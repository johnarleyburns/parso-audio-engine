import Testing
import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis

@Suite("Portable analysis contract")
struct PortableAnalysisTests {
    private func result() -> FullAnalysisResult {
        let key = KeyEstimate(tonic: 0, isMinor: false,
                              camelot: Camelot.from(tonic: 0, isMinor: false)!,
                              confidence: 0.9, musicalKey: "C major")
        let beats = stride(from: 0, through: 336_000, by: 24_000).map(Int64.init)
        let phrase = Phrase(startSample: 0, endSample: 336_000, startBeat: 0,
                            lengthBeats: 16, type: .chorus, energy: 6,
                            confidence: 0.8,
                            descriptors: PhraseLocalDescriptors(
                                energy: 6, bassEnergy: 0.4, brightness: 0.6,
                                transientDensity: 0.5, harmonicStability: 0.9,
                                localKey: PortableKey(tonic: 0, mode: .major,
                                                      camelot: "8B", confidence: 0.9),
                                spectralDensity: 0.5))
        return FullAnalysisResult(
            loudness: LoudnessResult(integratedLUFS: -14, truePeakDBTP: -1,
                                     gainToTargetDB: 0, loudnessRangeLU: 4),
            bpm: 120, key: key,
            beatGrid: BeatGrid(firstBeatSample: 0, bpm: 120,
                               beatSamples: beats,
                               confidence: [Float](repeating: 0.9, count: beats.count),
                               isConstantTempo: true),
            downbeats: [0, 4, 8, 12], phrases: [phrase],
            energy: EnergyResult(scalar: 0.6, curve: [0.4, 0.6], hopSeconds: 0.1),
            waveform: WaveformPyramid(levels: [[
                WaveformBin(min: -1, max: 1, rms: 0.5, bandRMS: [0.3, 0.2, 0.1])
            ]], sampleRate: 48_000, baseSamplesPerBin: 256), hopSeconds: 0.1)
    }

    @Test func roundTripPreservesPortableValues() throws {
        let portable = result().portable(sourceSampleRate: 48_000,
                                         sourceFrameCount: 384_000)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(portable)
        let decoded = try JSONDecoder().decode(PortableAnalysisV1.self, from: data)
        #expect(decoded == portable)
        let reconstructed = try decoded.fullAnalysisResult()
        #expect(reconstructed.phrases.first?.descriptors?.localKey?.camelot == "8B")
    }

    @Test func portableEnumsAndNilFieldsRemainStable() throws {
        #expect(PhraseTypePortable.allCases.map(\.rawValue) ==
                ["intro", "build", "drop", "chorus", "breakdown", "outro"])
        let value = PortableAnalysisV1(
            sourceSampleRate: 48_000, sourceFrameCount: 0,
            analyzedSampleRate: 48_000, durationSeconds: 0,
            loudness: PortableLoudness(integratedLUFS: -14,
                                       truePeakDBTP: -1,
                                       gainToTargetDB: 0),
            key: nil)
        let decoded = try JSONDecoder().decode(
            PortableAnalysisV1.self,
            from: JSONEncoder().encode(value))
        #expect(decoded.key == nil)
        #expect(decoded.waveform == nil)
    }

    @Test func rejectsFutureSchemaAndCorruptPayload() throws {
        var future = result().portable(sourceSampleRate: 48_000,
                                       sourceFrameCount: 384_000)
        future.schemaVersion = AnalysisSchema.currentVersion + 1
        #expect(throws: PortableAnalysisError.self) {
            _ = try JSONDecoder().decode(PortableAnalysisV1.self,
                                          from: JSONEncoder().encode(future))
        }

        var corrupt = result().portable(sourceSampleRate: 48_000,
                                        sourceFrameCount: 384_000)
        corrupt.sourceSampleRate = 0
        #expect(throws: PortableAnalysisError.self) {
            _ = try JSONDecoder().decode(PortableAnalysisV1.self,
                                          from: JSONEncoder().encode(corrupt))
        }
    }
}
