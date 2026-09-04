//
//  SpleeterStemModel.swift
//  The default `StemModelProviding` conformance (Phase 7c): a Core ML wrapper
//  around a converted Spleeter `4stems` U-Net. New in this session.
//
//  LICENSING (see current_status.md "Phase 7" for the full trail; this is
//  the author's own determination, not a claim independently re-verified by
//  Claude in a prior investigation this session that found several other
//  "MIT-tagged" separation checkpoints did not hold up under scrutiny —
//  see that section for what was rejected and why): Spleeter
//  (github.com/deezer/spleeter, Deezer Research) ships both its code and its
//  pretrained weights under the MIT license, trained on Deezer's internal
//  (non-MUSDB18) production catalogue. This is the shipping default.
//
//  LIMITATIONS: Spleeter is a 2018-era 2D-U-Net magnitude-masking model —
//  materially behind modern transformer-based separators (BS-RoFormer,
//  Mel-Band RoFormer-class architectures) on separation quality, particularly
//  vocal bleed into `other` and transient smearing on percussive material.
//  It is shipped because it is the best backend currently known to be
//  cleanly commercially licensed, not because it is the best available
//  separator. **The eventual target is a BS-RoFormer-class model** — swap
//  one in the moment a cleanly-licensed release exists, by implementing this
//  same protocol and registering it in `SeparationBackendRegistry` (see that
//  file's header); no other code changes. Track this in
//  parso-audio-engine GitHub issue #2.
//
//  This target ships NO model weights — same policy as every other
//  `ParsoAudioNeural` model seam. A host app supplies a converted
//  `.mlpackage` via its own On-Demand Resources, exactly as it already does
//  for CLAP (`NeuralModelProviding`). The Core ML I/O contract below
//  (`magnitude` in; `<voice>_magnitude` out) is the contract a conversion
//  tool (a `tools/spleeter-coreml`, mirroring the existing
//  `tools/demucs-coreml`/`tools/clap-coreml`) must produce — it does not
//  exist in this repo yet; converting Spleeter's public TensorFlow
//  checkpoint to that shape is a one-time offline step, not something this
//  session executes (same posture as every other "no weights ship" seam).
//
#if !os(watchOS)
import CoreML
import Foundation

/// Loads a converted `SpleeterStems.mlpackage` and runs the STFT → per-channel
/// U-Net inference → ratio-mask → ISTFT pipeline (`SpleeterSpectrogram`) over
/// one `StemSeparator` chunk. The model is loaded once and held.
public actor SpleeterStemModel: StemModelProviding {
    public nonisolated let version: Int
    public nonisolated let nativeSampleRate: Double = SpleeterSpectrogram.sampleRate
    /// Exactly one model patch's worth of samples
    /// (`nfft + (modelFrames - 1) * hop`) — the smallest chunk that produces
    /// no zero-padded trailing patch.
    public nonisolated let segmentFrames: Int =
        SpleeterSpectrogram.nfft + (SpleeterSpectrogram.modelFrames - 1) * SpleeterSpectrogram.hop

    private let source: any NeuralModelProviding
    private let computeUnits: MLComputeUnits
    private var engine: ModelBox?

    private final class ModelBox: @unchecked Sendable {
        let model: MLModel
        init(_ model: MLModel) { self.model = model }
    }

    public init(source: any NeuralModelProviding,
                version: Int = 1,
                computeUnits: MLComputeUnits = .all) {
        self.source = source
        self.version = version
        self.computeUnits = computeUnits
    }

    public func isAvailable() async -> Bool {
        await source.isAvailable
    }

    public func separate(chunk: StemChunk) async throws -> StemSeparation? {
        guard await isAvailable() else { return nil }
        let engine = try await loadedModel()

        let separatedChannels = try await [chunk.left, chunk.right].asyncMap { channel in
            try await Self.separateChannel(channel, length: chunk.frameCount, engine: engine)
        }

        var voices: [SeparationVoice: StemChunk] = [:]
        for kind in SeparationVoice.allCases {
            voices[kind] = StemChunk(sampleRate: chunk.sampleRate,
                                     left: separatedChannels[0][kind]!,
                                     right: separatedChannels[1][kind]!)
        }
        return StemSeparation(sampleRate: chunk.sampleRate,
                              vocals: voices[.vocals]!, drums: voices[.drums]!,
                              bass: voices[.bass]!, other: voices[.other]!)
    }

    /// One channel through the full frontend → model → backend pipeline,
    /// isolated off the actor: `MLModel`/`MLMultiArray` are not `Sendable`.
    private nonisolated static func separateChannel(_ signal: [Float], length: Int,
                                                     engine: ModelBox) async throws -> [SeparationVoice: [Float]] {
        let spectrum = SpleeterSpectrogram.forward(signal)
        let patches = SpleeterSpectrogram.magnitudePatches(spectrum)
        guard !patches.isEmpty else {
            return Dictionary(uniqueKeysWithValues: SeparationVoice.allCases.map {
                ($0, [Float](repeating: 0, count: length))
            })
        }

        // Run every patch through the model, then stitch the per-source
        // magnitude planes back into `frames × modelBins`.
        var stitched: [SeparationVoice: [Float]] = [:]
        for kind in SeparationVoice.allCases {
            stitched[kind] = [Float](repeating: 0,
                                     count: spectrum.frames * SpleeterSpectrogram.modelBins)
        }
        for (index, patch) in patches.enumerated() {
            let predicted = try await predict(patch: patch, engine: engine)
            let start = index * SpleeterSpectrogram.modelFrames
            let framesInPatch = min(SpleeterSpectrogram.modelFrames, spectrum.frames - start)
            for kind in SeparationVoice.allCases {
                stitched[kind]!.withUnsafeMutableBufferPointer { dst in
                    predicted[kind]!.withUnsafeBufferPointer { src in
                        for t in 0..<framesInPatch {
                            let s = t * SpleeterSpectrogram.modelBins
                            let d = (start + t) * SpleeterSpectrogram.modelBins
                            dst.baseAddress!.advanced(by: d)
                                .update(from: src.baseAddress!.advanced(by: s),
                                       count: SpleeterSpectrogram.modelBins)
                        }
                    }
                }
            }
        }

        let maskedSpectra = SpleeterSpectrogram.maskedSpectra(mixture: spectrum,
                                                               predictedMagnitudes: stitched)
        var out: [SeparationVoice: [Float]] = [:]
        for kind in SeparationVoice.allCases {
            out[kind] = SpleeterSpectrogram.inverse(maskedSpectra[kind]!, length: length)
        }
        return out
    }

    /// One patch → the model → four `modelFrames × modelBins` magnitude planes.
    private nonisolated static func predict(patch: [Float],
                                            engine: ModelBox) async throws -> [SeparationVoice: [Float]] {
        guard let input = try? MLMultiArray(
            shape: [1, NSNumber(value: SpleeterSpectrogram.modelFrames),
                    NSNumber(value: SpleeterSpectrogram.modelBins)],
            dataType: .float32) else {
            throw StemModelError.inferenceFailed("could not allocate the model input")
        }
        patch.withUnsafeBufferPointer { src in
            input.dataPointer.assumingMemoryBound(to: Float.self)
                .update(from: src.baseAddress!, count: patch.count)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "magnitude": MLFeatureValue(multiArray: input),
        ])
        let output: MLFeatureProvider
        do {
            output = try await engine.model.prediction(from: provider)
        } catch {
            throw StemModelError.inferenceFailed("the Core ML prediction failed: \(error)")
        }
        var out: [SeparationVoice: [Float]] = [:]
        for kind in SeparationVoice.allCases {
            guard let value = output.featureValue(for: "\(kind.rawValue)_magnitude")?.multiArrayValue else {
                throw StemModelError.inferenceFailed(
                    "the model output was missing `\(kind.rawValue)_magnitude`")
            }
            out[kind] = flatten(value)
        }
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

    private func loadedModel() async throws -> ModelBox {
        if let engine { return engine }
        guard await source.isAvailable else {
            throw StemModelError.modelLoadFailed("weights not resolvable")
        }
        let url = try await source.modelURL()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        do {
            let model = try MLModel(contentsOf: url, configuration: configuration)
            let box = ModelBox(model)
            self.engine = box
            return box
        } catch {
            throw StemModelError.modelLoadFailed("\(error)")
        }
    }
}

extension Sequence {
    /// A small local helper so `separate(chunk:)` can process channels with
    /// `async` work without pulling in a concurrency library dependency.
    fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
#endif
