//
//  DemucsStemModelForAcceptance.swift
//  A tool-local `StemModelProviding` conformance that loads a
//  `DemucsStems.mlpackage` directly from a filesystem path. Mirrors
//  parso-tonearm's `DemucsStemModel` (Sources/DJ/Stems/StemModel.swift) but
//  drops its app-specific plumbing (ODR resource resolution, device-memory
//  ceiling gating) that this acceptance harness has no use for. See
//  ATTRIBUTION.md.
//
import CoreML
import Accelerate
import Foundation
import ParsoAudioNeural

public actor DemucsStemModelForAcceptance: StemModelProviding {
    public nonisolated let version: Int = 1
    public nonisolated let nativeSampleRate: Double = DemucsSpectrogram.sampleRate
    public nonisolated let segmentFrames: Int = DemucsSpectrogram.segmentFrames
    private let modelURL: URL
    private var engine: CoreMLModelBox?

    public init(modelURL: URL) {
        self.modelURL = modelURL
    }

    public func isAvailable() async -> Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// The model's source axis order — matches tonearm's `DemucsStemModel`
    /// exactly (locked there by `DemucsStemModelTests`); getting this wrong
    /// silently swaps every stem.
    private static let sourceOrder: [SeparationVoice] = [.drums, .bass, .other, .vocals]

    public func separate(chunk: StemChunk) async throws -> StemSeparation? {
        guard await isAvailable() else { return nil }
        guard chunk.frameCount == segmentFrames else {
            throw StemModelError.inferenceFailed(
                "chunk is \(chunk.frameCount) frames, the model expects \(segmentFrames)")
        }
        let engine = try await loadedModel()
        let (spec, waveform) = try await Self.predict(chunk: chunk, engine: engine)
        return try handleOutput(spec: spec, waveform: waveform, chunk: chunk)
    }

    private nonisolated static func predict(
        chunk: StemChunk, engine: CoreMLModelBox
    ) async throws -> (spec: [Float], waveform: [Float]) {
        let frames = DemucsSpectrogram.frames
        let segmentFrames = DemucsSpectrogram.segmentFrames
        let bins = DemucsSpectrogram.bins
        guard let mag = try? MLMultiArray(shape: [1, 4, bins, frames] as [NSNumber],
                                          dataType: .float32),
              let audio = try? MLMultiArray(shape: [1, 2, segmentFrames] as [NSNumber],
                                            dataType: .float32) else {
            throw StemModelError.inferenceFailed("could not allocate the model inputs")
        }
        let magValues = DemucsSpectrogram.forward(left: chunk.left, right: chunk.right)
        magValues.withUnsafeBufferPointer { src in
            mag.dataPointer.assumingMemoryBound(to: Float.self)
                .update(from: src.baseAddress!, count: magValues.count)
        }
        let audioPtr = audio.dataPointer.assumingMemoryBound(to: Float.self)
        chunk.left.withUnsafeBufferPointer { src in
            audioPtr.update(from: src.baseAddress!, count: chunk.left.count)
        }
        chunk.right.withUnsafeBufferPointer { src in
            audioPtr.advanced(by: segmentFrames).update(from: src.baseAddress!, count: chunk.right.count)
        }

        let features = try MLDictionaryFeatureProvider(dictionary: [
            "mag": MLFeatureValue(multiArray: mag),
            "audio": MLFeatureValue(multiArray: audio),
        ])
        let output: MLFeatureProvider
        do {
            output = try await engine.model.prediction(from: features)
        } catch {
            throw StemModelError.inferenceFailed("the Core ML prediction failed: \(error)")
        }
        guard let specValue = output.featureValue(for: "spec")?.multiArrayValue,
              let waveformValue = output.featureValue(for: "waveform")?.multiArrayValue else {
            throw StemModelError.inferenceFailed("the model output was missing `spec` or `waveform`")
        }
        return (flatten(specValue), flatten(waveformValue))
    }

    private func handleOutput(spec: [Float], waveform: [Float],
                              chunk: StemChunk) throws -> StemSeparation {
        let bins = DemucsSpectrogram.bins
        let frames = DemucsSpectrogram.frames
        let specPlane = 4 * bins * frames
        let wavePlane = 2 * segmentFrames
        guard spec.count == 4 * specPlane, waveform.count == 4 * wavePlane else {
            throw StemModelError.inferenceFailed("unexpected model output shapes")
        }

        var voices: [SeparationVoice: StemChunk] = [:]
        for s in 0..<4 {
            let inv = spec.withUnsafeBufferPointer { buf in
                DemucsSpectrogram.inverse(
                    spec: UnsafeBufferPointer(start: buf.baseAddress!.advanced(by: s * specPlane),
                                              count: specPlane))
            }
            let waveBase = s * wavePlane
            let left = addVoice(inv.left, wave: Array(waveform[waveBase ..< waveBase + segmentFrames]))
            let right = addVoice(inv.right,
                                 wave: Array(waveform[waveBase + segmentFrames ..< waveBase + wavePlane]))
            voices[Self.sourceOrder[s]] = StemChunk(sampleRate: chunk.sampleRate, left: left, right: right)
        }
        return StemSeparation(sampleRate: chunk.sampleRate,
                              vocals: voices[.vocals]!, drums: voices[.drums]!,
                              bass: voices[.bass]!, other: voices[.other]!)
    }

    private func loadedModel() async throws -> CoreMLModelBox {
        if let engine { return engine }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do {
            // `MLModel(contentsOf:)` only accepts a compiled `.mlmodelc`; an
            // Xcode app target compiles a bundled `.mlpackage` at build time,
            // but this standalone CLI tool has to do it itself.
            let compiledURL = try await MLModel.compileModel(at: modelURL)
            let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
            let engine = CoreMLModelBox(model)
            self.engine = engine
            return engine
        } catch {
            throw StemModelError.modelLoadFailed("\(error)")
        }
    }

    private func addVoice(_ ispec: [Float], wave: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: ispec.count)
        vDSP_vadd(ispec, 1, wave, 1, &out, 1, vDSP_Length(ispec.count))
        return out
    }

    private static func flatten(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            let src = array.dataPointer.assumingMemoryBound(to: Float.self)
            buffer.baseAddress!.update(from: src, count: count)
            initialized = count
        }
    }
}

/// `MLModel` is documented thread-safe for prediction; this box is the same
/// justified `@unchecked Sendable` pattern used throughout PAE's neural code.
private final class CoreMLModelBox: @unchecked Sendable {
    let model: MLModel
    init(_ model: MLModel) { self.model = model }
}
