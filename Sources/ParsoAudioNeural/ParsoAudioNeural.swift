//
//  ParsoAudioNeural.swift
//  On-device neural model plumbing: a caller-supplied-weights seam for
//  CoreML-backed audio features (semantic/mood search, source separation),
//  deliberately watchOS-excluded (Phase 7a, docs/UNIFICATION_PLAN.md §8,
//  current_status.md "Phase 7").
//
//  This target ships NO model weights and never will — it is a library, not
//  an app, and has no On-Demand Resources mechanism of its own. It defines
//  the protocol surface a consumer (an app, with its own ODR-delivered
//  `.mlpackage`) conforms its concrete model to. This mirrors the seam
//  `parso-tonearm` already built for its Demucs/CLAP models
//  (`StemModelProviding`/`ModelResourceProviding`) rather than inventing a
//  new shape.
//
//  Why `#if !os(watchOS)` and not `#if canImport(CoreML)`: unlike
//  AudioToolbox (genuinely absent from the watchOS SDK, gated in
//  ParsoAudioCore.swift with plain `canImport`), CoreML **is** present on
//  watchOS 10 — so `canImport(CoreML)` alone would not exclude it. The
//  explicit `!os(watchOS)` form is the one already used for
//  ParsoAudioStreaming/CachingResourceLoader.swift and
//  ParsoAudioPlayback/EQTapInstaller.swift, both APIs that are technically
//  importable on watchOS but not meant to be used there.
//
#if !os(watchOS)
import CoreML
import Foundation

/// A model whose weights the *caller* supplies — this package never bundles
/// or points at a specific model's binary weights.
public protocol NeuralModelProviding: Sendable {
    /// Whether the caller-supplied weights are currently resolvable (e.g. an
    /// On-Demand Resource has finished downloading). Consumers should treat
    /// `false` as a normal, expected state — degrade gracefully, never throw.
    var isAvailable: Bool { get async }

    /// The on-disk location of a compiled `.mlmodelc` or `.mlpackage`, valid
    /// only when `isAvailable` is `true`.
    func modelURL() async throws -> URL
}

public enum NeuralModelError: Error, Equatable, Sendable {
    /// `modelURL()` was called while `isAvailable` was `false`.
    case modelUnavailable
    /// The file at `modelURL()` failed to load as a Core ML model.
    case loadFailed(String)
}

/// `MLModel` is not `Sendable` (it's a plain `NSObject`). Inference itself is
/// documented thread-safe by Apple, so this box carries it across the actor
/// boundary under that documented guarantee — same pattern as PAE's other
/// `@unchecked Sendable` boundary types (`PCMBuffer`, `TimePitch`; see
/// docs/UNIFICATION_PLAN.md §5).
public final class NeuralModel: @unchecked Sendable {
    public let mlModel: MLModel
    init(_ mlModel: MLModel) { self.mlModel = mlModel }
}

/// Loads and caches a `MLModel` from a `NeuralModelProviding` source.
///
/// Deliberately minimal (mirrors the Phase 3 `EQTapInstaller` author
/// decision): this does inference-graph-agnostic loading only. Per-feature
/// pre/post-processing (STFT/ISTFT framing, tokenization, embedding
/// projection) is Phase 7b/7c scope, layered on top of this, not in it.
public actor NeuralModelLoader {
    private let source: any NeuralModelProviding
    private let computeUnits: MLComputeUnits
    private var cached: NeuralModel?

    public init(source: any NeuralModelProviding, computeUnits: MLComputeUnits = .all) {
        self.source = source
        self.computeUnits = computeUnits
    }

    /// Returns the loaded model, loading (and caching) it on first use.
    /// Throws `.modelUnavailable` rather than blocking if the caller's
    /// weights aren't resolvable yet — this must never be a busy-wait.
    public func model() async throws -> NeuralModel {
        if let cached { return cached }
        guard await source.isAvailable else { throw NeuralModelError.modelUnavailable }
        let url = try await source.modelURL()
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        do {
            let model = NeuralModel(try MLModel(contentsOf: url, configuration: config))
            cached = model
            return model
        } catch {
            throw NeuralModelError.loadFailed(String(describing: error))
        }
    }

    /// Drops the cached model (e.g. weights were evicted/updated).
    public func invalidate() {
        cached = nil
    }
}
#endif
