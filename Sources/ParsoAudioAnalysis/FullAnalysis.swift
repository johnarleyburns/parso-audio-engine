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

/// Pure pipeline: decode → run every stage → assemble `FullAnalysisResult`.
/// Deterministic for a fixed input (NFR-DET-3).
public enum FullAnalysis {

    /// The `replayGainDB` target the loudness step measures against (§20.1):
    /// −18 LUFS for DJ headroom.
    public static let loudnessTargetLUFS: Double = -18

    public static func run(url: URL) throws -> FullAnalysisResult {
        try run(AnalysisDecoder.decode(url))
    }

    public static func run(_ pcm: AnalysisAudio) -> FullAnalysisResult {
        let loudness = measureLoudness(pcm)

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
                    let chroma = spectra.isEmpty ? HPCP() : KeyDetector.chroma(spectra[idx])
                    let rms = frames.isEmpty ? 0 : frames[idx].rms
                    return BeatFeature(chroma: chroma, energy: rms)
                }
            }
        }

        // Key from per-frame chroma.
        var key: KeyEstimate?
        if !spectra.isEmpty {
            let chromaFrames = spectra.map { KeyDetector.chroma($0) }
            key = KeyDetector.estimate(chromaFrames)
        }

        // Energy curve + scalar (§19.4 `energy_curve` — carried, not discarded).
        var energy: EnergyResult?
        if let beatGrid, !frames.isEmpty {
            let curve = EnergyAnalyzer.curve(frames: frames, beatSamples: beatGrid.beatSamples,
                                             frameRateHz: 1 / hopSeconds,
                                             sampleRate: stft.sampleRate)
            energy = EnergyResult(scalar: EnergyAnalyzer.scalar(curve),
                                  curve: curve, hopSeconds: hopSeconds)
        }

        // Phrases.
        var phrases: [Phrase] = []
        if !beatFeatures.isEmpty && !downbeatIndices.isEmpty, let beatGrid {
            phrases = PhraseSegmenter.segment(features: beatFeatures,
                                              beats: beatGrid.beatSamples,
                                              downbeats: downbeatIndices,
                                              sampleRate: stft.sampleRate)
        }

        // Waveform pyramid.
        let waveform = WaveformPyramidBuilder.build(pcm.mono, sampleRate: stft.sampleRate)

        return FullAnalysisResult(loudness: loudness, bpm: bpm, key: key,
                                  beatGrid: beatGrid, downbeats: downbeatIndices,
                                  phrases: phrases, energy: energy,
                                  waveform: waveform, hopSeconds: hopSeconds)
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
