//
//  FullAnalysis.swift
//  The 12-step Stage-1 analysis sequence, ported from parso-tonearm's
//  `AnalyzePipeline.run` (Sources/DJ/Analysis/AnalysisCoordinator.swift) minus
//  its GRDB coupling (audio-engine unification, docs/UNIFICATION_PLAN.md §4
//  Phase 5). Every stage degrades gracefully — a stage that cannot run leaves
//  its field nil rather than failing the whole analysis; only decode is fatal.
//

import Foundation
import ParsoAudioCore

/// Non-fatal aggregate of every Stage-1 analysis stage.
public struct FullAnalysisResult: Sendable {
    /// BS.1770-4 / EBU R128 loudness (`ParsoAudioCore.LoudnessAnalyzer`,
    /// libebur128) measured against a −18 LUFS DJ-headroom target.
    public var loudness: LoudnessResult
    public var bpm: Double?
    public var key: KeyEstimate?
    /// The detected beat grid (sample positions at the 48 kHz analysis rate).
    public var beatGrid: BeatGrid?
    /// Beat indices that start bars.
    public var downbeats: [Int]
    /// Bar-aligned phrase segmentation.
    public var phrases: [Phrase]
    /// Per-beat energy curve + scalar (nil when there is no beat grid).
    public var energy: EnergyResult?
    /// Band-split waveform pyramid.
    public var waveform: WaveformPyramid?
    /// The STFT hop-seconds every frame-rate quantity above was measured at.
    public var hopSeconds: Double

    public var phraseCount: Int { phrases.count }
    public var waveformLevels: Int { waveform?.levels.count ?? 0 }

    public init(loudness: LoudnessResult,
                bpm: Double? = nil,
                key: KeyEstimate? = nil,
                beatGrid: BeatGrid? = nil,
                downbeats: [Int] = [],
                phrases: [Phrase] = [],
                energy: EnergyResult? = nil,
                waveform: WaveformPyramid? = nil,
                hopSeconds: Double = 0) {
        self.loudness = loudness
        self.bpm = bpm
        self.key = key
        self.beatGrid = beatGrid
        self.downbeats = downbeats
        self.phrases = phrases
        self.energy = energy
        self.waveform = waveform
        self.hopSeconds = hopSeconds
    }
}

public enum FullAnalysisStage: String, Codable, Sendable {
    case decoding, loudness, spectral, tempo, beatGrid, key, energy, structure, waveform, complete
}

public struct FullAnalysisProgress: Sendable {
    public var stage: FullAnalysisStage
    public var fraction: Double

    public init(stage: FullAnalysisStage, fraction: Double) {
        self.stage = stage
        self.fraction = max(0, min(1, fraction))
    }
}

public enum FullAnalysisEvent: Sendable {
    case progress(FullAnalysisProgress)
    case waveform(WaveformPyramid)
    case tempo(Double?)
    case beatGrid(BeatGrid?, downbeats: [Int])
    case key(KeyEstimate?)
    case phrases([Phrase])
    case complete(FullAnalysisResult)
}

/// Pure pipeline: decode → run every stage → assemble `FullAnalysisResult`.
/// Deterministic for a fixed input (NFR-DET-3).
public enum FullAnalysis {

    /// The `replayGainDB` target the loudness step measures against (§20.1):
    /// −18 LUFS for DJ headroom.
    public static let loudnessTargetLUFS: Double = -18

    public static func run(url: URL) throws -> FullAnalysisResult {
        try run(AnalysisDecoder.decode(url))
    }

    /// Runs the same pipeline as `run(url:)` on a detached task. Cancellation
    /// is checked between the real decode, feature, tempo, key, energy,
    /// structure, and waveform boundaries; no completion event is published
    /// after cancellation.
    public static func analyze(url: URL) -> AsyncThrowingStream<FullAnalysisEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: nil) {
                do {
                    try Task.checkCancellation()
                    continuation.yield(.progress(FullAnalysisProgress(stage: .decoding,
                                                                       fraction: 0)))
                    let pcm = try AnalysisDecoder.decode(url)
                    try Task.checkCancellation()
                    continuation.yield(.progress(FullAnalysisProgress(stage: .decoding,
                                                                       fraction: 1)))
                    let result = try runInternal(
                        pcm,
                        shouldCancel: { Task.isCancelled },
                        emit: { event in
                            if !Task.isCancelled { continuation.yield(event) }
                        })
                    try Task.checkCancellation()
                    continuation.yield(.progress(FullAnalysisProgress(stage: .complete,
                                                                       fraction: 1)))
                    continuation.yield(.complete(result))
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func run(_ pcm: AnalysisAudio) -> FullAnalysisResult {
        do {
            return try runInternal(pcm, shouldCancel: { false }, emit: nil)
        } catch {
            preconditionFailure("synchronous full analysis was cancelled")
        }
    }

    /// Staged implementation shared by the synchronous and cancellable APIs.
    /// The callback is invoked immediately after the work represented by each
    /// stage, rather than from a later progress-only replay pass.
    private static func runInternal(
        _ pcm: AnalysisAudio,
        shouldCancel: @Sendable () -> Bool,
        emit: (@Sendable (FullAnalysisEvent) -> Void)?
    ) throws -> FullAnalysisResult {
        func checkpoint() throws {
            if shouldCancel() { throw CancellationError() }
        }
        func progress(_ stage: FullAnalysisStage, _ fraction: Double) throws {
            try checkpoint()
            emit?(.progress(FullAnalysisProgress(stage: stage, fraction: fraction)))
        }

        try checkpoint()
        let loudness = measureLoudness(pcm)
        try progress(.loudness, 0.12)

        // STFT → features → onset envelope.
        let stft = STFTConfig()
        let kernel = STFTKernel(config: stft)
        let spectra = kernel.spectra(pcm.mono)
        let hopSeconds = Double(stft.hopSize) / stft.sampleRate

        var frames: [SpectralFrame] = []
        if !spectra.isEmpty {
            frames.reserveCapacity(spectra.count)
            let monoBase = pcm.mono.baseAddress
            let monoCount = pcm.mono.count
            for (i, spec) in spectra.enumerated() {
                let prev = i > 0 ? spectra[i - 1].power : spec.power
                let offset = stft.hopSize * i
                let sliceCount = min(stft.fftSize, max(0, monoCount - offset))
                let slice = UnsafeBufferPointer(
                    start: sliceCount > 0 ? monoBase?.advanced(by: offset) : nil,
                    count: sliceCount)
                frames.append(SpectralFeatures.frame(spec, prevPower: prev, frameSamples: slice))
            }
        }
        try progress(.spectral, 0.30)

        let envelope = OnsetDetector.envelope(spectra: spectra)
        let onsets = hopSeconds > 0
            ? OnsetDetector.peaks(envelope, frameRateHz: 1 / hopSeconds)
            : []
        let tempo = hopSeconds > 0
            ? TempoAnalyzer.estimate(novelty: envelope, hopSeconds: hopSeconds).first
            : nil

        var bpm: Double?
        var beatGrid: BeatGrid?
        var downbeatIndices: [Int] = []
        var beatFeatures: [BeatFeature] = []
        if let tempo {
            bpm = tempo.bpm
            if let grid = BeatTracker.grid(novelty: envelope, hopSeconds: hopSeconds,
                                           sampleRate: stft.sampleRate,
                                           onsets: onsets, bpm: tempo.bpm) {
                beatGrid = grid
                downbeatIndices = BeatTracker.downbeats(beatSamples: grid.beatSamples,
                                                        novelty: envelope,
                                                        hopSeconds: hopSeconds,
                                                        sampleRate: stft.sampleRate)
                // Beat-synchronous features for phrasing (§25.1): chroma of the
                // frame nearest each beat, energy from RMS.
                beatFeatures = grid.beatSamples.map { sample -> BeatFeature in
                    let frame = Int((Double(sample) / stft.sampleRate / hopSeconds).rounded())
                    let idx = max(0, min(spectra.count - 1, frame))
                    let chroma = spectra.isEmpty ? HPCP() : KeyDetector.fusedChroma(spectra[idx])
                    let rms = frames.isEmpty ? 0 : frames[idx].rms
                    return BeatFeature(chroma: chroma, energy: rms)
                }
            }
        }
        try progress(.tempo, 0.46)
        emit?(.tempo(bpm))
        emit?(.beatGrid(beatGrid, downbeats: downbeatIndices))
        try progress(.beatGrid, 0.52)

        // Key from per-frame chroma.
        var key: KeyEstimate?
        if !spectra.isEmpty {
            let chromaFrames = spectra.map { KeyDetector.fusedChroma($0) }
            key = KeyDetector.estimate(chromaFrames)
        }
        try progress(.key, 0.58)
        emit?(.key(key))

        // Energy curve + scalar (§19.4 `energy_curve` — carried, not discarded).
        var energy: EnergyResult?
        if let beatGrid, !frames.isEmpty {
            let curve = EnergyAnalyzer.curve(frames: frames, beatSamples: beatGrid.beatSamples,
                                             frameRateHz: 1 / hopSeconds,
                                             sampleRate: stft.sampleRate)
            energy = EnergyResult(scalar: EnergyAnalyzer.scalar(curve),
                                  curve: curve, hopSeconds: hopSeconds)
        }
        try progress(.energy, 0.69)

        // Phrases.
        var phrases: [Phrase] = []
        if !beatFeatures.isEmpty && !downbeatIndices.isEmpty, let beatGrid {
            phrases = PhraseSegmenter.segment(features: beatFeatures,
                                              beats: beatGrid.beatSamples,
                                              downbeats: downbeatIndices,
                                              sampleRate: stft.sampleRate)
        }
        phrases = addLocalDescriptors(to: phrases, frames: frames,
                                      keyFrames: spectra.map { KeyDetector.fusedChroma($0) },
                                      sampleRate: stft.sampleRate, hopSeconds: hopSeconds)
        try progress(.structure, 0.83)
        emit?(.phrases(phrases))

        // Waveform pyramid.
        let waveform = WaveformPyramidBuilder.build(pcm.mono, sampleRate: stft.sampleRate)
        try progress(.waveform, 0.95)
        emit?(.waveform(waveform))

        return FullAnalysisResult(loudness: loudness, bpm: bpm, key: key,
                                  beatGrid: beatGrid, downbeats: downbeatIndices,
                                  phrases: phrases, energy: energy,
                                  waveform: waveform, hopSeconds: hopSeconds)
    }

    private static func addLocalDescriptors(
        to phrases: [Phrase], frames: [SpectralFrame],
        keyFrames: [HPCP], sampleRate: Double, hopSeconds: Double
    ) -> [Phrase] {
        guard !phrases.isEmpty, !frames.isEmpty, hopSeconds > 0 else { return phrases }
        let maxRMS = max(Double(frames.map { $0.rms }.max() ?? 0), 1e-9)
        let maxFlux = max(Double(frames.map { $0.flux }.max() ?? 0), 1e-9)
        return phrases.map { phrase in
            let first = max(0, Int((Double(phrase.startSample) / sampleRate / hopSeconds).rounded(.down)))
            let last = min(frames.count, max(first + 1,
                Int((Double(phrase.endSample) / sampleRate / hopSeconds).rounded(.up)) + 1))
            guard first < last else { return phrase }
            let local = Array(frames[first..<last])
            let rms = local.reduce(0.0) { $0 + Double($1.rms) } / Double(local.count)
            let brightness = local.reduce(0.0) { $0 + Double($1.centroid) } /
                Double(local.count) / max(1, sampleRate * 0.5)
            let flux = local.reduce(0.0) { $0 + Double($1.flux) } /
                Double(local.count) / maxFlux
            let totalBands = local.reduce(0.0) { partial, frame in
                partial + (0..<8).reduce(0.0) { $0 + Double(frame.bandEnergy[$1]) }
            }
            let bassBands = local.reduce(0.0) { partial, frame in
                partial + (0..<3).reduce(0.0) { $0 + Double(frame.bandEnergy[$1]) }
            }
            let density = local.reduce(0.0) { partial, frame in
                let occupied = (0..<8).filter { frame.bandEnergy[$0] > 1e-8 }.count
                return partial + Double(occupied) / 8
            } / Double(local.count)
            let keyStart = min(first, keyFrames.count)
            let keyEnd = max(keyStart, min(last, keyFrames.count))
            let chroma = Array(keyFrames[keyStart..<keyEnd])
            let localKey = KeyDetector.estimate(chroma).map {
                PortableKey(tonic: $0.tonic, mode: $0.isMinor ? .minor : .major,
                            camelot: $0.camelot.code, confidence: $0.confidence)
            }
            var stability = 0.0
            if !chroma.isEmpty {
                let mean = KeyDetector.aggregate(chroma)
                stability = chroma.reduce(0.0) { partial, value in
                    let dot = zip(mean.values, value.values).reduce(0.0) { $0 + Double($1.0 * $1.1) }
                    let a = sqrt(mean.values.reduce(0.0) { $0 + Double($1 * $1) })
                    let b = sqrt(value.values.reduce(0.0) { $0 + Double($1 * $1) })
                    return partial + (a > 0 && b > 0 ? dot / (a * b) : 0)
                } / Double(chroma.count)
            }
            var result = phrase
            result.descriptors = PhraseLocalDescriptors(
                energy: min(10, max(0, rms / maxRMS * 10)),
                bassEnergy: totalBands > 0 ? bassBands / totalBands : 0,
                brightness: brightness, transientDensity: flux,
                harmonicStability: stability, localKey: localKey,
                spectralDensity: density)
            return result
        }
    }

    /// Bridge the analysis buffer into `ParsoAudioCore.PCMBuffer` and run the
    /// libebur128 loudness measurement (§20).
    static func measureLoudness(_ pcm: AnalysisAudio) -> LoudnessResult {
        guard pcm.frameCount > 0, pcm.channelCount > 0 else {
            return LoudnessResult(integratedLUFS: -.infinity, truePeakDBTP: -.infinity,
                                  gainToTargetDB: .infinity, loudnessRangeLU: 0)
        }
        let core = PCMBuffer(
            format: AudioFormat(sampleRate: pcm.sampleRate, channelCount: pcm.channelCount),
            capacity: pcm.frameCount)
        for c in 0..<pcm.channelCount {
            let dst = core.channel(c)
            let src = pcm.channels[c]
            for i in 0..<pcm.frameCount { dst[i] = src[i] }
        }
        return LoudnessAnalyzer(targetLUFS: loudnessTargetLUFS).measure(core)
    }
}
