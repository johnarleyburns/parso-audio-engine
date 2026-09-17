import Testing
import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoDJEngine

@Suite("Platterhead public contract")
@MainActor
struct PlatterheadContractTests {
    private func pcm(frequency: Double) -> PCMBuffer {
        let buffer = PCMBuffer(format: AudioFormat(sampleRate: 48_000, channelCount: 2),
                               capacity: 384_000)
        for frame in 0..<buffer.frameCount {
            let sample = Float(sin(2 * Double.pi * frequency * Double(frame) / 48_000)) * 0.35
            buffer.channel(0)[frame] = sample
            buffer.channel(1)[frame] = sample
        }
        return buffer
    }

    private func analyzed(_ frequency: Double, keyTonic: Int) -> (PCMBuffer, FullAnalysisResult) {
        let buffer = pcm(frequency: frequency)
        let input = AnalysisAudio(sampleRate: 48_000, channels: [Array(buffer.channel(0))])
        var result = FullAnalysis.run(input)
        let key = KeyEstimate(tonic: keyTonic, isMinor: false,
                              camelot: Camelot.from(tonic: keyTonic, isMinor: false)!,
                              confidence: 0.9, musicalKey: "contract")
        let beats = stride(from: 0, through: 336_000, by: 24_000).map(Int64.init)
        result.bpm = 120
        result.key = key
        result.beatGrid = BeatGrid(firstBeatSample: 0, bpm: 120,
                                   beatSamples: beats,
                                   confidence: [Float](repeating: 0.9, count: beats.count),
                                   isConstantTempo: true)
        result.downbeats = [0, 4, 8, 12]
        result.phrases = [Phrase(startSample: 0, endSample: 336_000,
                                 startBeat: 0, lengthBeats: 16,
                                 type: .outro, energy: 5, confidence: 0.9,
                                 descriptors: PhraseLocalDescriptors(
                                    energy: 5, bassEnergy: 0.25,
                                    brightness: 0.5, transientDensity: 0.2,
                                    harmonicStability: 0.9,
                                    localKey: PortableKey(tonic: keyTonic,
                                                          mode: .major,
                                                          camelot: key.camelot.code,
                                                          confidence: 0.9),
                                    spectralDensity: 0.2))]
        return (buffer, result)
    }

    @Test func publicTransitionLabFlowIsComplete() throws {
        let (pcmA, analysisA) = analyzed(220, keyTonic: 0)
        let (pcmB, analysisB) = analyzed(330, keyTonic: 0)
        let portableA = try JSONDecoder().decode(
            PortableAnalysisV1.self,
            from: JSONEncoder().encode(analysisA.portable(
                sourceSampleRate: 48_000, sourceFrameCount: Int64(pcmA.frameCount))))
        let portableB = try JSONDecoder().decode(
            PortableAnalysisV1.self,
            from: JSONEncoder().encode(analysisB.portable(
                sourceSampleRate: 48_000, sourceFrameCount: Int64(pcmB.frameCount))))
        let intent = TransitionPlanningIntent(preferredBars: [1], limit: 1)
        let proposal = try #require(TransitionPlanner.proposals(
            from: portableA, to: portableB, intent: intent).first)
        #expect(proposal.outSample >= 0)
        #expect(proposal.inSample >= 0)
        #expect(proposal.outSample < pcmA.frameCount)
        #expect(proposal.inSample < pcmB.frameCount)

        let preview = try TransitionPreviewRenderer.render(
            from: TransitionPreviewSource(pcm: pcmA, analysis: analysisA),
            to: TransitionPreviewSource(pcm: pcmB, analysis: analysisB),
            proposal: proposal,
            configuration: TransitionPreviewConfiguration(preRollBars: 1,
                                                          postRollBars: 1))
        #expect(preview.pcm.format.channelCount == 2)
        #expect(preview.pcm.frameCount > 0)
        #expect(preview.transitionEndFrame > preview.transitionStartFrame)
        #expect(preview.pcm.channel(0).allSatisfy { $0.isFinite })

        let engine = HeadlessDJEngine(deckCount: 2, profile: .transitionLab)
        engine.deckA.load(analysisA.trackAnalysis(format: pcmA.format), buffer: pcmA)
        engine.deckB.load(analysisB.trackAnalysis(format: pcmB.format), buffer: pcmB)
        try engine.mixer.smartFader.arm(from: engine.deckA, to: engine.deckB,
                                        proposal: proposal)
        for _ in 0..<500 { _ = engine.render(frames: 256) }
        #expect(engine.mixer.smartFader.snapshot.state == .completed)
        #expect(engine.mixer.smartFader.snapshot.progress == 0)

        let snapshot = engine.preparationSnapshot()
        let restored = HeadlessDJEngine(deckCount: 2, profile: .transitionLab)
        restored.deckA.load(analysisA.trackAnalysis(format: pcmA.format), buffer: pcmA)
        restored.deckB.load(analysisB.trackAnalysis(format: pcmB.format), buffer: pcmB)
        try restored.restorePreparationSnapshot(snapshot)
        #expect(restored.preparationSnapshot() == snapshot)

        let poor = analyzed(330, keyTonic: 6).1
        let poorProposal = try #require(TransitionPlanner.proposals(
            from: analysisA, to: poor, intent: intent).first)
        #expect(poorProposal.score <= proposal.score)
        #expect(poorProposal.clashes.harmonicTension >= proposal.clashes.harmonicTension)
    }
}
