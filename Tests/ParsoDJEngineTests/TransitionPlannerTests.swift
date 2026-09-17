import Testing
import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoDJEngine

@Suite("Transition Planner")
struct TransitionPlannerTests {
    private func result(bpm: Double, tonic: Int, phraseType: PhraseType,
                        bass: Double, density: Double) -> FullAnalysisResult {
        let key = KeyEstimate(tonic: tonic, isMinor: false,
                              camelot: Camelot.from(tonic: tonic, isMinor: false)!,
                              confidence: 0.9, musicalKey: "test")
        let grid = BeatGrid(firstBeatSample: 0, bpm: bpm,
                            beatSamples: stride(from: 0, through: 240_000, by: 24_000).map(Int64.init),
                            confidence: [Float](repeating: 0.9, count: 11),
                            isConstantTempo: true)
        let descriptor = PhraseLocalDescriptors(energy: 5, bassEnergy: bass,
                                                brightness: 0.5, transientDensity: 0.4,
                                                harmonicStability: 0.9,
                                                localKey: PortableKey(tonic: tonic, mode: .major,
                                                                      camelot: key.camelot.code,
                                                                      confidence: 0.9),
                                                spectralDensity: density)
        let phrase = Phrase(startSample: 0, endSample: 192_000, startBeat: 0,
                            lengthBeats: 16, type: phraseType, energy: 5,
                            confidence: 0.9, descriptors: descriptor)
        return FullAnalysisResult(
            loudness: LoudnessResult(integratedLUFS: -14, truePeakDBTP: -1,
                                     gainToTargetDB: 0, loudnessRangeLU: 4),
            bpm: bpm, key: key, beatGrid: grid, downbeats: [0, 4, 8],
            phrases: [phrase], energy: EnergyResult(scalar: 5,
                                                     curve: [0.5], hopSeconds: 0.1),
            waveform: nil, hopSeconds: 0.1)
    }

    @Test func proposalsAreDeterministicAndAligned() {
        let a = result(bpm: 120, tonic: 0, phraseType: .outro, bass: 0.9, density: 0.2)
        let b = result(bpm: 120, tonic: 0, phraseType: .intro, bass: 0.9, density: 0.2)
        let first = TransitionPlanner.proposals(from: a, to: b)
        let second = TransitionPlanner.proposals(from: a, to: b)
        #expect(first == second)
        #expect(!first.isEmpty)
        #expect(first[0].outSample == 0)
        #expect(first[0].inSample == 0)
        #expect(first[0].technique == .bassSwap)
        #expect(first.allSatisfy { $0.score.isFinite && $0.clashes.combined <= 1 })
    }

    @Test func proposalCodableRoundTrip() throws {
        let a = result(bpm: 124, tonic: 0, phraseType: .outro, bass: 0.2, density: 0.1)
        let b = result(bpm: 124, tonic: 0, phraseType: .intro, bass: 0.2, density: 0.1)
        let proposal = try #require(TransitionPlanner.proposals(from: a, to: b).first)
        let data = try JSONEncoder().encode(proposal)
        let decoded = try JSONDecoder().decode(AudioTransitionProposal.self, from: data)
        #expect(decoded == proposal)
    }
}
