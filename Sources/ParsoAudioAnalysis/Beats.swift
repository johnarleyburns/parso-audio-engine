//
//  Beats.swift
//  Ported verbatim from parso-tonearm/Sources/DJ/Analysis/Beats.swift
//  (audio-engine unification, docs/UNIFICATION_PLAN.md §4 Phase 5).
//

import Foundation
import Accelerate

/// Beat tracking configuration (§23.1).
public struct BeatConfig: Sendable, Equatable {
    /// Penalty weight for deviating from the target period (log-Gaussian).
    public var tightness: Double = 100
    /// Snap-to-onset tolerance per beat, in milliseconds.
    public var refineWindowMS: Double = 25
    /// Constant-tempo default for DJ tracks.
    public var allowVariableTempo: Bool = false

    public init(tightness: Double = 100, refineWindowMS: Double = 25,
                allowVariableTempo: Bool = false) {
        self.tightness = tightness
        self.refineWindowMS = refineWindowMS
        self.allowVariableTempo = allowVariableTempo
    }
}

/// Downbeat detection configuration (§23.2).
public struct DownbeatConfig: Sendable, Equatable {
    public var beatsPerBar: Int = 4
    public var lowBandHz: ClosedRange<Float> = 20...120
    public var harmonicChangeWeight: Double = 0.5
    public var lowEnergyWeight: Double = 0.5

    public init(beatsPerBar: Int = 4, lowBandHz: ClosedRange<Float> = 20...120,
                harmonicChangeWeight: Double = 0.5, lowEnergyWeight: Double = 0.5) {
        self.beatsPerBar = beatsPerBar
        self.lowBandHz = lowBandHz
        self.harmonicChangeWeight = harmonicChangeWeight
        self.lowEnergyWeight = lowEnergyWeight
    }
}

/// The authoritative beat grid (§23.1): sample-accurate beat positions plus a
/// header row for `beat_grid`.
public struct BeatGrid: Equatable, Sendable {
    public var firstBeatSample: Int64
    public var bpm: Double
    public var beatSamples: [Int64]
    public var confidence: [Float]
    public var isConstantTempo: Bool

    public init(firstBeatSample: Int64, bpm: Double, beatSamples: [Int64],
                confidence: [Float], isConstantTempo: Bool) {
        self.firstBeatSample = firstBeatSample
        self.bpm = bpm
        self.beatSamples = beatSamples
        self.confidence = confidence
        self.isConstantTempo = isConstantTempo
    }
}

public enum BeatTracker {
    /// Ellis-style DP beat tracker (App. F.5, §23.1): choose beat frames
    /// maximizing Σ onset(b) − λ·(log(Δt/P))². Returns the grid.
    public static func grid(novelty: [Float], hopSeconds: Double,
                            sampleRate: Double,
                            onsets: [OnsetPeak],
                            bpm: Double,
                            config: BeatConfig = BeatConfig()) -> BeatGrid? {
        let period = (60.0 / bpm) / Double(hopSeconds)
        let n = novelty.count
        guard n > 0, period > 0 else { return nil }

        var score = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        let lo = Int(period * 0.5)
        let hi = Int(period * 1.5)
        guard hi > 0 else { return nil }

        for i in 0..<n {
            score[i] = Double(novelty[i])
            var bestPrev = -Double.greatestFiniteMagnitude
            var bestJ = -1
            let jStart = max(0, i - hi)
            let jEnd = max(0, i - lo)
            guard jStart <= jEnd else { continue }
            for j in jStart...jEnd where j < i {
                let interval = Double(i - j)
                guard interval > 0 else { continue }
                let penalty = -config.tightness * pow(log(interval / period), 2)
                let cand = score[j] + penalty
                if cand > bestPrev { bestPrev = cand; bestJ = j }
            }
            if bestJ >= 0 { score[i] += bestPrev; back[i] = bestJ }
        }

        // Backtrace from the best-scoring tail beat.
        var tail = 0
        var bestScore = -Double.greatestFiniteMagnitude
        for i in 0..<n where score[i] > bestScore {
            bestScore = score[i]
            tail = i
        }
        guard tail >= 0 else { return nil }

        var frames: [Int] = []
        var i = tail
        while i >= 0 {
            frames.append(i)
            guard i > 0 else { break }
            i = back[i]
            if i < 0 { break }
        }
        frames.reverse()
        guard frames.count >= 2 else { return nil }

        // Re-phase the grid: the DP backtrace anchors at frame 0 (silence), so
        // beats can sit between onsets. Try every whole-frame offset within the
        // first period and keep the one maximizing summed onset strength
        // (§23.1's "position of beat 1"). Constant tempo only.
        if !config.allowVariableTempo, let phased = Self.rephase(frames, novelty: novelty, period: period) {
            frames = phased
        }        // Convert beat frames to sample positions, refining each to the nearest
        // strong onset within the window, and sub-frame via parabolic
        // interpolation of the envelope so the grid is sample-accurate (FR-ANL-4).
        // For a rigid constant-tempo grid the phase fit can leave a beat one
        // frame off its peak, so the snap tolerance spans half the beat period;
        // the beat then takes the onset's own strength as its confidence.
        let refineWindow = config.allowVariableTempo
            ? config.refineWindowMS / 1000.0
            : (period * hopSeconds) / 2.0

        var beatSamples: [Int64] = []
        var confidence: [Float] = []
        for frame in frames {
            var seconds = Double(frame) * hopSeconds
            var strength = novelty[frame]
            if let nearest = onsets.min(by: {
                abs($0.timeSeconds - seconds) < abs($1.timeSeconds - seconds)
            }), abs(nearest.timeSeconds - seconds) <= refineWindow {
                // Snapped: the onset peak is already sub-frame refined, so use
                // its time and strength directly (no second parabola — that
                // would undo the snap and break grid rigidity).
                seconds = nearest.timeSeconds
                strength = nearest.strength
            } else if !config.allowVariableTempo {
                // Rigid grid: keep the periodic position exactly; apply only the
                // sub-frame parabola so beats stay uniformly spaced.
                if let delta = Self.subFrameOffset(novelty, at: frame) {
                    seconds += delta * hopSeconds
                }
            }
            let sample = Int64((seconds * sampleRate).rounded())
            if let last = beatSamples.last, sample <= last { continue }
            beatSamples.append(sample)
            confidence.append(strength)
        }

        // Trim leading beats that sit in silence before the first real onset.
        // The DP backtrace runs all the way to frame 0; beats with negligible
        // onset strength are padding, and keeping them skews the median BPM.
        if let maxConfidence = confidence.max(), maxConfidence > 0 {
            let floor = maxConfidence * 0.15
            if let firstStrong = confidence.firstIndex(where: { $0 >= floor }) {
                if firstStrong > 0 {
                    beatSamples.removeFirst(firstStrong)
                    confidence.removeFirst(firstStrong)
                }
            }
        }

        guard beatSamples.count >= 2 else { return nil }

        // Fit BPM by least-squares regression over beat index vs time — the
        // maximum-likelihood estimate for a constant tempo, robust to the
        // frame-quantized jitter that biases a median of deltas (§23.1, F.5).
        let refinedBPM = Self.leastSquaresBPM(beatSamples, sampleRate: sampleRate)

        return BeatGrid(firstBeatSample: beatSamples.first ?? 0,
                        bpm: refinedBPM,
                        beatSamples: beatSamples,
                        confidence: confidence,
                        isConstantTempo: !config.allowVariableTempo)
    }

    /// Least-squares slope of beat index vs time → BPM. Regression over
    /// `(index, sample)` minimizes the impact of individual beat jitter.
    static func leastSquaresBPM(_ beatSamples: [Int64], sampleRate: Double) -> Double {
        guard beatSamples.count >= 2 else { return 0 }
        let n = Double(beatSamples.count)
        var sumX = 0.0
        var sumY = 0.0
        var sumXY = 0.0
        var sumXX = 0.0
        for (i, sample) in beatSamples.enumerated() {
            let x = Double(i)
            let y = Double(sample)
            sumX += x
            sumY += y
            sumXY += x * y
            sumXX += x * x
        }
        let denom = n * sumXX - sumX * sumX
        guard abs(denom) > 1e-12 else { return 0 }
        let slopeSamplesPerBeat = (n * sumXY - sumX * sumY) / denom
        guard slopeSamplesPerBeat > 0 else { return 0 }
        return 60.0 * sampleRate / slopeSamplesPerBeat
    }

    /// Downbeats (§23.2, F.5): pick the beat offset within each bar that best
    /// explains the low-frequency accent pattern. Returns beat indices that are
    /// downbeats. With only the novelty envelope, low-band energy is approximated
    /// by the beat's own onset strength — a kick on "1" marks it.
    public static func downbeats(beatSamples: [Int64], novelty: [Float],
                                 hopSeconds: Double, sampleRate: Double,
                                 config: DownbeatConfig = DownbeatConfig()) -> [Int] {
        let beatsPerBar = max(2, config.beatsPerBar)
        guard beatSamples.count >= beatsPerBar else { return [] }

        // Per-beat strength = novelty at the nearest frame.
        let strengths = beatSamples.map { sample -> Double in
            let frame = Int((Double(sample) / sampleRate / hopSeconds).rounded())
            let idx = max(0, min(novelty.count - 1, frame))
            return Double(novelty[idx])
        }

        // Score each offset: mean strength of beats at that offset across bars.
        var offsetScores = [Double](repeating: 0, count: beatsPerBar)
        var offsetCounts = [Int](repeating: 0, count: beatsPerBar)
        for (idx, s) in strengths.enumerated() {
            let offset = idx % beatsPerBar
            offsetScores[offset] += s
            offsetCounts[offset] += 1
        }
        var bestOffset = 0
        var bestScore = -Double.greatestFiniteMagnitude
        for offset in 0..<beatsPerBar where offsetCounts[offset] > 0 {
            let mean = offsetScores[offset] / Double(offsetCounts[offset])
            if mean > bestScore {
                bestScore = mean
                bestOffset = offset
            }
        }

        return beatSamples.indices.filter { $0 % beatsPerBar == bestOffset }
    }

    /// Fits the rigid constant-tempo grid (§23.1): a single global period plus
    /// the phase ("position of beat 1"). The DP backtrace only fixes the period;
    /// its frames can sit between onsets, so we lay a uniform grid at the target
    /// period, try every phase offset within one period, and keep the alignment
    /// maximizing summed onset strength. Returns a rigid grid of frame indices.
    static func rephase(_ frames: [Int], novelty: [Float], period: Double) -> [Int]? {
        guard frames.first != nil, frames.count > 1 else { return frames }
        let n = novelty.count
        let periodInt = max(1, Int(period.rounded()))
        var bestFrames = frames
        var bestScore = -Double.greatestFiniteMagnitude

        for phase in 0..<periodInt {
            // Uniform grid: phase, phase+P, phase+2P, ... (same count as the DP).
            var candidate: [Int] = []
            for k in 0..<frames.count {
                let f = Int((Double(phase) + Double(k) * period).rounded())
                guard f >= 0 && f < n else { break }
                candidate.append(f)
            }
            guard candidate.count >= 2 else { continue }
            var score = 0.0
            for f in candidate { score += Double(novelty[f]) }
            if score > bestScore {
                bestScore = score
                bestFrames = candidate
            }
        }
        return bestFrames
    }

    /// Sub-frame offset (in frames, centered on `index`) from a parabola fitted
    /// through the envelope's three neighbouring points. Returns nil when the
    /// fit is degenerate. This makes the grid sample-accurate rather than
    /// frame-quantized (FR-ANL-4).
    static func subFrameOffset(_ envelope: [Float], at index: Int) -> Double? {
        let count = envelope.count
        guard index > 0, index < count - 1 else { return nil }
        let y0 = Double(envelope[index - 1])
        let y1 = Double(envelope[index])
        let y2 = Double(envelope[index + 1])
        let denom = y0 - 2 * y1 + y2
        guard abs(denom) > 1e-9 else { return nil }
        // Vertex of the parabola through (-1,y0),(0,y1),(1,y2): x* = (y0 - y2)/(2*denom).
        let vertex = (y0 - y2) / (2 * denom)
        guard vertex.isFinite, abs(vertex) <= 1 else { return nil }
        return vertex
    }
}
