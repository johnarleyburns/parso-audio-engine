//
//  Semantic.swift
//  CLAP-style text/audio semantic embedding plumbing (Phase 7b), ported from
//  parso-tonearm/Sources/DJ/Semantic/EmbeddingModel.swift. See ATTRIBUTION.md.
//
//  Licensing note: the checkpoint this was built against
//  (`music_audioset_epoch_15_esc_90.14.pt`, LAION CLAP / HTSAT-base) ships
//  weights under Apache-2.0 — independently verified, not merely self-tagged
//  (see current_status.md "Phase 7b"). No weights ship in this target; the
//  caller supplies a converted `.mlpackage` via `NeuralModelProviding`.
//
#if !os(watchOS)
import CoreML
import CryptoKit
import Foundation

/// How per-window vectors are pooled into a whole-track vector. Recorded in
/// callers' embedding-version bookkeeping so results stay interpretable
/// across model upgrades.
public enum EmbeddingPooling: String, Sendable, Equatable, Codable {
    case mean
    case attention
}

/// Everything the preprocessor and the embedder need to know about the active
/// model. The real model's values come from the conversion tool's
/// `model_spec.json`; a deterministic fake spec is fine for tests.
public struct EmbeddingModelSpec: Sendable, Equatable {
    public var modelName: String
    public var dimensions: Int
    public var sampleRate: Double
    public var windowSeconds: Double
    public var hopSeconds: Double
    public var fftSize: Int
    public var hopSize: Int
    public var melBins: Int
    public var lowHz: Double
    public var highHz: Double
    /// Samples per encoder clip (`windowSeconds * sampleRate`).
    public var clipSamples: Int
    /// STFT frames per clip: `clipSamples / hopSize + 1`.
    public var frames: Int
    /// Window-count cap with uniform sub-sampling.
    public var maxWindows: Int
    public var textMaxLength: Int
    public var pooling: EmbeddingPooling
    /// The model's mel filterbank, row-major `[fftSize/2+1][melBins]` Float32.
    /// Empty in `musicCLAPMetadata`; filled by `musicCLAP(melFilterBank:)`.
    public var melFilterBank: [Float]

    public init(modelName: String,
                dimensions: Int,
                sampleRate: Double,
                windowSeconds: Double,
                hopSeconds: Double,
                fftSize: Int,
                hopSize: Int,
                melBins: Int,
                lowHz: Double,
                highHz: Double,
                clipSamples: Int,
                frames: Int,
                maxWindows: Int,
                textMaxLength: Int,
                pooling: EmbeddingPooling,
                melFilterBank: [Float]) {
        self.modelName = modelName
        self.dimensions = dimensions
        self.sampleRate = sampleRate
        self.windowSeconds = windowSeconds
        self.hopSeconds = hopSeconds
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.melBins = melBins
        self.lowHz = lowHz
        self.highHz = highHz
        self.clipSamples = clipSamples
        self.frames = frames
        self.maxWindows = maxWindows
        self.textMaxLength = textMaxLength
        self.pooling = pooling
        self.melFilterBank = melFilterBank
    }

    /// The reference music-CLAP model (LAION CLAP, HTSAT-base music/AudioSet
    /// checkpoint, Apache-2.0). The mel filterbank is not embedded here; load
    /// it with `loadMelFilterBank` and call `musicCLAP(melFilterBank:)`.
    public static let musicCLAPMetadata = EmbeddingModelSpec(
        modelName: "music_audioset_epoch_15_esc_90.14",
        dimensions: 512,
        sampleRate: 48_000,
        windowSeconds: 10,
        hopSeconds: 5,
        fftSize: 1024,
        hopSize: 480,
        melBins: 64,
        lowHz: 50,
        highHz: 14_000,
        clipSamples: 480_000,
        frames: 1_001,
        maxWindows: 240,
        textMaxLength: 77,
        pooling: .attention,
        melFilterBank: [])

    public static func musicCLAP(melFilterBank: [Float]) -> EmbeddingModelSpec {
        var spec = musicCLAPMetadata
        spec.melFilterBank = melFilterBank
        return spec
    }

    /// Read the raw Float32 mel filterbank (`fftSize/2+1 × melBins`,
    /// little-endian, row-major) the conversion tool dumps next to the model spec.
    public static func loadMelFilterBank(from url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Float.self).map { Float($0) }
        }
    }
}

public enum SemanticModelError: Error, LocalizedError, Equatable {
    case modelUnavailable(String)
    case modelLoadFailed(String)
    case inferenceFailed(String)
    case tokenizerUnavailable

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let name): return "The \(name) model is not downloaded."
        case .modelLoadFailed(let detail): return "Could not load the model: \(detail)"
        case .inferenceFailed(let detail): return "Model inference failed: \(detail)"
        case .tokenizerUnavailable: return "The text tokenizer is not available."
        }
    }
}

/// The seam between every downstream stage (preprocess, pooling, quantization,
/// search) and the CLAP encoders. Everything above this protocol is identical
/// for both conformances below.
public protocol SemanticModel: Sendable {
    var spec: EmbeddingModelSpec { get }
    /// Embed a text query into the shared `dimensions`-D space, L2-normalized.
    func embedText(_ text: String) async throws -> [Float]
    /// Embed one log-mel window (`spec.frames × spec.melBins` row-major) into
    /// the shared space, L2-normalized.
    func embedAudio(logMel: [Float]) async throws -> [Float]
}

/// Loads the converted `.mlpackage` from a caller-provided URL: the model is
/// never in this binary, and every embed is "not available" until a real file
/// exists at `url`.
public actor CoreMLSemanticModel: SemanticModel {
    public enum EncoderKind: Sendable {
        case audio
        case text
    }

    public let spec: EmbeddingModelSpec
    private let kind: EncoderKind
    private let url: URL
    private let tokenizer: RoBERTaTokenizer?
    private let computeUnits: MLComputeUnits
    private var box: ModelBox?

    /// Core ML's `MLModel` is not `Sendable`, yet the modern `prediction(from:)`
    /// is `async` and demands a `Sendable` receiver. The model is only ever
    /// touched inside this actor, so an `@unchecked Sendable` box is honest:
    /// the box itself is Sendable, and the actor serializes every use of its
    /// payload — the same pattern as PAE's other `@unchecked Sendable`
    /// boundary types (`NeuralModel`, `PCMBuffer`).
    private final class ModelBox: @unchecked Sendable {
        let model: MLModel
        init(_ model: MLModel) { self.model = model }
    }

    /// - Parameters:
    ///   - kind: which encoder this instance wraps (drives I/O names + compute target).
    ///   - url: location of the `.mlpackage` once the caller's weights are available.
    ///   - tokenizer: required for `.text`; ignored for `.audio`.
    ///   - computeUnits: defaults follow how each model was converted — the audio
    ///     encoder (HTSAT) is not ANE-compilable (CPU+GPU), the text encoder is `all`.
    public init(kind: EncoderKind,
                url: URL,
                spec: EmbeddingModelSpec,
                tokenizer: RoBERTaTokenizer? = nil,
                computeUnits: MLComputeUnits? = nil) {
        self.kind = kind
        self.url = url
        self.spec = spec
        self.tokenizer = tokenizer
        self.computeUnits = computeUnits ?? (kind == .audio ? .cpuAndGPU : .all)
    }

    public func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func embedText(_ text: String) async throws -> [Float] {
        let modelBox = try load()
        guard kind == .text else {
            throw SemanticModelError.inferenceFailed("text input on an audio encoder")
        }
        guard let tokenizer else { throw SemanticModelError.tokenizerUnavailable }
        let encoded = try tokenizer.encode(text, maxLength: spec.textMaxLength)
        let ids = try MLMultiArray(shape: [1, NSNumber(value: spec.textMaxLength)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: spec.textMaxLength)], dataType: .int32)
        for i in 0..<encoded.ids.count {
            ids[i] = NSNumber(value: encoded.ids[i])
            mask[i] = NSNumber(value: encoded.mask[i])
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        return try await Self.predict(modelBox, provider: provider,
                                       outputName: "text_embedding", count: spec.dimensions)
    }

    public func embedAudio(logMel: [Float]) async throws -> [Float] {
        let modelBox = try load()
        guard kind == .audio else {
            throw SemanticModelError.inferenceFailed("audio input on a text encoder")
        }
        let total = spec.frames * spec.melBins
        guard logMel.count == total else {
            throw SemanticModelError.inferenceFailed(
                "log-mel has \(logMel.count) samples, expected \(total)")
        }
        let input = try MLMultiArray(shape: [1, 1, NSNumber(value: spec.frames),
                                            NSNumber(value: spec.melBins)],
                                     dataType: .float32)
        for i in 0..<total { input[i] = NSNumber(value: logMel[i]) }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "log_mel": MLFeatureValue(multiArray: input),
        ])
        return try await Self.predict(modelBox, provider: provider,
                                       outputName: "audio_embedding", count: spec.dimensions)
    }

    private func load() throws -> ModelBox {
        if let box { return box }
        guard isAvailable() else {
            throw SemanticModelError.modelUnavailable(url.lastPathComponent)
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            let loaded = try MLModel(contentsOf: url, configuration: configuration)
            let box = ModelBox(loaded)
            self.box = box
            return box
        } catch {
            throw SemanticModelError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Runs the prediction and extracts the output outside actor isolation:
    /// `MLModel.prediction(from:)`'s non-Sendable `MLFeatureProvider` result
    /// can't cross back into the actor, so only the Sendable `[Float]` does.
    private static func predict(_ box: ModelBox, provider: MLDictionaryFeatureProvider,
                                 outputName: String, count: Int) async throws -> [Float] {
        let output = try await box.model.prediction(from: provider)
        guard let value = output.featureValue(for: outputName)?.multiArrayValue else {
            throw SemanticModelError.inferenceFailed("missing \(outputName) output")
        }
        return extract(value, count: count)
    }

    private static func extract(_ multiArray: MLMultiArray, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = multiArray[i].floatValue }
        return out
    }
}

/// Seeded, SHA-256-based pseudo-embedding — tests and goldens only, never
/// production. Deterministic across runs and platforms: same seed + same
/// input → same bytes.
public struct DeterministicFakeSemanticModel: SemanticModel {
    public let spec: EmbeddingModelSpec
    public let seed: Data

    public init(spec: EmbeddingModelSpec, seed: Data = Data("fake-clap-v1".utf8)) {
        self.spec = spec
        self.seed = seed
    }

    public func embedText(_ text: String) async throws -> [Float] {
        Self.pseudoEmbedding(from: Data(text.utf8), seed: seed, dims: spec.dimensions)
    }

    public func embedAudio(logMel: [Float]) async throws -> [Float] {
        let bytes = logMel.withUnsafeBytes { Data($0) }
        return Self.pseudoEmbedding(from: bytes, seed: seed, dims: spec.dimensions)
    }

    /// Hash the payload + seed into `dims` floats in [-1, 1), L2-normalized.
    /// Dim i hashes `seed || payload || 4-byte-BE-i`, so the vector is a
    /// deterministic function of its content alone.
    public static func pseudoEmbedding(from payload: Data, seed: Data, dims: Int) -> [Float] {
        var out = [Float](repeating: 0, count: dims)
        for i in 0..<dims {
            let counter = [UInt8(truncatingIfNeeded: i >> 24),
                           UInt8(truncatingIfNeeded: i >> 16),
                           UInt8(truncatingIfNeeded: i >> 8),
                           UInt8(truncatingIfNeeded: i)]
            var material = seed
            material.append(payload)
            material.append(contentsOf: counter)
            let digest = SHA256.hash(data: material)
            let u = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            out[i] = Float((Double(u) / Double(UInt32.max)) * 2 - 1)
        }
        return l2Normalized(out)
    }

    public static func l2Normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}

/// Serializes text/audio predictions through a `SemanticModel`. The actor
/// gives the encoder concurrency-1 (the ANE serializes anyway); preprocessing
/// can still pipeline ahead of it because only `embed*` is actor-isolated.
public actor CLAPEmbedder {
    private let model: any SemanticModel

    /// The active model's spec — what preprocessing and the caller's store
    /// must agree with.
    public nonisolated var spec: EmbeddingModelSpec { model.spec }

    public init(model: any SemanticModel) {
        self.model = model
    }

    /// Embed a text query → L2-normalized (idempotent: the models already
    /// normalize; the re-normalization guards the fake and any future non-L2 model).
    public func embedText(_ text: String) async throws -> [Float] {
        DeterministicFakeSemanticModel.l2Normalized(try await model.embedText(text))
    }

    /// Embed each window → one L2-normalized vector per window.
    public func embedWindows(_ windows: [SemanticPreprocess.MelWindow]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(windows.count)
        for window in windows {
            out.append(DeterministicFakeSemanticModel.l2Normalized(
                try await model.embedAudio(logMel: window.logMel)))
        }
        return out
    }
}
#endif
