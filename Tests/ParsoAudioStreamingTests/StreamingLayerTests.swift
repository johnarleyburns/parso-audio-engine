import Testing
@testable import ParsoAudioStreaming

@Suite("Streaming layer")
struct StreamingLayerTests {
    @Test("layer links")
    func layerLinks() {
        #expect(ParsoAudioStreaming.layerVersion == 1)
    }
}
