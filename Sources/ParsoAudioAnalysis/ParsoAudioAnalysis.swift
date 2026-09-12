//
//  ParsoAudioAnalysis.swift
//  The compatibility facade: `TempoResult` / `KeyResult` / `Section` /
//  `Waveform` / `TrackAnalysis` and the `TempoEstimator` / `KeyEstimator` /
//  `StructureAnalyzer` / `WaveformGenerator` / `TrackAnalyzer` estimators keep
//  their exact field names and signatures — `ParsoDJEngine` and PAE's own
//  synthetic / real-fixture tests depend on them.
//
//  Since the audio-engine unification (docs/UNIFICATION_PLAN.md §4 Phase 5) the
//  tempo and key estimators are thin adapters over the Accelerate-backed
//  pipeline ported from `parso-tonearm` (STFTKernel / OnsetDetector /
//  TempoAnalyzer / BeatTracker / KeyDetector …). The hand-rolled scalar Swift
//  FFT that made an un-filtered `swift test` run for ~2 h is gone. Structure and
//  waveform bucketing (no FFT, energy-domain) stay as the deterministic v1.
//

import Foundation
import Accelerate
import ParsoAudioCore

// MARK: - Results

public struct TempoResult: Sendable, Equatable {
    public var bpm: Double
    public var confidence: Double            // 0..1
    public var beatPositions: [TimeInterval] // seconds
    public var downbeatPositions: [TimeInterval]
    public var isConstantTempo: Bool

    public init(
        bpm: Double,
        confidence: Double,
        beatPositions: [TimeInterval],
        downbeatPositions: [TimeInterval],
        isConstantTempo: Bool
    ) {
        self.bpm = bpm
        self.confidence = confidence
        self.beatPositions = beatPositions
        self.downbeatPositions = downbeatPositions
        self.isConstantTempo = isConstantTempo
    }
}

public struct KeyResult: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case major, minor }
    public var tonic: Int                    // 0=C ... 11=B
    public var mode: Mode
    public var camelot: String               // e.g. "8A"
    public var openKey: String               // e.g. "1m"
    public var confidence: Double

    public init(tonic: Int, mode: Mode, camelot: String, openKey: String, confidence: Double) {
        self.tonic = tonic
        self.mode = mode
        self.camelot = camelot
        self.openKey = openKey
        self.confidence = confidence
    }

    /// This key transposed by `semitones` (octave-wrapping), mode preserved.
    /// Used for Key Shift / Key Sync "sounding key" display (CDJ3000 parity C2).
    public func transposed(by semitones: Int) -> KeyResult {
        let shift = ((semitones % 12) + 12) % 12
        guard shift != 0 else { return self }
        let newTonic = (tonic + shift) % 12
        let isMinor = mode == .minor
        let camelotKey = Camelot.from(tonic: newTonic, isMinor: isMinor)
        let open = camelotKey.map { "\((($0.number + 4) % 12) + 1)\(isMinor ? "m" : "d")" }
        return KeyResult(tonic: newTonic, mode: mode,
                         camelot: camelotKey?.code ?? camelot,
                         openKey: open ?? openKey, confidence: confidence)
    }

    /// Smallest semitone shift (−6…+6) that moves this key's tonic onto
    /// `other`'s. Mode is ignored — the CDJ-3000 Key Sync matches pitch class.
    public func shortestShift(to other: KeyResult) -> Int {
        var delta = (other.tonic - tonic) % 12
        if delta > 6 { delta -= 12 }
        if delta < -6 { delta += 12 }
        return delta
    }
}

public struct Section: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case intro, buildup, drop, verse, chorus, breakdown, outro, unknown
    }
    public var start: TimeInterval
    public var kind: Kind
    public var bar: Int

    public init(start: TimeInterval, kind: Kind, bar: Int) {
        self.start = start
        self.kind = kind
        self.bar = bar
    }
}

public struct Waveform: Sendable, Equatable {
    public var overviewMinMax: [SIMD2<Float>]  // .x = min, .y = max
    public var detailRMS: [Float]
    public var bandEnergy: [SIMD3<Float>]      // low, mid, high (for color)

    public init(
        overviewMinMax: [SIMD2<Float>],
        detailRMS: [Float],
        bandEnergy: [SIMD3<Float>]
    ) {
        self.overviewMinMax = overviewMinMax
        self.detailRMS = detailRMS
        self.bandEnergy = bandEnergy
    }
}

public struct TrackAnalysis: Sendable, Equatable {
    public var format: AudioFormat
    public var duration: TimeInterval
    public var tempo: TempoResult
    public var key: KeyResult
    public var sections: [Section]
    public var waveform: Waveform
    public var loudness: LoudnessResult

    public init(
        format: AudioFormat,
        duration: TimeInterval,
        tempo: TempoResult,
        key: KeyResult,
        sections: [Section],
        waveform: Waveform,
        loudness: LoudnessResult
    ) {
        self.format = format
        self.duration = duration
        self.tempo = tempo
        self.key = key
        self.sections = sections
        self.waveform = waveform
        self.loudness = loudness
    }
}

// MARK: - Buffer bridge

enum AnalysisBridge {
    static let analysisRate: Double = AnalysisDecoder.workingSampleRate  // 48 kHz

    /// Resample an incoming `ParsoAudioCore.PCMBuffer` to the 48 kHz analysis
    /// buffer the ported pipeline expects. libsamplerate (sinc-best) when the
    /// rates differ; a straight copy when they already match.
    static func analysisAudio(from buffer: PCMBuffer) -> AnalysisAudio {
        let channelCount = max(1, buffer.channelCount)
        let source = buffer.format.sampleRate

        func channelsFrom(_ pcm: PCMBuffer) -> [[Float]] {
            (0..<max(1, pcm.channelCount)).map { Array(pcm.channel($0)) }
        }

        guard buffer.frameCount > 0 else {
            return AnalysisAudio(sampleRate: analysisRate,
                                 channels: Array(repeating: [Float](), count: channelCount))
        }
        if abs(source - analysisRate) < 0.5 {
            return AnalysisAudio(sampleRate: analysisRate, channels: channelsFrom(buffer))
        }
        let ratio = source > 0 ? analysisRate / source : 0
        if ratio > 1.0 / 256 && ratio < 256,
           let converted = try? SampleRateConverter(from: source, to: analysisRate,
                                                    channels: channelCount, quality: .best)
               .convert(buffer) {
            return AnalysisAudio(sampleRate: analysisRate, channels: channelsFrom(converted))
        }
        // Fallback: linear resample per channel.
        let linRatio = analysisRate / max(1, source)
        let outCount = max(1, Int((Double(buffer.frameCount) * linRatio).rounded()))
        var channels: [[Float]] = []
        for c in 0..<channelCount {
            let src = buffer.channel(c)
            var out = [Float](repeating: 0, count: outCount)
            for i in 0..<outCount {
                let pos = Double(i) / linRatio
                let lo = min(src.count - 1, max(0, Int(pos.rounded(.down))))
                let hi = min(src.count - 1, lo + 1)
                let frac = Float(pos - Double(lo))
                out[i] = src[lo] + (src[hi] - src[lo]) * frac
            }
            channels.append(out)
        }
        return AnalysisAudio(sampleRate: analysisRate, channels: channels)
    }
}

// MARK: - Pipeline → facade mappers

extension TempoResult {
    /// Map a ported `BeatGrid` (+ its tempo candidate) onto the facade result.
    static func fromPipeline(grid: BeatGrid?, tempoBPM: Double?, tempoConfidence: Double,
                             downbeats: [Int], sampleRate: Double) -> TempoResult {
        guard let grid else {
            return TempoResult(bpm: tempoBPM ?? 120, confidence: tempoConfidence,
                               beatPositions: [], downbeatPositions: [], isConstantTempo: true)
        }
        let beatPositions = grid.beatSamples.map { Double($0) / sampleRate }
        let downbeatPositions = downbeats.compactMap { idx -> TimeInterval? in
            idx >= 0 && idx < beatPositions.count ? beatPositions[idx] : nil
        }
        var meanConf = 0.0
        let peak: Float = grid.confidence.max() ?? 0
        if peak > 0 && !grid.confidence.isEmpty {
            let sum: Float = grid.confidence.reduce(0, +)
            let mean: Float = sum / Float(grid.confidence.count)
            meanConf = Double(min(Float(1), mean / peak))
        }
        return TempoResult(
            bpm: grid.bpm > 0 ? grid.bpm : (tempoBPM ?? 120),
            confidence: max(tempoConfidence, meanConf),
            beatPositions: beatPositions,
            downbeatPositions: downbeatPositions,
            isConstantTempo: grid.isConstantTempo
        )
    }
}

extension KeyResult {
    init(_ estimate: KeyEstimate) {
        // Open-Key notation from the Camelot code: wheel numbers offset by 7
        // (Camelot 8 == Open 1), letter d (major) / m (minor).
        let openNumber = ((estimate.camelot.number + 4) % 12) + 1
        self.init(tonic: estimate.tonic,
                  mode: estimate.isMinor ? .minor : .major,
                  camelot: estimate.camelot.code,
                  openKey: "\(openNumber)\(estimate.isMinor ? "m" : "d")",
                  confidence: estimate.confidence)
    }

    static let fallback = KeyResult(tonic: 0, mode: .major, camelot: "8B",
                                    openKey: "1d", confidence: 0)
}
