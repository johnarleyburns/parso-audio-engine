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

// MARK: - Estimators

/// Accelerate-backed onset/comb tempo + Ellis DP beat grid (docs/SPEC.md §10.2,
/// ported from `parso-tonearm`).
public struct TempoEstimator: Sendable {
    public init() {}
    public func analyze(_ buffer: PCMBuffer) -> TempoResult {
        let empty = TempoResult(bpm: 120, confidence: 0, beatPositions: [],
                                downbeatPositions: [], isConstantTempo: true)
        guard buffer.frameCount > 0 else { return empty }

        let audio = AnalysisBridge.analysisAudio(from: buffer)
        let stft = STFTConfig()
        let spectra = STFTKernel(config: stft).spectra(audio.mono)
        guard !spectra.isEmpty else { return empty }
        let hopSeconds = Double(stft.hopSize) / stft.sampleRate
        let envelope = OnsetDetector.envelope(spectra: spectra)
        let onsets = OnsetDetector.peaks(envelope, frameRateHz: 1 / hopSeconds)
        guard let tempo = TempoAnalyzer.estimate(novelty: envelope,
                                                 hopSeconds: hopSeconds).first else {
            return empty
        }

        let grid = BeatTracker.grid(novelty: envelope, hopSeconds: hopSeconds,
                                    sampleRate: stft.sampleRate,
                                    onsets: onsets, bpm: tempo.bpm)
        let downbeatIndices = grid.map {
            BeatTracker.downbeats(beatSamples: $0.beatSamples, novelty: envelope,
                                  hopSeconds: hopSeconds, sampleRate: stft.sampleRate)
        } ?? []
        return .fromPipeline(grid: grid, tempoBPM: tempo.bpm, tempoConfidence: tempo.confidence,
                             downbeats: downbeatIndices, sampleRate: stft.sampleRate)
    }
}

/// HPCP chroma correlated against Krumhansl–Schmuckler profiles → Camelot /
/// Open-Key (docs/SPEC.md §10.3, ported from `parso-tonearm`).
public struct KeyEstimator: Sendable {
    public init() {}
    public func analyze(_ buffer: PCMBuffer) -> KeyResult {
        guard buffer.frameCount > 0 else { return .fallback }
        let audio = AnalysisBridge.analysisAudio(from: buffer)
        let spectra = STFTKernel(config: STFTConfig()).spectra(audio.mono)
        guard !spectra.isEmpty else { return .fallback }
        let chromaFrames = spectra.map { KeyDetector.chroma($0) }
        guard let estimate = KeyDetector.estimate(chromaFrames) else { return .fallback }
        return KeyResult(estimate)
    }
}

/// Beat/energy-contour structural boundaries (docs/SPEC.md §10.4). Deterministic
/// v1 — energy + zero-crossing novelty, no FFT.
public struct StructureAnalyzer: Sendable {
    public init() {}
    public func analyze(_ buffer: PCMBuffer, tempo: TempoResult) -> [Section] {
        guard buffer.frameCount > 0 else { return [] }
        let sampleRate = buffer.format.sampleRate
        let mono = buffer.downmixedToMono().channel(0)
        let beatPeriod = tempo.bpm > 0 ? 60.0 / tempo.bpm : 0.5
        let duration = Double(buffer.frameCount) / sampleRate
        let beatCount = max(1, Int(ceil(duration / beatPeriod)))
        var features = [[Double]]()
        features.reserveCapacity(beatCount)

        for beat in 0..<beatCount {
            let start = min(buffer.frameCount, Int(Double(beat) * beatPeriod * sampleRate))
            let end = min(buffer.frameCount, max(start + 1, Int(Double(beat + 1) * beatPeriod * sampleRate)))
            guard start < end else { continue }
            var energy = 0.0
            var low = 0.0
            var mid = 0.0
            var high = 0.0
            var crossings = 0
            var previous = mono[start]
            for index in start..<end {
                let value = Double(mono[index])
                energy += value * value
                // Short-time band proxies are intentionally lightweight here;
                // the feature is used for boundary novelty, not tonal analysis.
                if abs(value) > 0.35 { high += value * value }
                else if abs(value) > 0.1 { mid += value * value }
                else { low += value * value }
                if index > start && (mono[index] >= 0) != (previous >= 0) { crossings += 1 }
                previous = mono[index]
            }
            let count = Double(end - start)
            features.append([
                (energy / count).squareRoot(),
                low / count,
                mid / count,
                high / count,
                Double(crossings) / count
            ])
        }

        guard !features.isEmpty else { return [] }
        let maximumEnergy = features.map { $0[0] }.max() ?? 0
        var boundaries = [0]
        var lastBoundary = 0
        for index in 1..<features.count {
            let previous = features[index - 1]
            let current = features[index]
            let novelty = Self.cosineDistance(previous, current)
            let energyChange = abs(current[0] - previous[0])
            let isPeak = index + 1 == features.count ||
                novelty >= Self.cosineDistance(current, features[index + 1])
            if isPeak && energyChange > max(0.02 * maximumEnergy, 0.08) && index - lastBoundary >= 4 {
                boundaries.append(index)
                lastBoundary = index
            }
        }
        if boundaries.count == 1 && features.count > 8 {
            // A gradual transition can have no single dominant novelty peak.
            let quarter = max(1, features.count / 4)
            boundaries.append(quarter)
            boundaries.append(min(features.count - 1, quarter * 2))
        }
        boundaries = Array(Set(boundaries)).sorted()

        return boundaries.enumerated().map { position, beatIndex in
            let start = Double(beatIndex) * beatPeriod
            let energy = features[min(beatIndex, features.count - 1)][0]
            let kind: Section.Kind
            if position == 0 {
                kind = .intro
            } else if energy > maximumEnergy * 0.75 {
                kind = .drop
            } else if energy < maximumEnergy * 0.25 {
                kind = .breakdown
            } else {
                kind = .unknown
            }
            return Section(start: min(duration, start), kind: kind, bar: beatIndex / 4 + 1)
        }
    }

    private static func cosineDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count else { return 1 }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        let denominator = (lhsNorm * rhsNorm).squareRoot()
        return denominator > 0 ? 1 - dot / denominator : 1
    }
}

/// Multi-resolution min/max/RMS + band-energy bucketing (docs/SPEC.md §10.5).
/// Deterministic v1 — pure reductions, no FFT.
public struct WaveformGenerator: Sendable {
    public init() {}
    public func generate(_ buffer: PCMBuffer, overviewBuckets: Int = 2048) -> Waveform {
        let bucketCount = max(0, overviewBuckets)
        guard bucketCount > 0 else { return Waveform(overviewMinMax: [], detailRMS: [], bandEnergy: []) }
        let mono = buffer.downmixedToMono().channel(0)
        var overview = [SIMD2<Float>](repeating: SIMD2(0, 0), count: bucketCount)
        var rms = [Float](repeating: 0, count: bucketCount)
        var bands = [SIMD3<Float>](repeating: SIMD3(0, 0, 0), count: bucketCount)
        guard buffer.frameCount > 0 else {
            return Waveform(overviewMinMax: overview, detailRMS: rms, bandEnergy: bands)
        }

        var lowState = 0.0
        var midState = 0.0
        for bucket in 0..<bucketCount {
            let start = min(buffer.frameCount, bucket * buffer.frameCount / bucketCount)
            let end = min(buffer.frameCount, max(start + 1, (bucket + 1) * buffer.frameCount / bucketCount))
            var minimum = Float.infinity
            var maximum = -Float.infinity
            var squareSum = 0.0
            var lowEnergy = 0.0
            var midEnergy = 0.0
            var highEnergy = 0.0
            for frame in start..<end {
                let value = Double(mono[frame])
                let sample = Float(value)
                minimum = min(minimum, sample)
                maximum = max(maximum, sample)
                squareSum += value * value

                lowState += 0.02 * (value - lowState)
                midState += 0.2 * (value - midState)
                let mid = midState - lowState
                let high = value - midState
                lowEnergy += lowState * lowState
                midEnergy += mid * mid
                highEnergy += high * high
            }
            let count = Double(end - start)
            overview[bucket] = SIMD2(minimum, maximum)
            rms[bucket] = Float((squareSum / count).squareRoot())
            bands[bucket] = SIMD3(
                Float(lowEnergy / count), Float(midEnergy / count), Float(highEnergy / count)
            )
        }
        return Waveform(overviewMinMax: overview, detailRMS: rms, bandEnergy: bands)
    }
}

/// Runs the full pipeline (tempo → key → structure → waveform → loudness).
public struct TrackAnalyzer: Sendable {
    public var targetLUFS: Double
    public init(targetLUFS: Double = -14.0) { self.targetLUFS = targetLUFS }
    public func analyze(_ buffer: PCMBuffer) -> TrackAnalysis {
        // One shared STFT/resample pass for tempo + key (the estimators would
        // each rebuild the spectra otherwise); structure + waveform stay on the
        // raw buffer (energy-domain, no FFT).
        let audio = AnalysisBridge.analysisAudio(from: buffer)
        let full = FullAnalysis.run(audio)
        let tempo = TempoResult.fromPipeline(grid: full.beatGrid, tempoBPM: full.bpm,
                                             tempoConfidence: full.bpm == nil ? 0 : 1,
                                             downbeats: full.downbeats,
                                             sampleRate: AnalysisBridge.analysisRate)
        let key = full.key.map(KeyResult.init) ?? .fallback
        let sections = StructureAnalyzer().analyze(buffer, tempo: tempo)
        let waveform = WaveformGenerator().generate(buffer)
        var loudness = full.loudness
        loudness.gainToTargetDB = targetLUFS - loudness.integratedLUFS

        return TrackAnalysis(
            format: buffer.format,
            duration: buffer.format.sampleRate > 0
                ? Double(buffer.frameCount) / buffer.format.sampleRate
                : 0,
            tempo: tempo,
            key: key,
            sections: sections,
            waveform: waveform,
            loudness: loudness
        )
    }
}

// MARK: - Reference constants (normative — used by the implementation & tests)

public enum KeyProfiles {
    /// Krumhansl–Kessler major profile (docs/SPEC.md §10.3).
    public static let major: [Double] =
        [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    /// Krumhansl–Kessler minor profile.
    public static let minor: [Double] =
        [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    /// Pitch-class names, index 0 == C.
    public static let pitchClassNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
}
