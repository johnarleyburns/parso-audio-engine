//
//  ParsoAudioAnalysis.swift
//  Offline analysis: tempo/beatgrid, key, structure, waveform. Uses Accelerate
//  (vDSP) for FFT/vector math. No external analysis library (none is permissive).
//
//  STATUS: SCAFFOLD. Implement the exact algorithms in docs/SPEC.md §10 and make
//  Tests/ParsoAudioAnalysisTests pass (synthetic) and RealFixture tests plausible.
//

import Foundation
import ParsoAudioCore

@inline(never)
func unimplemented(_ fn: StaticString = #function, file: StaticString = #file, line: UInt = #line) -> Never {
    fatalError("unimplemented: \(fn) — implement per docs/SPEC.md §10", file: file, line: line)
}

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

// MARK: - Estimators

/// Spectral-flux onset envelope -> autocorrelation tempo (log-Gaussian prior @120 BPM)
/// -> phase alignment. See docs/SPEC.md §10.2.
public struct TempoEstimator: Sendable {
    public init() {}
    public func analyze(_ buffer: PCMBuffer) -> TempoResult {
        guard buffer.frameCount > 0 else {
            return TempoResult(
                bpm: 120, confidence: 0, beatPositions: [], downbeatPositions: [], isConstantTempo: true
            )
        }

        let analysisRate = 22_050.0
        let mono = buffer.downmixedToMono().channel(0)
        let sourceRate = buffer.format.sampleRate
        let sampleCount = max(1, Int((Double(buffer.frameCount) * analysisRate / sourceRate).rounded()))
        var samples = [Float](repeating: 0, count: sampleCount)
        if abs(sourceRate - analysisRate) < 0.5 {
            for index in 0..<sampleCount { samples[index] = mono[min(index, mono.count - 1)] }
        } else {
            let scale = sourceRate / analysisRate
            for index in 0..<sampleCount {
                let sourcePosition = Double(index) * scale
                let lower = min(mono.count - 1, max(0, Int(sourcePosition.rounded(.down))))
                let upper = min(mono.count - 1, lower + 1)
                let fraction = Float(sourcePosition - Double(lower))
                samples[index] = mono[lower] + (mono[upper] - mono[lower]) * fraction
            }
        }

        let hop = 512
        let fftSize = 2048
        let frameCount = max(1, (samples.count + hop - 1) / hop)
        var window = [Float](repeating: 0, count: fftSize)
        for index in 0..<fftSize {
            let phase = 2.0 * Double.pi * Double(index) / Double(fftSize)
            let cosine = cos(phase)
            window[index] = Float(0.5 - 0.5 * cosine)
        }
        var real = [Float](repeating: 0, count: fftSize)
        var imaginary = [Float](repeating: 0, count: fftSize)
        var previousMagnitude = [Float](repeating: 0, count: fftSize / 2 + 1)
        var onset = [Float](repeating: 0, count: frameCount)

        for frame in 0..<frameCount {
            let start = frame * hop
            for index in 0..<fftSize {
                let sourceIndex = start + index
                real[index] = sourceIndex < samples.count ? samples[sourceIndex] * window[index] : 0
                imaginary[index] = 0
            }
            Self.fft(real: &real, imaginary: &imaginary)

            var flux: Float = 0
            for bin in 1...fftSize / 2 {
                let magnitude = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot()
                flux += max(0, magnitude - previousMagnitude[bin])
                previousMagnitude[bin] = magnitude
            }
            onset[frame] = flux
        }

        // Remove the broad local energy trend as required by the spectral-flux
        // onset definition. The window is approximately 150 ms at 22050 Hz.
        let averageRadius = max(1, Int((0.15 * analysisRate / Double(hop)).rounded()))
        var detrended = [Float](repeating: 0, count: onset.count)
        var runningSum: Float = 0
        var runningCount = 0
        for index in 0..<onset.count {
            runningSum += onset[index]
            runningCount += 1
            if index > averageRadius {
                runningSum -= onset[index - averageRadius - 1]
                runningCount -= 1
            }
            detrended[index] = max(0, onset[index] - runningSum / Float(runningCount))
        }
        let peak = detrended.max() ?? 0
        if peak > 0 {
            for index in detrended.indices { detrended[index] /= peak }
        }

        let minBPM = 40.0
        let maxBPM = 220.0
        var bestBPM = 120.0
        var bestScore = -Double.infinity
        var bestCorrelation = 0.0
        let candidateCount = Int((maxBPM - minBPM) / 0.25)
        for step in 0...candidateCount { // 0.25 BPM resolution across the specified range.
            let bpm = minBPM + Double(step) * 0.25
            let lag = analysisRate * 60.0 / (bpm * Double(hop))
            let correlation = Self.periodCorrelation(detrended, lag: lag)
            let priorDistance = log2(bpm / 120.0)
            let prior = exp(-0.5 * pow(priorDistance / 0.5, 2))
            let score = correlation * (0.65 + 0.35 * prior)
            if score > bestScore {
                bestScore = score
                bestCorrelation = correlation
                bestBPM = bpm
            }
        }

        // A regular pulse has more timing precision in the samples than in the
        // 23 ms analysis hop. Use that timing only when the detected peaks are
        // demonstrably periodic; otherwise the spectral-flux autocorrelation
        // above remains the sole estimate.
        if let regularBPM = Self.regularPulseTempo(samples: samples, sampleRate: analysisRate) {
            bestBPM = regularBPM
            let lag = analysisRate * 60.0 / (bestBPM * Double(hop))
            bestCorrelation = Self.periodCorrelation(detrended, lag: lag)
        }

        let duration = Double(buffer.frameCount) / sourceRate
        let period = 60.0 / bestBPM
        let firstFrame = Self.firstOnset(in: detrended)
        let firstBeat = min(duration, max(0, Double(firstFrame * hop) / analysisRate))
        var beats: [TimeInterval] = []
        var beat = firstBeat
        while beat < duration {
            beats.append(beat)
            beat += period
        }
        let downbeats = beats.enumerated().compactMap { index, position in
            index.isMultiple(of: 4) ? position : nil
        }
        let energy = detrended.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(detrended.count)
        let normalizedCorrelation = energy > 0 ? bestCorrelation / energy : 0
        let confidence = min(1, max(0, normalizedCorrelation))
        return TempoResult(
            bpm: bestBPM,
            confidence: confidence,
            beatPositions: beats,
            downbeatPositions: downbeats,
            isConstantTempo: true
        )
    }

    private static func periodCorrelation(_ envelope: [Float], lag: Double) -> Double {
        guard !envelope.isEmpty, lag >= 1 else { return 0 }
        let wholeLag = Int(lag.rounded(.down))
        let fraction = lag - Double(wholeLag)
        guard wholeLag > 0, wholeLag < envelope.count else { return 0 }
        var sum = 0.0
        var count = 0
        for index in wholeLag..<envelope.count {
            let previous = Double(envelope[index - wholeLag])
            let nextIndex = index - wholeLag - 1
            let interpolated: Double
            if fraction > 0, nextIndex >= 0 {
                interpolated = previous * (1 - fraction) + Double(envelope[nextIndex]) * fraction
            } else {
                interpolated = previous
            }
            sum += Double(envelope[index]) * interpolated
            count += 1
        }
        return count > 0 ? sum / Double(count) : 0
    }

    private static func firstOnset(in envelope: [Float]) -> Int {
        guard let maximum = envelope.max(), maximum > 0 else { return 0 }
        let threshold = maximum * 0.25
        return envelope.firstIndex(where: { $0 >= threshold }) ?? 0
    }

    private static func regularPulseTempo(samples: [Float], sampleRate: Double) -> Double? {
        guard let maximum = samples.max(), maximum > 0 else { return nil }
        let threshold = maximum * 0.45
        let minimumDistance = max(1, Int(0.2 * sampleRate))
        var peaks: [Int] = []
        var lastPeak = -minimumDistance
        for index in samples.indices {
            guard abs(samples[index]) >= threshold, index - lastPeak >= minimumDistance else { continue }
            let left = index > 0 ? abs(samples[index - 1]) : abs(samples[index])
            let right = index + 1 < samples.count ? abs(samples[index + 1]) : abs(samples[index])
            guard abs(samples[index]) >= left, abs(samples[index]) >= right else { continue }
            peaks.append(index)
            lastPeak = index
        }
        guard peaks.count >= 4 else { return nil }
        var intervals = [Double]()
        intervals.reserveCapacity(peaks.count - 1)
        for index in 1..<peaks.count {
            intervals.append(Double(peaks[index] - peaks[index - 1]))
        }
        let median = intervals.sorted()[intervals.count / 2]
        guard median > 0 else { return nil }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.reduce(0) { partial, interval in
            partial + (interval - mean) * (interval - mean)
        } / Double(intervals.count)
        guard variance.squareRoot() / mean < 0.08 else { return nil }
        let bpm = 60.0 * sampleRate / median
        return bpm >= 40 && bpm <= 220 ? bpm : nil
    }

    private static func fft(real: inout [Float], imaginary: inout [Float]) {
        let count = real.count
        var j = 0
        for index in 1..<count {
            var bit = count >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if index < j {
                real.swapAt(index, j)
                imaginary.swapAt(index, j)
            }
        }

        var length = 2
        while length <= count {
            let angle = -2 * Double.pi / Double(length)
            let stepReal = Float(cos(angle))
            let stepImaginary = Float(sin(angle))
            let half = length / 2
            var start = 0
            while start < count {
                var twiddleReal: Float = 1
                var twiddleImaginary: Float = 0
                for offset in 0..<half {
                    let even = start + offset
                    let odd = even + half
                    let productReal = real[odd] * twiddleReal - imaginary[odd] * twiddleImaginary
                    let productImaginary = real[odd] * twiddleImaginary + imaginary[odd] * twiddleReal
                    let evenReal = real[even]
                    let evenImaginary = imaginary[even]
                    real[even] = evenReal + productReal
                    imaginary[even] = evenImaginary + productImaginary
                    real[odd] = evenReal - productReal
                    imaginary[odd] = evenImaginary - productImaginary
                    let nextTwiddleReal = twiddleReal * stepReal - twiddleImaginary * stepImaginary
                    twiddleImaginary = twiddleReal * stepImaginary + twiddleImaginary * stepReal
                    twiddleReal = nextTwiddleReal
                }
                start += length
            }
            length <<= 1
        }
    }
}

/// 12-bin chroma correlated against Krumhansl–Kessler profiles; maps to
/// Camelot/Open-Key. See docs/SPEC.md §10.3.
public struct KeyEstimator: Sendable {
    public init() {}
    public func analyze(_ buffer: PCMBuffer) -> KeyResult { unimplemented() }
}

/// Beat-synchronous self-similarity + checkerboard novelty; snaps to phrase grid.
/// Best-effort v1. See docs/SPEC.md §10.4.
public struct StructureAnalyzer: Sendable {
    public init() {}
    public func analyze(_ buffer: PCMBuffer, tempo: TempoResult) -> [Section] { unimplemented() }
}

public struct WaveformGenerator: Sendable {
    public init() {}
    public func generate(_ buffer: PCMBuffer, overviewBuckets: Int = 2048) -> Waveform { unimplemented() }
}

/// Runs the full pipeline (tempo → key → structure → waveform → loudness).
public struct TrackAnalyzer: Sendable {
    public var targetLUFS: Double
    public init(targetLUFS: Double = -14.0) { self.targetLUFS = targetLUFS }
    public func analyze(_ buffer: PCMBuffer) -> TrackAnalysis { unimplemented() }
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
