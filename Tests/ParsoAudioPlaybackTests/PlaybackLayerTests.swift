import Testing
@testable import ParsoAudioPlayback

@Suite("Playback layer")
struct PlaybackLayerTests {
    @Test("layer links")
    func layerLinks() {
        #expect(ParsoAudioPlaybackLayer.layerVersion == 1)
    }
}
