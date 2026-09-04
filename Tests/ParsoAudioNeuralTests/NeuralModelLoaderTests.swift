#if !os(watchOS)
import Foundation
import Testing
@testable import ParsoAudioNeural

private struct UnavailableSource: NeuralModelProviding {
    var isAvailable: Bool { get async { false } }
    func modelURL() async throws -> URL { throw NeuralModelError.modelUnavailable }
}

private struct MissingFileSource: NeuralModelProviding {
    var isAvailable: Bool { get async { true } }
    func modelURL() async throws -> URL {
        URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mlmodelc")
    }
}

@Suite
struct NeuralModelLoaderTests {
    @Test
    func modelThrowsUnavailableWhenSourceIsNotReady() async throws {
        let loader = NeuralModelLoader(source: UnavailableSource())
        await #expect(throws: NeuralModelError.modelUnavailable) {
            _ = try await loader.model()
        }
    }

    @Test
    func modelWrapsLoadFailureRatherThanCrashing() async throws {
        let loader = NeuralModelLoader(source: MissingFileSource())
        await #expect(throws: (any Error).self) {
            _ = try await loader.model()
        }
    }
}
#endif
