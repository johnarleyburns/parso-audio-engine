//
//  SemanticPooling.swift
//  Whole-track pooling of per-window embedding vectors, ported from
//  parso-tonearm/Sources/DJ/Semantic/Pooling.swift. See ATTRIBUTION.md.
//
#if !os(watchOS)
import Foundation
import Accelerate

/// Mean pooling L2-normalizes the mean of the window vectors. Attention
/// pooling weights each window by a softmax over salience — a blend of the
/// window's energy (its log-mel magnitude, a loudness proxy) and its
/// similarity to the track centroid — so intro/outro/ambient tails are
/// de-emphasized and the characteristic sections dominate the pooled vector.
public enum SemanticPooling {

    /// Mean pooling: L2-normalized mean of the window vectors. Cheap, robust.
    public static func mean(_ windows: [[Float]]) -> [Float] {
        guard let first = windows.first else { return [] }
        let dims = first.count
        var sum = [Float](repeating: 0, count: dims)
        for window in windows {
            for i in 0..<dims { sum[i] += window[i] }
        }
        let count = Float(max(1, windows.count))
        for i in 0..<dims { sum[i] /= count }
        return l2Normalized(sum)
    }

    /// Attention pooling. `energy` is one scalar per window (absent → the
    /// salience is pure distance-from-centroid). Softmax temperature 1.0.
    public static func attention(_ windows: [[Float]], energy: [Float]?) -> [Float] {
        guard let first = windows.first else { return [] }
        guard windows.count > 1 else { return l2Normalized(first) }
        let dims = first.count

        // Track centroid = mean of the window vectors (unnormalized).
        var centroid = [Float](repeating: 0, count: dims)
        for window in windows {
            for i in 0..<dims { centroid[i] += window[i] / Float(windows.count) }
        }
        let centroidUnit = l2Normalized(centroid)

        // Similarity of each window to the centroid, normalized to [0, 1]
        // (a window very unlike the average is an intro/ambient tail → low weight).
        var similarities = [Float](repeating: 0, count: windows.count)
        for (j, window) in windows.enumerated() {
            let unit = l2Normalized(window)
            var dot: Float = 0
            vDSP_dotpr(unit, 1, centroidUnit, 1, &dot, vDSP_Length(dims))
            similarities[j] = (dot + 1) / 2
        }
        similarities = minMaxNormalize(similarities)

        // Blend salience: energy 0.5 + similarity 0.5 (energy absent → 0.5 only).
        var salience = similarities
        if let energy, energy.count == windows.count {
            let energies = minMaxNormalize(energy)
            for i in 0..<salience.count {
                salience[i] = 0.5 * energies[i] + 0.5 * similarities[i]
            }
        }

        // Softmax over salience → window weights.
        let weights = softmax(salience)

        // Weighted mean, then L2-normalize.
        var pooled = [Float](repeating: 0, count: dims)
        for (j, window) in windows.enumerated() {
            let w = weights[j]
            for i in 0..<dims { pooled[i] += w * window[i] }
        }
        return l2Normalized(pooled)
    }

    /// Dispatch by the model registry's pooling strategy.
    public static func pool(_ windows: [[Float]],
                            strategy: EmbeddingPooling,
                            energy: [Float]? = nil) -> [Float] {
        switch strategy {
        case .mean: return mean(windows)
        case .attention: return attention(windows, energy: energy)
        }
    }

    /// L2-normalize; returns a new vector.
    public static func l2Normalized(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_dotpr(vector, 1, vector, 1, &norm, vDSP_Length(vector.count))
        let length = sqrt(norm)
        guard length > 0 else { return vector }
        var inverse = 1 / length
        var out = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &inverse, &out, 1, vDSP_Length(vector.count))
        return out
    }

    private static func softmax(_ scores: [Float]) -> [Float] {
        guard let maxScore = scores.max() else { return [] }
        var expScores: [Float] = []
        expScores.reserveCapacity(scores.count)
        var total: Float = 0
        for s in scores {
            let e = exp(s - maxScore)
            expScores.append(e)
            total += e
        }
        guard total > 0 else { return scores.map { _ in 1 / Float(scores.count) } }
        return expScores.map { $0 / total }
    }

    /// Min-max scale to [0, 1]; all-equal input → uniform (0.5) so the blend
    /// is well-defined and the pooled result is invariant to absolute energy level.
    private static func minMaxNormalize(_ values: [Float]) -> [Float] {
        guard let lo = values.min(), let hi = values.max(), hi > lo else {
            return values.map { _ in 0.5 }
        }
        let range = hi - lo
        return values.map { ($0 - lo) / range }
    }
}
#endif
