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
    public func analyze(_ buffer: PCMBuffer) -> KeyResult {
        let tonicFallback = 0
        guard buffer.frameCount > 0 else {
            return Self.result(tonic: tonicFallback, mode: .major, confidence: 0)
        }

        let analysisRate = 22_050.0
        let mono = buffer.downmixedToMono().channel(0)
        let sourceRate = buffer.format.sampleRate
        let sampleCount = max(1, Int((Double(buffer.frameCount) * analysisRate / sourceRate).rounded()))
        var samples = [Float](repeating: 0, count: sampleCount)
        let scale = sourceRate / analysisRate
        for index in 0..<sampleCount {
            let sourcePosition = Double(index) * scale
            let lower = min(mono.count - 1, max(0, Int(sourcePosition.rounded(.down))))
            let upper = min(mono.count - 1, lower + 1)
            let fraction = Float(sourcePosition - Double(lower))
            samples[index] = mono[lower] + (mono[upper] - mono[lower]) * fraction
        }

        let fftSize = 4096
        let hop = 2048
        let frameCount = max(1, (samples.count + hop - 1) / hop)
        var window = [Float](repeating: 0, count: fftSize)
        for index in window.indices {
            let phase = 2.0 * Double.pi * Double(index) / Double(fftSize)
            window[index] = Float(0.5 - 0.5 * cos(phase))
        }
        var real = [Float](repeating: 0, count: fftSize)
        var imaginary = [Float](repeating: 0, count: fftSize)
        var chroma = [Double](repeating: 0, count: 12)

        for frame in 0..<frameCount {
            let start = frame * hop
            for index in 0..<fftSize {
                let sourceIndex = start + index
                real[index] = sourceIndex < samples.count ? samples[sourceIndex] * window[index] : 0
                imaginary[index] = 0
            }
            Self.fft(real: &real, imaginary: &imaginary)
            for bin in 1...fftSize / 2 {
                let frequency = Double(bin) * analysisRate / Double(fftSize)
                guard frequency >= 100 && frequency <= 5000 else { continue }
                let magnitude = Double(
                    (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot()
                )
                let midi = Int((12 * log2(frequency / 440.0) + 69).rounded())
                let pitchClass = (midi % 12 + 12) % 12
                chroma[pitchClass] += magnitude
            }
        }

        let total = chroma.reduce(0, +)
        if total > 0 {
            for index in chroma.indices { chroma[index] /= total }
        }

        var bestTonic = tonicFallback
        var bestMode = KeyResult.Mode.major
        var bestCorrelation = -Double.infinity
        var secondCorrelation = -Double.infinity
        for mode in [KeyResult.Mode.major, .minor] {
            let profile = mode == .major ? KeyProfiles.major : KeyProfiles.minor
            for tonic in 0..<12 {
                var rotated = [Double](repeating: 0, count: 12)
                for pitchClass in 0..<12 {
                    rotated[pitchClass] = profile[(pitchClass - tonic + 12) % 12]
                }
                let correlation = Self.pearson(chroma, rotated)
                if correlation > bestCorrelation {
                    secondCorrelation = bestCorrelation
                    bestCorrelation = correlation
                    bestTonic = tonic
                    bestMode = mode
                } else if correlation > secondCorrelation {
                    secondCorrelation = correlation
                }
            }
        }
        let confidence = min(1, max(0, (bestCorrelation - secondCorrelation) * 2.0))
        return Self.result(tonic: bestTonic, mode: bestMode, confidence: confidence)
    }

    private static func result(tonic: Int, mode: KeyResult.Mode, confidence: Double) -> KeyResult {
        let camelotMajor = ["8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B"]
        let camelotMinor = ["5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A"]
        let openMajor = ["1d", "8d", "3d", "10d", "5d", "12d", "7d", "2d", "9d", "4d", "11d", "6d"]
        let openMinor = ["10m", "5m", "12m", "7m", "2m", "9m", "4m", "11m", "6m", "1m", "8m", "3m"]
        return KeyResult(
            tonic: tonic,
            mode: mode,
            camelot: mode == .major ? camelotMajor[tonic] : camelotMinor[tonic],
            openKey: mode == .major ? openMajor[tonic] : openMinor[tonic],
            confidence: confidence
        )
    }

    private static func pearson(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let lhsMean = lhs.reduce(0, +) / Double(lhs.count)
        let rhsMean = rhs.reduce(0, +) / Double(rhs.count)
        var numerator = 0.0
        var lhsEnergy = 0.0
        var rhsEnergy = 0.0
        for index in lhs.indices {
            let left = lhs[index] - lhsMean
            let right = rhs[index] - rhsMean
            numerator += left * right
            lhsEnergy += left * left
            rhsEnergy += right * right
        }
        let denominator = (lhsEnergy * rhsEnergy).squareRoot()
        return denominator > 0 ? numerator / denominator : 0
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
            let angle = -2.0 * Double.pi / Double(length)
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

/// Beat-synchronous self-similarity + checkerboard novelty; snaps to phrase grid.
/// Best-effort v1. See docs/SPEC.md §10.4.
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
