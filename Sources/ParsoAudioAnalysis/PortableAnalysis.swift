//
//  PortableAnalysis.swift
//  Stable, scalar Codable representation of FullAnalysisResult.
//

import Foundation
import ParsoAudioCore

/// Version identifiers for the on-disk analysis contract. The algorithm ID is
/// intentionally separate from the Swift type name so a future implementation
/// can reject stale caches without decoding implementation details.
public enum AnalysisSchema {
    public static let currentVersion: Int = 1
    public static let algorithmID: String = "pae-full-analysis-1.2"
}

public enum PortableAnalysisError: Error, Sendable, Equatable {
    case unsupportedSchema(Int)
    case invalidPayload(String)
}

public struct PortableKey: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case major, minor }
    public var tonic: Int
    public var mode: Mode
    public var camelot: String
    public var confidence: Double

    public init(tonic: Int, mode: Mode, camelot: String, confidence: Double) {
        self.tonic = tonic
        self.mode = mode
        self.camelot = camelot
        self.confidence = confidence
    }
}

/// Alias used by phrase-local descriptors when a descriptor is read without
/// loading the full key-estimator implementation.
public typealias KeyEstimatePortable = PortableKey

public enum PhraseTypePortable: String, Codable, Sendable, CaseIterable {
    case intro, build, drop, chorus, breakdown, outro
}

public struct PortableLoudness: Codable, Sendable, Equatable {
    public var integratedLUFS: Double
    public var truePeakDBTP: Double
    public var gainToTargetDB: Double
    public var loudnessRangeLU: Double

    public init(integratedLUFS: Double, truePeakDBTP: Double,
                gainToTargetDB: Double, loudnessRangeLU: Double = 0) {
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
        self.gainToTargetDB = gainToTargetDB
        self.loudnessRangeLU = loudnessRangeLU
    }
}

public struct PortableEnergy: Codable, Sendable, Equatable {
    public var scalar: Double
    public var curve: [Double]
    public var hopSeconds: Double

    public init(scalar: Double, curve: [Double], hopSeconds: Double) {
        self.scalar = scalar
        self.curve = curve
        self.hopSeconds = hopSeconds
    }
}

public struct PortableWaveformBin: Codable, Sendable, Equatable {
    public var min: Double
    public var max: Double
    public var rms: Double
    public var bandRMS: [Double]

    public init(min: Double, max: Double, rms: Double, bandRMS: [Double] = []) {
        self.min = min
        self.max = max
        self.rms = rms
        self.bandRMS = bandRMS
    }
}

public struct PortableWaveform: Codable, Sendable, Equatable {
    public var levels: [[PortableWaveformBin]]
    public var sampleRate: Double
    public var baseSamplesPerBin: Int

    public init(levels: [[PortableWaveformBin]], sampleRate: Double,
                baseSamplesPerBin: Int) {
        self.levels = levels
        self.sampleRate = sampleRate
        self.baseSamplesPerBin = baseSamplesPerBin
    }
}

public struct PortablePhrase: Codable, Sendable, Equatable {
    public var startSample: Int64
    public var endSample: Int64
    public var startBeat: Int
    public var lengthBeats: Int
    public var type: PhraseTypePortable
    public var energy: Float
    public var confidence: Double
    public var descriptors: PhraseLocalDescriptors?

    public init(startSample: Int64, endSample: Int64, startBeat: Int,
                lengthBeats: Int, type: PhraseTypePortable, energy: Float,
                confidence: Double, descriptors: PhraseLocalDescriptors? = nil) {
        self.startSample = startSample
        self.endSample = endSample
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.type = type
        self.energy = energy
        self.confidence = confidence
        self.descriptors = descriptors
    }
}

/// Portable analysis schema v1. Additional beat-grid fields are retained so a
/// round trip does not throw away confidence or constant-tempo information;
/// consumers may ignore them and use the required `beatSamples` field.
public struct PortableAnalysisV1: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var algorithmID: String
    public var sourceSampleRate: Double
    public var sourceFrameCount: Int64
    public var analyzedSampleRate: Double
    public var durationSeconds: Double
    public var loudness: PortableLoudness
    public var bpm: Double?
    public var tempoConfidence: Double?
    public var key: PortableKey?
    public var beatSamples: [Int64]
    public var downbeatIndices: [Int]
    public var phrases: [PortablePhrase]
    public var energy: PortableEnergy?
    public var waveform: PortableWaveform?
    public var beatConfidence: [Float]
    public var isConstantTempo: Bool
    public var hopSeconds: Double

    public init(schemaVersion: Int = AnalysisSchema.currentVersion,
                algorithmID: String = AnalysisSchema.algorithmID,
                sourceSampleRate: Double, sourceFrameCount: Int64,
                analyzedSampleRate: Double, durationSeconds: Double,
                loudness: PortableLoudness, bpm: Double? = nil,
                tempoConfidence: Double? = nil, key: PortableKey? = nil,
                beatSamples: [Int64] = [], downbeatIndices: [Int] = [],
                phrases: [PortablePhrase] = [], energy: PortableEnergy? = nil,
                waveform: PortableWaveform? = nil, beatConfidence: [Float] = [],
                isConstantTempo: Bool = true, hopSeconds: Double = 0) {
        self.schemaVersion = schemaVersion
        self.algorithmID = algorithmID
        self.sourceSampleRate = sourceSampleRate
        self.sourceFrameCount = sourceFrameCount
        self.analyzedSampleRate = analyzedSampleRate
        self.durationSeconds = durationSeconds
        self.loudness = loudness
        self.bpm = bpm
        self.tempoConfidence = tempoConfidence
        self.key = key
        self.beatSamples = beatSamples
        self.downbeatIndices = downbeatIndices
        self.phrases = phrases
        self.energy = energy
        self.waveform = waveform
        self.beatConfidence = beatConfidence
        self.isConstantTempo = isConstantTempo
        self.hopSeconds = hopSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, algorithmID, sourceSampleRate, sourceFrameCount
        case analyzedSampleRate, durationSeconds, loudness, bpm, tempoConfidence
        case key, beatSamples, downbeatIndices, phrases, energy, waveform
        case beatConfidence, isConstantTempo, hopSeconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == AnalysisSchema.currentVersion else {
            throw PortableAnalysisError.unsupportedSchema(version)
        }
        self.schemaVersion = version
        let decodedAlgorithmID = try c.decode(String.self, forKey: .algorithmID)
        self.algorithmID = decodedAlgorithmID
        guard decodedAlgorithmID == AnalysisSchema.algorithmID else {
            throw PortableAnalysisError.invalidPayload("unsupported algorithm ID")
        }
        sourceSampleRate = try c.decode(Double.self, forKey: .sourceSampleRate)
        sourceFrameCount = try c.decode(Int64.self, forKey: .sourceFrameCount)
        analyzedSampleRate = try c.decode(Double.self, forKey: .analyzedSampleRate)
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        loudness = try c.decode(PortableLoudness.self, forKey: .loudness)
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm)
        tempoConfidence = try c.decodeIfPresent(Double.self, forKey: .tempoConfidence)
        key = try c.decodeIfPresent(PortableKey.self, forKey: .key)
        beatSamples = try c.decode([Int64].self, forKey: .beatSamples)
        downbeatIndices = try c.decode([Int].self, forKey: .downbeatIndices)
        phrases = try c.decode([PortablePhrase].self, forKey: .phrases)
        energy = try c.decodeIfPresent(PortableEnergy.self, forKey: .energy)
        waveform = try c.decodeIfPresent(PortableWaveform.self, forKey: .waveform)
        beatConfidence = try c.decodeIfPresent([Float].self, forKey: .beatConfidence) ?? []
        isConstantTempo = try c.decodeIfPresent(Bool.self, forKey: .isConstantTempo) ?? true
        hopSeconds = try c.decodeIfPresent(Double.self, forKey: .hopSeconds) ?? 0
        try validate()
    }

    private func validate() throws {
        func finite(_ value: Double, _ label: String) throws {
            guard value.isFinite else { throw PortableAnalysisError.invalidPayload("non-finite \(label)") }
        }
        guard sourceSampleRate > 0, analyzedSampleRate > 0,
              sourceFrameCount >= 0, durationSeconds >= 0,
              beatSamples == beatSamples.sorted(),
              beatSamples.allSatisfy({ $0 >= 0 }),
              downbeatIndices.allSatisfy({ $0 >= 0 && $0 < beatSamples.count }),
              beatConfidence.isEmpty || beatConfidence.count == beatSamples.count else {
            throw PortableAnalysisError.invalidPayload("invalid sample or grid ranges")
        }
        try finite(sourceSampleRate, "source sample rate")
        try finite(analyzedSampleRate, "analysis sample rate")
        try finite(durationSeconds, "duration")
        if let bpm { guard bpm.isFinite, bpm > 0 else { throw PortableAnalysisError.invalidPayload("invalid BPM") } }
        if let key {
            guard (0..<12).contains(key.tonic), CamelotKey(code: key.camelot) != nil,
                  !key.confidence.isNaN, key.confidence >= 0, key.confidence <= 1 else {
                throw PortableAnalysisError.invalidPayload("invalid key")
            }
        }
        let loudnessValues = [loudness.integratedLUFS, loudness.truePeakDBTP,
                              loudness.gainToTargetDB, loudness.loudnessRangeLU]
        guard loudnessValues.allSatisfy(\.isFinite) else {
            throw PortableAnalysisError.invalidPayload("invalid loudness")
        }
        if let tempoConfidence {
            guard tempoConfidence.isFinite, (0...1).contains(tempoConfidence) else {
                throw PortableAnalysisError.invalidPayload("invalid tempo confidence")
            }
        }
        guard hopSeconds.isFinite, hopSeconds >= 0,
              beatConfidence.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw PortableAnalysisError.invalidPayload("invalid feature timing")
        }
        if let energy {
            guard energy.scalar.isFinite, energy.hopSeconds.isFinite,
                  energy.hopSeconds >= 0,
                  energy.curve.allSatisfy(\.isFinite) else {
                throw PortableAnalysisError.invalidPayload("invalid energy")
            }
        }
        if let waveform {
            guard waveform.sampleRate.isFinite, waveform.sampleRate > 0,
                  waveform.baseSamplesPerBin > 0 else {
                throw PortableAnalysisError.invalidPayload("invalid waveform")
            }
            for bin in waveform.levels.flatMap({ $0 }) {
                let values = [bin.min, bin.max, bin.rms] + bin.bandRMS
                guard values.allSatisfy(\.isFinite) else {
                    throw PortableAnalysisError.invalidPayload("invalid waveform bin")
                }
            }
        }
        for phrase in phrases {
            guard phrase.startSample >= 0, phrase.endSample >= phrase.startSample,
                  phrase.startBeat >= 0, phrase.lengthBeats > 0,
                  phrase.confidence.isFinite, phrase.energy.isFinite else {
                throw PortableAnalysisError.invalidPayload("invalid phrase")
            }
            if let descriptors = phrase.descriptors {
                let values = [descriptors.energy, descriptors.bassEnergy,
                              descriptors.brightness, descriptors.transientDensity,
                              descriptors.harmonicStability, descriptors.spectralDensity]
                guard descriptors.energy >= 0, descriptors.energy <= 10,
                      values.dropFirst().allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw PortableAnalysisError.invalidPayload("invalid phrase descriptors")
                }
                if let localKey = descriptors.localKey {
                    guard (0..<12).contains(localKey.tonic),
                          CamelotKey(code: localKey.camelot) != nil,
                          localKey.confidence.isFinite,
                          (0...1).contains(localKey.confidence) else {
                        throw PortableAnalysisError.invalidPayload("invalid local key")
                    }
                }
            }
        }
    }

    public func fullAnalysisResult() throws -> FullAnalysisResult {
        try validate()
        let loudnessResult = LoudnessResult(
            integratedLUFS: loudness.integratedLUFS,
            truePeakDBTP: loudness.truePeakDBTP,
            gainToTargetDB: loudness.gainToTargetDB,
            loudnessRangeLU: loudness.loudnessRangeLU)
        let keyEstimate = key.flatMap { value -> KeyEstimate? in
            guard let camelot = CamelotKey(code: value.camelot) else { return nil }
            return KeyEstimate(tonic: value.tonic, isMinor: value.mode == .minor,
                               camelot: camelot, confidence: value.confidence,
                               musicalKey: "\(value.tonic) \(value.mode.rawValue)")
        }
        let grid: BeatGrid?
        if beatSamples.count >= 2, let bpm, bpm > 0 {
            grid = BeatGrid(firstBeatSample: beatSamples[0], bpm: bpm,
                            beatSamples: beatSamples,
                            confidence: beatConfidence.isEmpty
                                ? [Float](repeating: 0.5, count: beatSamples.count)
                                : beatConfidence,
                            isConstantTempo: isConstantTempo)
        } else {
            grid = nil
        }
        let phrases = phrases.map { item in
            Phrase(startSample: item.startSample, endSample: item.endSample,
                   startBeat: item.startBeat, lengthBeats: item.lengthBeats,
                   type: PhraseType(rawValue: item.type.rawValue) ?? .build,
                   energy: item.energy, confidence: item.confidence,
                   descriptors: item.descriptors)
        }
        let energyResult = energy.map { EnergyResult(scalar: Float($0.scalar),
                                                      curve: $0.curve.map(Float.init),
                                                      hopSeconds: $0.hopSeconds) }
        let waveformResult = waveform.map { value in
            WaveformPyramid(levels: value.levels.map { level in
                level.map { bin in
                    WaveformBin(min: Float(bin.min), max: Float(bin.max),
                                rms: Float(bin.rms), bandRMS: bin.bandRMS.map(Float.init))
                }
            }, sampleRate: value.sampleRate, baseSamplesPerBin: value.baseSamplesPerBin)
        }
        return FullAnalysisResult(loudness: loudnessResult, bpm: bpm,
                                  key: keyEstimate, beatGrid: grid,
                                  downbeats: downbeatIndices, phrases: phrases,
                                  energy: energyResult, waveform: waveformResult,
                                  hopSeconds: hopSeconds)
    }
}

extension FullAnalysisResult {
    public func portable(sourceSampleRate: Double, sourceFrameCount: Int64) -> PortableAnalysisV1 {
        let portablePhrases = phrases.map { phrase in
            PortablePhrase(startSample: phrase.startSample, endSample: phrase.endSample,
                            startBeat: phrase.startBeat, lengthBeats: phrase.lengthBeats,
                            type: PhraseTypePortable(rawValue: phrase.type.rawValue) ?? .build,
                            energy: phrase.energy, confidence: phrase.confidence,
                            descriptors: phrase.descriptors)
        }
        let portableEnergy = energy.map { PortableEnergy(scalar: Double($0.scalar),
                                                          curve: $0.curve.map(Double.init),
                                                          hopSeconds: $0.hopSeconds) }
        let portableWaveform = waveform.map { value in
            PortableWaveform(levels: value.levels.map { level in
                level.map { bin in
                    PortableWaveformBin(min: Double(bin.min), max: Double(bin.max),
                                        rms: Double(bin.rms), bandRMS: bin.bandRMS.map(Double.init))
                }
            }, sampleRate: value.sampleRate, baseSamplesPerBin: value.baseSamplesPerBin)
        }
        let portableKey = key.map { PortableKey(tonic: $0.tonic,
                                                  mode: $0.isMinor ? .minor : .major,
                                                  camelot: $0.camelot.code,
                                                  confidence: $0.confidence) }
        let tempoConfidence: Double? = beatGrid.flatMap { grid in
            guard !grid.confidence.isEmpty else { return nil }
            return Double(grid.confidence.reduce(0, +)) / Double(grid.confidence.count)
        }
        return PortableAnalysisV1(
            sourceSampleRate: sourceSampleRate, sourceFrameCount: sourceFrameCount,
            analyzedSampleRate: beatGrid.map { _ in 48_000 } ?? waveform?.sampleRate ?? 48_000,
            durationSeconds: sourceSampleRate > 0 ? Double(sourceFrameCount) / sourceSampleRate : 0,
            loudness: PortableLoudness(integratedLUFS: loudness.integratedLUFS,
                                       truePeakDBTP: loudness.truePeakDBTP,
                                       gainToTargetDB: loudness.gainToTargetDB,
                                       loudnessRangeLU: loudness.loudnessRangeLU),
            bpm: bpm ?? beatGrid?.bpm,
            tempoConfidence: tempoConfidence,
            key: portableKey, beatSamples: beatGrid?.beatSamples ?? [],
            downbeatIndices: downbeats, phrases: portablePhrases,
            energy: portableEnergy, waveform: portableWaveform,
            beatConfidence: beatGrid?.confidence ?? [],
            isConstantTempo: beatGrid?.isConstantTempo ?? true,
            hopSeconds: hopSeconds)
    }

    /// Compatibility projection used by `Deck.load`. It intentionally keeps
    /// the original TrackAnalysis facade available while the portable schema
    /// remains the cache/wire representation.
    public func trackAnalysis(format: AudioFormat) -> TrackAnalysis {
        let grid = beatGrid
        let tempo = TempoResult(
            bpm: bpm ?? grid?.bpm ?? 120,
            confidence: grid?.confidence.isEmpty == false
                ? Double(grid!.confidence.reduce(0, +)) / Double(grid!.confidence.count)
                : 0,
            beatPositions: (grid?.beatSamples ?? []).map { Double($0) / 48_000 },
            downbeatPositions: downbeats.compactMap { index in
                guard let samples = grid?.beatSamples, samples.indices.contains(index) else { return nil }
                return Double(samples[index]) / 48_000
            },
            isConstantTempo: grid?.isConstantTempo ?? true)
        let keyResult = key.map { value in
            KeyResult(tonic: value.tonic,
                      mode: value.isMinor ? .minor : .major,
                      camelot: value.camelot.code,
                      openKey: value.camelot.code,
                      confidence: value.confidence)
        } ?? .fallback
        let sections = phrases.map { phrase in
            let kind: Section.Kind = switch phrase.type {
            case .intro: .intro
            case .build: .buildup
            case .drop: .drop
            case .chorus: .chorus
            case .breakdown: .breakdown
            case .outro: .outro
            }
            return Section(start: Double(phrase.startSample) / 48_000,
                           kind: kind, bar: phrase.startBeat / 4)
        }
        let bins = waveform?.levels.first ?? []
        let waveformResult = Waveform(
            overviewMinMax: bins.map { SIMD2<Float>($0.min, $0.max) },
            detailRMS: bins.map(\.rms),
            bandEnergy: bins.map { bin in
                let bands = bin.bandRMS + [0, 0, 0]
                return SIMD3<Float>(bands[0], bands[1], bands[2])
            })
        return TrackAnalysis(format: format,
                              duration: 0,
                              tempo: tempo, key: keyResult, sections: sections,
                              waveform: waveformResult, loudness: loudness)
    }
}
