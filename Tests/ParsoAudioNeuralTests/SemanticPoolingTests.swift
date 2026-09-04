#if !os(watchOS)
import Foundation
import Testing
@testable import ParsoAudioNeural

@Suite
struct SemanticPoolingTests {
    @Test
    func meanPoolingIsL2Normalized() {
        let pooled = SemanticPooling.mean([[1, 0, 0], [0, 1, 0]])
        let norm = sqrt(pooled.reduce(Float(0)) { $0 + $1 * $1 })
        #expect(abs(norm - 1) < 0.0001)
    }

    @Test
    func attentionPoolingSingleWindowReturnsItNormalized() {
        let pooled = SemanticPooling.attention([[3, 4, 0]], energy: nil)
        #expect(abs(pooled[0] - 0.6) < 0.001)
        #expect(abs(pooled[1] - 0.8) < 0.001)
    }

    @Test
    func l2NormalizedZeroVectorStaysZero() {
        let out = SemanticPooling.l2Normalized([0, 0, 0])
        #expect(out == [0, 0, 0])
    }
}
#endif
