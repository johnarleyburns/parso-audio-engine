//
//  Tempo.swift
//  Ported verbatim from parso-tonearm/Sources/DJ/Analysis/Tempo.swift
//  (audio-engine unification, docs/UNIFICATION_PLAN.md §4 Phase 5).
//

import Foundation
import Accelerate

/// Tempo estimation configuration (§22.3–22.4).
public struct TempoConfig: Sendable, Equatable {
    public var range: ClosedRange<Double> = 60...220
    /// Histogram step in BPM.
    public var stepBPM: Double = 0.5
    /// Comb harmonics (1...4); weight decays with `h` per App. F.4.
    public var combHarmonics: ClosedRange<Int> = 1...4
    /// Gentle prior toward common DJ tempos, used to disambiguate octave errors.
    public var preferredTempoCenter: Double = 125
    public var preferenceStrengthBPM: Double = 30

    public init(range: ClosedRange<Double> = 60...220,
                stepBPM: Double = 0.5,
                combHarmonics: ClosedRange<Int> = 1...4,
                preferredTempoCenter: Double = 125,
                preferenceStrengthBPM: Double = 30) {
        self.range = range
        self.stepBPM = stepBPM
        self.combHarmonics = combHarmonics
        self.preferredTempoCenter = preferredTempoCenter
        self.preferenceStrengthBPM = preferenceStrengthBPM
    }
}

/// One BPM hypothesis (§22.3). `rank 0` is the best.
public struct TempoCandidate: Equatable, Sendable {
    public var bpm: Double
    public var confidence: Double
    public var rank: Int

    public init(bpm: Double, confidence: Double, rank: Int) {
        self.bpm = bpm
        self.confidence = confidence
        self.rank = rank
    }
}

public enum TempoAnalyzer {
    /// Autocorrelation of the onset novelty function (App. F.4), via `vDSP_conv`.
    /// vDSP_conv computes C[n] = Σ_k A[n+k]·F[k]; with A zero-padded to 2N−1 and
    /// F = the signal itself, C[n] is exactly the autocorrelation at lag n.
    static func autocorrelation(_ signal: [Float]) -> [Float] {
        guard !signal.isEmpty else { return [] }
        let n = signal.count
        var padded = [Float](repeating: 0, count: 2 * n - 1)
        padded.replaceSubrange(0..<n, with: signal)
        var ac = [Float](repeating: 0, count: n)
        vDSP_conv(padded, 1, signal, 1, &ac, 1, vDSP_Length(n), vDSP_Length(n))
        return ac
    }

    /// Comb score for one candidate BPM: sum of autocorrelation at the beat
    /// period and its integer multiples, decaying with harmonic order (F.4).
    /// The autocorrelation is sampled at fractional lags via linear
    /// interpolation so the comb resolves BPMs between frame boundaries
    /// instead of quantizing every BPM to the same integer lag.
    static func combScore(bpm: Double, autocorrelation ac: [Float],
                          hopSeconds: Double, config: TempoConfig) -> Double {
        let m = ac.count
        let periodFrames = (60.0 / bpm) / hopSeconds
        var score = 0.0
        for h in config.combHarmonics {
            let lag = periodFrames * Double(h)
            guard lag > 0, lag < Double(m) else { continue }
            let lo = Int(lag.rounded(.down))
            let hi = lo + 1
            let weight = lag - Double(lo)
            if hi < m {
                score += (Double(ac[lo]) * (1 - weight) + Double(ac[hi]) * weight) / Double(h)
            } else {
                score += Double(ac[lo]) / Double(h)
            }
        }
        return score
    }

    /// Bounded preference around the preferred center. The prior may break an
    /// ambiguity, but must not erase rhythmic evidence far from 125 BPM.
    static func priorWeight(_ bpm: Double, config: TempoConfig) -> Double {
        let d = (bpm - config.preferredTempoCenter) / config.preferenceStrengthBPM
        return 0.9 + 0.1 * exp(-0.5 * d * d)
    }

    /// Refine the selected period using the spacing of nearby autocorrelation
    /// peaks. Linear sampling of a coarse envelope favors integer-frame lags;
    /// fitting several multiples of the period recovers sub-frame precision
    /// without switching to another rhythmic hypothesis or fitting snapped beats.
    static func refinedBPM(_ bpm: Double, autocorrelation ac: [Float],
                           hopSeconds: Double, config: TempoConfig) -> Double {
        guard ac.count > 2, bpm > 0, hopSeconds > 0 else { return bpm }
        let period = 60 / bpm / hopSeconds
        var numerator = 0.0
        var denominator = 0.0
        for harmonic in 1...16 {
            let h = Double(harmonic)
            let target = period * h
            let radius = max(1, target * 0.02)
            let lo = max(1, Int(floor(target - radius)))
            let hi = min(ac.count - 2, Int(ceil(target + radius)))
            guard lo <= hi else { continue }
            var peak = lo
            for index in lo...hi where ac[index] > ac[peak] { peak = index }
            guard ac[peak] > 0, ac[peak] > ac[peak - 1],
                  ac[peak] >= ac[peak + 1] else { continue }
            let left = Double(ac[peak - 1])
            let center = Double(ac[peak])
            let right = Double(ac[peak + 1])
            let curvature = left - 2 * center + right
            guard curvature < 0 else { continue }
            let lag = Double(peak) + 0.5 * (left - right) / curvature
            guard abs(lag - target) <= radius else { continue }
            numerator += center * h * lag
            denominator += center * h * h
        }
        guard denominator > 0, numerator > 0 else { return bpm }
        let refined = 60 / (numerator / denominator) / hopSeconds
        guard config.range.contains(refined), abs(refined - bpm) <= bpm * 0.02 else { return bpm }
        return refined
    }

    /// Estimate tempo from the onset novelty envelope. Returns the top-K
    /// candidates with octave errors resolved and rank 0 = best.
    public static func estimate(novelty: [Float], hopSeconds: Double,
                                config: TempoConfig = TempoConfig(),
                                topK: Int = 3) -> [TempoCandidate] {
        guard novelty.count > 8 else { return [] }
        // The envelope is power-domain flux. Correlating it directly squares
        // the accent contrast again, letting loud downbeats erase quieter
        // intervening beats. Amplitude-domain novelty keeps those beats in the
        // tempo evidence; the uncompressed envelope still drives beat accents.
        let rhythmicNovelty = novelty.map { max(0, $0).squareRoot() }
        let ac = autocorrelation(rhythmicNovelty)

        // Inter-onset-interval histogram with octave folding: a period T and
        // 2T/½T reinforce the same tempo class (§22.3).
        let peaks = OnsetDetector.peaks(novelty, config: OnsetConfig(), frameRateHz: 1 / hopSeconds)
        var ioiHistogram: [Double: Double] = [:]
        if peaks.count >= 2 {
            for i in 0..<(peaks.count - 1) {
                var interval = peaks[i + 1].timeSeconds - peaks[i].timeSeconds
                // Octave-fold into the search range's BPM band (60–220 BPM).
                var bpm = 60.0 / interval
                while bpm < config.range.lowerBound { bpm *= 2; interval /= 2 }
                while bpm > config.range.upperBound { bpm /= 2; interval *= 2 }
                ioiHistogram[interval, default: 0] += 1
            }
        }

        // Score each candidate BPM: autocorrelation comb + IOI histogram, with
        // the tempo prior applied gently (§22.3).
        var scored: [(bpm: Double, raw: Double)] = []
        var bpm = config.range.lowerBound
        while bpm <= config.range.upperBound {
            let comb = combScore(bpm: bpm, autocorrelation: ac,
                                 hopSeconds: hopSeconds, config: config)
            let period = 60.0 / bpm
            let ioiVotes = ioiHistogram[period, default: 0]
            let raw = comb + ioiVotes * 0.5
            scored.append((bpm, raw))
            bpm += config.stepBPM
        }
        guard !scored.isEmpty else { return [] }

        // Octave resolution: evaluate each candidate and its ×2/÷2 together,
        // keeping the variant with the highest prior-weighted comb score so a
        // clear half/double-tempo error resolves to the true BPM (§22.4).
        var winners: [Int: TempoCandidate] = [:]
        for s in scored {
            let variants = [s.bpm, s.bpm / 2, s.bpm * 2].filter { config.range.contains($0) }
            let bestVariant = variants.max { a, b in
                let ca = combScore(bpm: a, autocorrelation: ac, hopSeconds: hopSeconds, config: config) * priorWeight(a, config: config)
                let cb = combScore(bpm: b, autocorrelation: ac, hopSeconds: hopSeconds, config: config) * priorWeight(b, config: config)
                return ca < cb
            } ?? s.bpm

            // Only the family winner survives, keyed by rounded BPM.
            let key = Int((bestVariant / config.stepBPM).rounded())
            let weighted = combScore(bpm: bestVariant, autocorrelation: ac,
                                     hopSeconds: hopSeconds, config: config)
                * priorWeight(bestVariant, config: config)
            if let existing = winners[key] {
                // Keep the stronger of the two if the same family won twice.
                if weighted > existing.confidence {
                    winners[key] = TempoCandidate(bpm: bestVariant, confidence: weighted, rank: 0)
                }
            } else {
                winners[key] = TempoCandidate(bpm: bestVariant, confidence: weighted, rank: 0)
            }
        }

        let sorted = winners.values
            // Total order: `winners.values` iterates in a non-deterministic
            // dictionary order, so ties on confidence are broken by BPM (then
            // the map key) to keep the ranking reproducible run-to-run
            // (NFR-DET-3).
            .sorted {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.bpm < $1.bpm
            }
            .prefix(topK)
            .map { TempoCandidate(bpm: $0.bpm, confidence: normalized($0.confidence, among: Array(winners.values)), rank: $0.rank) }
        return sorted.enumerated().map { idx, c in
            TempoCandidate(bpm: refinedBPM(c.bpm, autocorrelation: ac,
                                           hopSeconds: hopSeconds, config: config),
                           confidence: c.confidence, rank: idx)
        }
    }

    /// Maps raw weighted scores to a 0...1 confidence relative to the best.
    static func normalized(_ value: Double, among all: [TempoCandidate]) -> Double {
        let best = all.map(\.confidence).max() ?? 0
        guard best > 0 else { return 0 }
        return max(0, min(1, value / best))
    }
}
