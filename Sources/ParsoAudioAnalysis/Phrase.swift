//
//  Phrase.swift
//  Ported verbatim from parso-tonearm/Sources/DJ/Analysis/Phrase.swift
//  (audio-engine unification, docs/UNIFICATION_PLAN.md §4 Phase 5).
//

import Foundation
import Accelerate

/// Phrase segmentation configuration (§25.1).
public struct PhraseConfig: Sendable, Equatable {
    /// Checkerboard kernel half-width in bars (Foote novelty).
    public var kernelBars: Int = 8
    /// Minimum phrase length in beats; shorter candidates merge.
    public var minPhraseBeats: Int = 16
    /// Preferred quantized phrase lengths (in beats).
    public var quantizeToBeats: [Int] = [16, 32]
    /// Fractional energy drop marking a breakdown.
    public var energyDropThreshold: Double = 0.35

    public init(kernelBars: Int = 8, minPhraseBeats: Int = 16,
                quantizeToBeats: [Int] = [16, 32],
                energyDropThreshold: Double = 0.35) {
        self.kernelBars = kernelBars
        self.minPhraseBeats = minPhraseBeats
        self.quantizeToBeats = quantizeToBeats
        self.energyDropThreshold = energyDropThreshold
    }
}

/// A musical phrase (§25): a bar-aligned span of a track.
public struct Phrase: Equatable, Sendable {
    /// Sample position of the phrase's first beat (the `phrase.startSample`
    /// row, §19.4 — the anchor the waveform renderer draws the label on).
    public var startSample: Int64
    /// Sample position of the phrase's last beat (`phrase.endSample`).
    public var endSample: Int64
    /// Beat index of the phrase start.
    public var startBeat: Int
    /// Length in beats.
    public var lengthBeats: Int
    /// Section label (intro/build/drop/chorus/breakdown/outro).
    public var type: PhraseType
    /// Mean energy on a 0...10 scale (§25.2).
    public var energy: Float
    /// 0...1 boundary-confidence.
    public var confidence: Double

    public init(startSample: Int64, endSample: Int64,
                startBeat: Int, lengthBeats: Int, type: PhraseType,
                energy: Float, confidence: Double) {
        self.startSample = startSample
        self.endSample = endSample
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.type = type
        self.energy = energy
        self.confidence = confidence
    }
}

/// Phrase labels (§25.1).
public enum PhraseType: String, Sendable, CaseIterable {
    case intro
    case build
    case drop
    case chorus
    case breakdown
    case outro
}

/// Beat-synchronous feature vector: chroma + energy, used for the self-similarity
/// matrix (§25.1). One entry per beat.
public struct BeatFeature: Sendable, Equatable {
    public var chroma: HPCP
    public var energy: Float

    public init(chroma: HPCP, energy: Float) {
        self.chroma = chroma
        self.energy = energy
    }

    /// Cosine similarity with another beat feature (chroma-weighted).
    public func similarity(to other: BeatFeature) -> Float {
        let a = chroma.values
        let b = other.chroma.values
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<12 {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        na = sqrt(na)
        nb = sqrt(nb)
        if na > 0 && nb > 0 {
            // Blend: mostly timbral, slightly energy.
            let chromaSim = dot / (na * nb)
            let eSim = 1 - abs(energy - other.energy)
            return 0.8 * chromaSim + 0.2 * eSim
        }
        return 0
    }
}

/// Phrase segmentation (§25): fuses structural novelty (self-similarity +
/// Foote checkerboard) with energy-contour change points, snaps boundaries to
/// downbeats, and quantizes to musically plausible lengths.
public enum PhraseSegmenter {

    /// Segment `features` (one per beat) given the beat grid. `beats` is the
    /// per-beat sample positions; `downbeats` the beat indices that start bars.
    public static func segment(features: [BeatFeature],
                               beats: [Int64],
                               downbeats: [Int],
                               sampleRate: Double,
                               config: PhraseConfig = PhraseConfig()) -> [Phrase] {
        let n = features.count
        guard n > 0, beats.count >= n else { return [] }

        // 1) Self-similarity matrix + Foote checkerboard novelty.
        var ss = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                ss[i][j] = features[i].similarity(to: features[j])
            }
        }
        let novelty = footeNovelty(ss, config: config)

        // 2) Energy-contour change points.
        let energyChange = energyChangePoints(features)

        // 3) Combined change score, peak-picked.
        var change = [Float](repeating: 0, count: n)
        for i in 0..<n {
            change[i] = novelty[i] + energyChange[i]
        }
        var boundaries = peakPick(change, minGap: config.minPhraseBeats / 2)
        boundaries.insert(0, at: 0)
        boundaries.append(n)

        // 4) Snap to the nearest downbeat.
        var snapped = boundaries.map { snapToDownbeat($0, downbeats: downbeats, n: n) }
        snapped = dedupeAndSort(snapped, n: n)

        // 5) Enforce minimum length and quantize lengths to preferred multiples.
        var final: [Int] = [snapped.first ?? 0]
        var cursor = 0
        while cursor < snapped.count - 1 {
            var end = snapped[cursor + 1]
            let length = end - snapped[cursor]
            if length < config.minPhraseBeats {
                // Merge into the next boundary.
                end = snapped.count > cursor + 2 ? snapped[cursor + 2] : n
            }
            // Quantize the length toward a preferred multiple.
            let quantizedLength = quantizeLength(length, options: config.quantizeToBeats)
            let newEnd = min(n, snapped[cursor] + quantizedLength)
            if newEnd > final.last! { final.append(newEnd) }
            cursor = snapped.firstIndex { $0 >= newEnd } ?? (cursor + 1)
            if cursor >= snapped.count - 1 { break }
        }
        if final.last != n { final.append(n) }

        // 6) Label phrases from their energy shape.
        return buildPhrases(final, features: features, beats: beats,
                            sampleRate: sampleRate, n: n, config: config)
    }

    // MARK: - Foote novelty

    /// Checkerboard novelty along the diagonal of the self-similarity matrix
    /// (§25.1, Foote 2000): convolution with a tapering checkerboard kernel.
    static func footeNovelty(_ ss: [[Float]], config: PhraseConfig) -> [Float] {
        let n = ss.count
        guard n > 1 else { return [Float](repeating: 0, count: n) }
        // Kernel half-width in beats; a bar is `beatsPerBar` beats, but we
        // approximate using the config's kernelBars as the half-width.
        let half = max(1, config.kernelBars)
        var kernel = [[Float]](repeating: [Float](repeating: 0, count: 2 * half + 1),
                               count: 2 * half + 1)
        let sigma = Float(half) / 2
        for i in -half...half {
            for j in -half...half {
                // Checkerboard sign: +1 in the on-diagonal quadrants where a
                // true boundary keeps similarity high, −1 off-diagonal where a
                // boundary shows low cross-similarity. Convolving the SSM with
                // this kernel peaks exactly at section boundaries.
                let sign: Float = (i * j > 0) ? 1 : -1
                let g = exp(-(Float(i * i + j * j)) / (2 * sigma * sigma))
                kernel[i + half][j + half] = sign * g
            }
        }

        var novelty = [Float](repeating: 0, count: n)
        for b in 0..<n {
            var acc: Float = 0
            for i in -half...half {
                let r = b + i
                guard r >= 0 && r < n else { continue }
                for j in -half...half {
                    let c = b + j
                    guard c >= 0 && c < n else { continue }
                    acc += ss[r][c] * kernel[i + half][j + half]
                }
            }
            novelty[b] = max(0, acc)
        }
        return novelty
    }

    /// Energy-contour change points (§25.1): absolute slope of the smoothed
    /// energy, normalized to the novelty scale.
    static func energyChangePoints(_ features: [BeatFeature]) -> [Float] {
        let n = features.count
        guard n > 2 else { return [Float](repeating: 0, count: n) }
        var energies = features.map { $0.energy }
        if let mx = energies.max(), mx > 0 {
            energies = energies.map { $0 / mx }
        }
        var out = [Float](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            let prev = energies[i - 1]
            let next = energies[i + 1]
            out[i] = abs(next - prev)
        }
        return out
    }

    /// Simple local-maximum peak picking above the mean, with a minimum gap.
    /// A flat run (plateau) picks its center index.
    static func peakPick(_ signal: [Float], minGap: Int) -> [Int] {
        let n = signal.count
        guard n > 2 else { return [] }
        let mean = signal.reduce(0, +) / Float(n)
        var peaks: [Int] = []
        var i = 1
        while i < n - 1 {
            guard signal[i] > mean else { i += 1; continue }
            // Find the extent of a plateau.
            var left = i
            while left > 0 && signal[left - 1] >= signal[left] { left -= 1 }
            var right = i
            while right < n - 1 && signal[right + 1] >= signal[right] { right += 1 }
            if signal[left] > (left > 0 ? signal[left - 1] : -1)
                && signal[right] > (right < n - 1 ? signal[right + 1] : -1) {
                peaks.append((left + right) / 2)
                i = right + 1 + max(1, minGap)
            } else {
                i = right + 1
            }
        }
        return peaks
    }

    static func snapToDownbeat(_ beatIndex: Int, downbeats: [Int], n: Int) -> Int {
        guard !downbeats.isEmpty else { return beatIndex }
        let target = max(0, min(n - 1, beatIndex))
        let nearest = downbeats.min(by: { abs($0 - target) < abs($1 - target) }) ?? target
        return nearest
    }

    static func dedupeAndSort(_ values: [Int], n: Int) -> [Int] {
        var seen: [Int] = []
        for v in values.sorted() {
            let clamped = max(0, min(n, v))
            if seen.last != clamped { seen.append(clamped) }
        }
        return seen
    }

    static func quantizeLength(_ length: Int, options: [Int]) -> Int {
        guard !options.isEmpty else { return length }
        let best = options.min(by: { abs($0 - length) < abs($1 - length) }) ?? length
        return best > 0 ? best : length
    }

    // MARK: - Phrase building

    static func buildPhrases(_ boundaries: [Int], features: [BeatFeature],
                             beats: [Int64], sampleRate: Double,
                             n: Int, config: PhraseConfig) -> [Phrase] {
        guard boundaries.count >= 2 else { return [] }
        // Per-boundary mean energy.
        var phraseEnergies: [Float] = []
        for i in 0..<(boundaries.count - 1) {
            let start = boundaries[i]
            let end = boundaries[i + 1]
            let slice = features[start..<min(end, n)]
            let mean = slice.isEmpty ? 0 : slice.map { $0.energy }.reduce(0, +) / Float(slice.count)
            phraseEnergies.append(mean)
        }
        let maxEnergy = phraseEnergies.max() ?? 0

        var phrases: [Phrase] = []
        for i in 0..<(boundaries.count - 1) {
            let start = boundaries[i]
            let end = boundaries[i + 1]
            guard end > start else { continue }
            let energy10 = min(10, max(0, phraseEnergies[i] * 10))
            let type = label(i: i, count: boundaries.count - 1,
                             energy: phraseEnergies[i], maxEnergy: maxEnergy,
                             energies: phraseEnergies, config: config)
            let length = end - start
            // Confidence from boundary novelty strength at the edges.
            let confidence = boundaryConfidence(features, start: start, end: end)
            let startSample = beats[max(0, min(start, n - 1))]
            let endSample = beats[max(start, min(end, n) - 1)]
            phrases.append(Phrase(startSample: startSample, endSample: endSample,
                                  startBeat: start, lengthBeats: length, type: type,
                                  energy: energy10, confidence: confidence))
        }
        return phrases
    }

    /// Label a phrase by its energy shape (§25.1): intro (low, first), outro
    /// (low, last), drop (energy spike after a low/breakdown), chorus (high
    /// sustained), breakdown (low after high), build (rising toward a high).
    static func label(i: Int, count: Int, energy: Float, maxEnergy: Float,
                      energies: [Float], config: PhraseConfig) -> PhraseType {
        let isFirst = i == 0
        let isLast = i == count - 1
        let isLow = maxEnergy > 0 && energy < Float(config.energyDropThreshold) * maxEnergy
        let isHigh = maxEnergy > 0 && energy > 0.6 * maxEnergy
        let prev = i > 0 ? energies[i - 1] : maxEnergy
        let next = i < count - 1 ? energies[i + 1] : 0

        if isFirst && isLow { return .intro }
        if isLast && isLow { return .outro }
        if isHigh && prev < energy { return .drop }
        if isHigh { return .chorus }
        if isLow && prev > energy { return .breakdown }
        if next > energy { return .build }
        return .build
    }

    /// Boundary confidence: how distinct the phrase's edges are, estimated from
    /// the change in energy at the phrase start.
    static func boundaryConfidence(_ features: [BeatFeature], start: Int, end: Int) -> Double {
        guard features.count > 2, start > 0, end <= features.count else { return 0.5 }
        let before = Double(features[start - 1].energy)
        let after = Double(features[start].energy)
        let delta = abs(after - before)
        return min(1.0, 0.4 + delta)
    }
}
