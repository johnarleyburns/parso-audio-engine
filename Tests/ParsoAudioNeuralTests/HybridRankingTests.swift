import Foundation
import Testing
import ParsoAudioAnalysis
@testable import ParsoAudioNeural

@Suite
struct HybridRankingTests {
    @Test
    func bpmFitIsNeutralWhenEitherSideIsMissing() {
        #expect(HybridRanker.bpmFit(candidate: nil, target: 120) == HybridRanker.neutral)
        #expect(HybridRanker.bpmFit(candidate: 120, target: nil) == HybridRanker.neutral)
    }

    @Test
    func bpmFitIsOneAtExactMatch() {
        #expect(HybridRanker.bpmFit(candidate: 120, target: 120) == 1.0)
    }

    @Test
    func keyFitGradesCamelotCompatibility() {
        let a = CamelotKey(number: 8, letter: "A")
        #expect(HybridRanker.keyFit(candidate: a, target: a) == 1.0)
        #expect(abs(HybridRanker.keyFit(candidate: a.relative, target: a) - 0.9) < 0.0001)
        #expect(HybridRanker.keyFit(candidate: nil, target: a) == HybridRanker.neutral)
    }

    @Test
    func fusedScoreOrderingPrefersHigherSemanticAtEqualAttributes() {
        let target = RankTarget()
        let high = HybridRanker.fusedScore(RankCandidate(semantic: 0.9), target: target)
        let low = HybridRanker.fusedScore(RankCandidate(semantic: 0.1), target: target)
        #expect(high.fused > low.fused)
    }

    @Test
    func orderingBreaksTiesBySemanticThenRowID() {
        let breakdown = RankBreakdown(semantic: 0.5, bpm: 0.5, key: 0.5, energy: 0.5,
                                      phrase: 0.5, fused: 0.5)
        let a = RankedMatch(rowID: 2, semantic: 0.5, breakdown: breakdown)
        let b = RankedMatch(rowID: 1, semantic: 0.5, breakdown: breakdown)
        let ordered = HybridRankerOrdering.order([a, b])
        #expect(ordered.map(\.rowID) == [1, 2])
    }
}
