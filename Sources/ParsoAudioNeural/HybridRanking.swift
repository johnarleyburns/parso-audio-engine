//
//  HybridRanking.swift
//  Pure hybrid semantic + musical-attribute ranking, ported from
//  parso-tonearm/Sources/DJ/Semantic/Ranking.swift. See ATTRIBUTION.md.
//
import Foundation
import ParsoAudioAnalysis

/// Hybrid ranking weights. Each component is normalized to [0, 1]; the fused
/// score is the weighted sum. `default` mirrors Tonearm's shipping mixture
/// (semantic 0.40, BPM 0.20, Camelot 0.20, energy 0.10, phrase 0.10).
public struct RankWeights: Sendable, Equatable {
    public var semantic: Double
    public var bpm: Double
    public var key: Double
    public var energy: Double
    public var phrase: Double

    public static let `default` = RankWeights()

    public init(semantic: Double = 0.40,
                bpm: Double = 0.20,
                key: Double = 0.20,
                energy: Double = 0.10,
                phrase: Double = 0.10) {
        self.semantic = semantic
        self.bpm = bpm
        self.key = key
        self.energy = energy
        self.phrase = phrase
    }
}

/// One candidate track's known attributes for the hybrid score. Every
/// musical attribute is optional: an unanalysed track scores
/// semantic-dominant, with missing attributes landing at the neutral 0.5
/// per component.
public struct RankCandidate: Sendable, Equatable {
    /// Cosine similarity of the pooled vector to the query, 0...1.
    public var semantic: Double
    public var bpm: Double?
    public var camelot: CamelotKey?
    /// Whole-track energy on the 0...10 scale.
    public var energy: Double?
    /// Characteristic phrase length in beats (e.g., 16).
    public var phraseLength: Double?

    public init(semantic: Double,
                bpm: Double? = nil,
                camelot: CamelotKey? = nil,
                energy: Double? = nil,
                phraseLength: Double? = nil) {
        self.semantic = semantic
        self.bpm = bpm
        self.camelot = camelot
        self.energy = energy
        self.phraseLength = phraseLength
    }
}

/// The query-side target the fit terms score against. A nil target means
/// "unconstrained": the component contributes a neutral 0.5 so it cannot
/// reorder results.
public struct RankTarget: Sendable, Equatable {
    public var bpm: Double?
    public var camelot: CamelotKey?
    public var energy: Double?
    public var phraseLength: Double?
    /// Gaussian σ for `bpmFit` in BPM (default 3).
    public var bpmTolerance: Double

    public init(bpm: Double? = nil,
                camelot: CamelotKey? = nil,
                energy: Double? = nil,
                phraseLength: Double? = nil,
                bpmTolerance: Double = 3) {
        self.bpm = bpm
        self.camelot = camelot
        self.energy = energy
        self.phraseLength = phraseLength
        self.bpmTolerance = bpmTolerance
    }
}

/// The per-component values behind one fused score — a "why it matched" decomposition.
public struct RankBreakdown: Sendable, Equatable {
    public let semantic: Double
    public let bpm: Double
    public let key: Double
    public let energy: Double
    public let phrase: Double
    public let fused: Double

    public init(semantic: Double, bpm: Double, key: Double, energy: Double,
                phrase: Double, fused: Double) {
        self.semantic = semantic
        self.bpm = bpm
        self.key = key
        self.energy = energy
        self.phrase = phrase
        self.fused = fused
    }
}

/// Pure hybrid scorer. Deterministic: no random, no environment.
public enum HybridRanker {

    /// Neutral value for an unconstrained or unknown component — it neither
    /// rewards nor penalizes, so a missing target or a missing attribute
    /// cannot tilt the ordering.
    public static let neutral: Double = 0.5

    /// Gaussian weight: 1 at exact match, decaying with `sigma`.
    public static func gaussian(_ x: Double, sigma: Double) -> Double {
        guard sigma > 0 else { return x == 0 ? 1 : 0 }
        return exp(-0.5 * pow(x / sigma, 2))
    }

    /// Tempo fit: 1 at an exact match, gaussian decay over ±tolerance.
    /// Either side nil (no constraint / unanalysed) → neutral 0.5.
    public static func bpmFit(candidate: Double?, target: Double?,
                              tolerance: Double = 3) -> Double {
        guard let candidate, let target else { return neutral }
        return gaussian(candidate - target, sigma: tolerance)
    }

    /// Camelot compatibility, graded 1.0/0.9/0.7/0.5/0.0. Nil → neutral.
    public static func keyFit(candidate: CamelotKey?, target: CamelotKey?) -> Double {
        guard let candidate, let target else { return neutral }
        return Double(Camelot.compatibility(candidate, target))
    }

    /// Energy fit on the 0...10 scale: `1 − |Δ|/10`, clamped to [0, 1].
    public static func energyFit(candidate: Double?, target: Double?) -> Double {
        guard let candidate, let target else { return neutral }
        return max(0, min(1, 1 - abs(candidate - target) / 10))
    }

    /// Phrase-length / structure compatibility ("bar-multiple match"): whole
    /// multiples of the reference length (8 vs 16, 16 vs 32) score 1, and the
    /// grade decays with the deviation from the nearest whole multiple.
    public static func phraseFit(candidate: Double?, target: Double?) -> Double {
        guard let candidate, let target, candidate > 0, target > 0 else { return neutral }
        let ratio = max(candidate, target) / min(candidate, target)
        let deviation = abs(ratio - ratio.rounded())
        return max(0, 1 - deviation)
    }

    /// The weighted composition. Each component is normalized to [0, 1] and
    /// fused = Σ weight·component; `RankBreakdown` carries every component
    /// so a caller can explain the match.
    public static func fusedScore(_ candidate: RankCandidate,
                                  target: RankTarget,
                                  weights: RankWeights = .default) -> RankBreakdown {
        let semantic = max(0, min(1, candidate.semantic))
        let bpm = bpmFit(candidate: candidate.bpm, target: target.bpm,
                         tolerance: target.bpmTolerance)
        let key = keyFit(candidate: candidate.camelot, target: target.camelot)
        let energy = energyFit(candidate: candidate.energy, target: target.energy)
        let phrase = phraseFit(candidate: candidate.phraseLength,
                               target: target.phraseLength)
        let fused = weights.semantic * semantic
                  + weights.bpm * bpm
                  + weights.key * key
                  + weights.energy * energy
                  + weights.phrase * phrase
        return RankBreakdown(semantic: semantic, bpm: bpm, key: key,
                             energy: energy, phrase: phrase, fused: fused)
    }
}

/// A scored candidate plus its stable identity, used to order a result pool
/// deterministically: fused score descending, then semantic descending, then
/// rowID ascending — so ties never resolve by iteration or hash order.
public struct RankedMatch: Sendable, Equatable {
    public let rowID: Int64
    public let semantic: Double
    public let breakdown: RankBreakdown

    public init(rowID: Int64, semantic: Double, breakdown: RankBreakdown) {
        self.rowID = rowID
        self.semantic = semantic
        self.breakdown = breakdown
    }

    public var fused: Double { breakdown.fused }
}

public enum HybridRankerOrdering {
    /// Deterministic descending order over a scored pool (tie handling):
    /// fused desc, semantic desc, rowID asc.
    public static func order(_ matches: [RankedMatch]) -> [RankedMatch] {
        matches.sorted { a, b in
            if a.fused != b.fused { return a.fused > b.fused }
            if a.semantic != b.semantic { return a.semantic > b.semantic }
            return a.rowID < b.rowID
        }
    }
}
