import Testing
@testable import ParsoAudioPlayback

@Suite("Playback layer")
struct PlaybackLayerTests {
    @Test("layer links")
    func layerLinks() {
        #expect(ParsoAudioPlayback.layerVersion == 1)
    }
}
