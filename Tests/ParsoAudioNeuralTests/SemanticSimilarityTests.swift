import Testing
import ParsoAudioNeural

@Suite("Transition semantic similarity")
struct SemanticSimilarityTests {
    @Test func cosineBasicsAndNormalization() {
        #expect(SemanticSimilarity.cosine([1, 0], [1, 0]) == 1)
        #expect(SemanticSimilarity.cosine([1, 0], [-1, 0]) == -1)
        #expect(SemanticSimilarity.cosine([1, 0], [0, 1]) == 0)
        #expect(SemanticSimilarity.cosine([], []) == 0)
        #expect(SemanticSimilarity.normalizedCosine([1, 0], [-1, 0]) == 0)
    }
}
