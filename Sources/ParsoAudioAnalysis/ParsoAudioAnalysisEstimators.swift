import Foundation
import Accelerate
import ParsoAudioCore

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

