#if !os(watchOS)
import Foundation
import Testing
import ParsoAudioAnalysis
@testable import ParsoAudioNeural

@Suite
struct StemChunkingTests {
    @Test
    func periodicHannIsFirstPowerCOLAAtHalfOverlap() {
        let n = 256
        let window = StemChunking.window(n)
        let hop = n / 2
        for i in 0..<hop {
            let sum = window[i] + window[i + hop]
            #expect(abs(sum - 1) < 0.0001)
        }
    }
}

/// A model that echoes its input chunk back unchanged on every voice — the
/// simplest possible conformance, used to pin the separator's chunk/overlap-add
/// reconstruction independent of any real model.
private struct PassthroughModel: StemModelProviding {
    let version = 0
    var available = true

    func isAvailable() async -> Bool { available }

    func separate(chunk: StemChunk) async throws -> StemSeparation? {
        guard available else { return nil }
        return StemSeparation(sampleRate: chunk.sampleRate,
                              vocals: chunk, drums: chunk, bass: chunk, other: chunk)
    }
}

@Suite
struct StemSeparatorTests {
    @Test
    func passthroughModelReconstructsInputInTheInterior() async throws {
        let chunkFrames = 4096
        let separator = StemSeparator(model: PassthroughModel(), chunkFrames: chunkFrames)
        let frameCount = chunkFrames * 3
        var samples = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount { samples[i] = sin(Float(i) * 0.01) }
        let pcm = AnalysisAudio(sampleRate: StemChunking.workingSampleRate,
                                channels: [samples, samples])

        let separation = try await separator.separate(pcm: pcm)
        let vocals = try #require(separation)

        // Away from the very first/last hop (edge taper), the passthrough
        // reconstruction should match the input closely.
        let margin = chunkFrames / 2
        for i in stride(from: margin, to: frameCount - margin, by: 97) {
            #expect(abs(vocals.vocals.left[i] - samples[i]) < 0.01)
        }
    }

    @Test
    func absentModelYieldsNilNotAnError() async throws {
        let separator = StemSeparator(model: PassthroughModel(available: false), chunkFrames: 4096)
        let pcm = AnalysisAudio(sampleRate: StemChunking.workingSampleRate,
                                channels: [[Float](repeating: 0, count: 4096)])
        let separation = try await separator.separate(pcm: pcm)
        #expect(separation == nil)
    }

    @Test
    func emptyInputThrows() async throws {
        let separator = StemSeparator(model: PassthroughModel(), chunkFrames: 4096)
        let pcm = AnalysisAudio(sampleRate: StemChunking.workingSampleRate, channels: [[]])
        await #expect(throws: StemSeparatorError.self) {
            _ = try await separator.separate(pcm: pcm)
        }
    }
}

@Suite
struct SeparationBackendRegistryTests {
    @Test
    func defaultActiveIDIsSpleeter() async {
        let registry = SeparationBackendRegistry()
        let id = await registry.activeID
        #expect(id == .spleeter)
    }

    @Test
    func activeModelThrowsWhenNothingIsRegistered() async {
        let registry = SeparationBackendRegistry()
        await #expect(throws: SeparationBackendError.self) {
            _ = try await registry.activeModel()
        }
    }

    @Test
    func registerAndSwapActiveBackend() async throws {
        let registry = SeparationBackendRegistry()
        await registry.register(.spleeter) { PassthroughModel() }
        let custom = SeparationBackendID(rawValue: "future-bs-roformer")
        await registry.register(custom) { PassthroughModel(available: false) }

        _ = try await registry.activeModel() // spleeter, registered above
        try await registry.setActive(custom)
        let id = await registry.activeID
        #expect(id == custom)
        let model = try await registry.activeModel()
        let available = await model.isAvailable()
        #expect(available == false)
    }

    @Test
    func setActiveThrowsForUnregisteredID() async {
        let registry = SeparationBackendRegistry()
        let unknown = SeparationBackendID(rawValue: "does-not-exist")
        await #expect(throws: SeparationBackendError.self) {
            try await registry.setActive(unknown)
        }
    }
}
#endif
