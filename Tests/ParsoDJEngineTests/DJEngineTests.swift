//
//  DJEngineTests.swift
//  Headless (device-free) engine behavior tests. The API-shape suite runs now;
//  render-behavior suites are `.disabled` until the RT engine is implemented (docs/SPEC.md §11).
//

import Testing
import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoDJEngine
import ParsoTestSupport

// MARK: - Real now: API surface is wired

@Suite("DJ API surface")
struct DJAPITests {
    @Test func allBeatFXKindsEnumerated() {
        // Sanity that the FLX4 Beat-FX palette is present.
        #expect(BeatFXUnit.Kind.allCases.count >= 12)
        #expect(BeatFXUnit.Kind.allCases.contains(.echo))
        #expect(BeatFXUnit.Kind.allCases.contains(.reverb))
        #expect(BeatFXUnit.Kind.allCases.contains(.roll))
    }

    @Test func eightPadModesExist() {
        let modes: [PadMode] = [.hotCue, .keyboard, .padFX1, .padFX2, .beatJump, .beatLoop, .sampler, .keyShift]
        #expect(modes.count == 8)
    }
}

// MARK: - Pending implementation (docs/SPEC.md §11)

/// Loads two analyzed tone tracks into a headless engine for deterministic assertions.
@MainActor
private func makeLoadedHeadless(bpmA: Double = 120, bpmB: Double = 128) -> HeadlessDJEngine {
    let engine = HeadlessDJEngine()
    func load(_ deck: Deck, bpm: Double, freq: Double) {
        let pcm = SignalGenerators.sine(frequency: freq, seconds: 8, sampleRate: 48_000, channels: 2)
        let analysis = TrackAnalysis(
            format: pcm.format, duration: 8,
            tempo: .init(bpm: bpm, confidence: 1, beatPositions: [], downbeatPositions: [], isConstantTempo: true),
            key: .init(tonic: 0, mode: .major, camelot: "8B", openKey: "1d", confidence: 1),
            sections: [], waveform: .init(overviewMinMax: [], detailRMS: [], bandEnergy: []),
            loudness: .init(integratedLUFS: -14, truePeakDBTP: -1, gainToTargetDB: 0))
        deck.load(analysis, buffer: pcm)
    }
    load(engine.deckA, bpm: bpmA, freq: 220)
    load(engine.deckB, bpm: bpmB, freq: 330)
    return engine
}

@Suite("Crossfader")
@MainActor
struct CrossfaderTests {
    @Test func fullLeftIsolatesDeckA() {
        let e = makeLoadedHeadless()
        e.deckA.play(); e.deckB.play()
        e.mixer.crossfader = -1
        let out = e.render(frames: 2048)
        // Deck A tone (220 Hz) present; Deck B tone (330 Hz) absent.
        let buf = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 1), capacity: out.left.count)
        for i in out.left.indices { buf.channel(0)[i] = out.left[i] }
        #expect(Measure.goertzelMagnitude(buf, frequency: 220) > Measure.goertzelMagnitude(buf, frequency: 330) * 8)
    }

    @Test func centerIsApproximatelyEqualPower() {
        let e = makeLoadedHeadless()
        e.deckA.play(); e.deckB.play()
        e.mixer.crossfaderCurve = .smooth
        e.mixer.crossfader = 0
        let out = e.render(frames: 4096)
        let buf = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 1), capacity: out.left.count)
        for i in out.left.indices { buf.channel(0)[i] = out.left[i] }
        let a = Measure.goertzelMagnitude(buf, frequency: 220)
        let b = Measure.goertzelMagnitude(buf, frequency: 330)
        #expect(abs(a - b) / max(a, b) < 0.2)   // roughly balanced
    }
}

@Suite("Sync", .disabled("Implement beat sync — docs/SPEC.md §11.2"))
@MainActor
struct SyncTests {
    @Test func syncMatchesTempoToMaster() {
        let e = makeLoadedHeadless(bpmA: 120, bpmB: 128)
        e.deckA.setAsMaster()
        e.deckB.sync()
        e.deckA.play(); e.deckB.play()
        _ = e.render(frames: 1024)
        // Deck B's effective tempo ratio should target 120/128.
        #expect(abs(e.deckB.tempoPercent - (120.0 / 128.0 - 1) * 100) < 1.0)
    }
}

@Suite("Loops", .disabled("Implement looping — docs/SPEC.md §11.2"))
@MainActor
struct LoopTests {
    @Test func autoBeatLoopProducesPeriodicOutput() {
        let e = makeLoadedHeadless(bpmA: 120)
        e.deckA.play()
        e.mixer.crossfader = -1
        e.deckA.autoBeatLoop(beats: 4)
        let out = e.render(frames: 48_000)  // 1 s
        // A 4-beat loop at 120 BPM is 2 s, so within 1 s output must be non-empty and bounded.
        let peak = out.left.map(abs).max() ?? 0
        #expect(peak > 0 && peak <= 1.0001)
    }
}

@Suite("Hot cues", .disabled("Implement hot cues — docs/SPEC.md §11.2"))
@MainActor
struct HotCueTests {
    @Test func jumpResetsPlayhead() {
        let e = makeLoadedHeadless()
        e.deckA.play()
        _ = e.render(frames: 24_000)  // advance ~0.5 s
        e.deckA.setHotCue(0)
        _ = e.render(frames: 24_000)  // advance further
        e.deckA.jumpHotCue(0)
        let after = e.deckA.playhead
        #expect(abs(after - 0.5) < 0.05)
    }
}

@Suite("Slip mode", .disabled("Implement slip — docs/SPEC.md §11.2"))
@MainActor
struct SlipTests {
    @Test func slipResumesAtShadowPosition() {
        let e = makeLoadedHeadless()
        e.deckA.slip = true
        e.deckA.play()
        _ = e.render(frames: 24_000)
        e.deckA.autoBeatLoop(beats: 1)
        _ = e.render(frames: 24_000)
        e.deckA.reloopExit()
        // With slip, playhead resumes where continuous playback would be (~1 s), not the loop end.
        #expect(e.deckA.playhead > 0.9)
    }
}

@Suite("Smart Fader", .disabled("Implement Smart Fader — docs/SPEC.md §11.5"))
@MainActor
struct SmartFaderTests {
    @Test func transitionSyncsAndDucksOutgoingLows() {
        let e = makeLoadedHeadless(bpmA: 120, bpmB: 128)
        e.deckA.play(); e.deckB.play()
        e.mixer.smartFader.isEnabled = true
        e.mixer.smartFader.tail = .echo
        e.mixer.smartFader.performTransition(from: e.deckA, to: e.deckB, over: 4)
        _ = e.render(frames: 4096)
        // Incoming deck tempo converged toward outgoing master.
        #expect(abs(e.deckB.tempoPercent - (120.0 / 128.0 - 1) * 100) < 2.0)
        // Outgoing lows attenuated during the blend.
        #expect(e.mixer.channelA.eqLow < 0)
    }
}

@Suite("Pad modes", .disabled("Implement pad modes — docs/SPEC.md §11.3"))
@MainActor
struct PadModeTests {
    @Test func beatLoopPadSetsLoop() {
        let e = makeLoadedHeadless()
        e.deckA.padMode = .beatLoop
        e.deckA.play()
        e.deckA.padPress(2)          // e.g. a fixed loop length
        let out = e.render(frames: 4096)
        #expect((out.left.map(abs).max() ?? 0) > 0)
    }

    @Test func samplerPadTriggersSlot() {
        let e = makeLoadedHeadless()
        e.sampler.load(0, buffer: SignalGenerators.sine(frequency: 660, seconds: 0.5, sampleRate: 48_000, channels: 2))
        e.deckA.padMode = .sampler
        e.deckA.padPress(0)
        let out = e.render(frames: 8192)
        let buf = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 1), capacity: out.left.count)
        for i in out.left.indices { buf.channel(0)[i] = out.left[i] }
        #expect(Measure.goertzelMagnitude(buf, frequency: 660) > 0)
    }

    @Test func keyShiftChangesPitchSemitones() {
        let e = makeLoadedHeadless()
        e.deckA.padMode = .keyShift
        e.deckA.padPress(7)          // shift up N semitones
        #expect(e.deckA.pitchSemitones != 0)
    }
}
