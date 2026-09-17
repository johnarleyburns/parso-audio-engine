import Foundation

/// Small transition-facing adapter over the existing SemanticModel seam. It
/// does not load models or ship weights; callers provide embeddings produced by
/// `CLAPEmbedder` or another approved SemanticModel implementation.
public enum SemanticSimilarity {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot = 0.0
        var aa = 0.0
        var bb = 0.0
        for index in a.indices {
            let x = Double(a[index])
            let y = Double(b[index])
            guard x.isFinite, y.isFinite else { return 0 }
            dot += x * y
            aa += x * x
            bb += y * y
        }
        let denominator = sqrt(aa * bb)
        guard denominator > 0, denominator.isFinite else { return 0 }
        return max(-1, min(1, dot / denominator))
    }

    /// Converts cosine space [-1, 1] to the normalized planner space [0, 1].
    public static func normalizedCosine(_ a: [Float], _ b: [Float]) -> Double {
        (cosine(a, b) + 1) * 0.5
    }
}
