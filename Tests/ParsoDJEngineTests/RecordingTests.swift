import Testing
import Foundation
import ParsoAudioCore
import ParsoDJEngine
import ParsoTestSupport

@Suite("MixRecorder")
@MainActor
struct MixRecorderTests {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    @Test func recordsMasterBlocksToWAV() throws {
        let source = SignalGenerators.sine(frequency: 440, seconds: 0.25, channels: 2)
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = try MixRecorder(codec: .wavPCM(bitDepth: 24), url: url)
        recorder.start()
        recorder.append(source)
        recorder.append(source)
        try recorder.stop()

        let output = try AudioFileReader(url: url, container: .wav).readAll()
        #expect(output.frameCount == source.frameCount * 2)
        #expect(Measure.dominantFrequency(output, searchRange: 300...600) == 440)
        #expect(!recorder.isRecording)
    }

    @Test func recordsMasterBlocksToFLAC() throws {
        let source = SignalGenerators.sine(frequency: 220, seconds: 0.1, channels: 2)
        let url = tempURL("flac")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = try MixRecorder(codec: .flac(compression: 5), url: url)
        recorder.start()
        recorder.append(source)
        try recorder.stop()

        let output = try AudioFileReader(url: url, container: .flac).readAll()
        #expect(output.frameCount == source.frameCount)
        #expect(output.channel(0)[100] == source.channel(0)[100])
    }
}
