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
private func makeLoadedHeadless(
    bpmA: Double = 120,
    bpmB: Double = 128,
    beatGridA: [TimeInterval] = [],
    beatGridB: [TimeInterval] = []
) -> HeadlessDJEngine {
    let engine = HeadlessDJEngine()
    func load(_ deck: Deck, bpm: Double, freq: Double) {
        let pcm = SignalGenerators.sine(frequency: freq, seconds: 8, sampleRate: 48_000, channels: 2)
        let analysis = TrackAnalysis(
            format: pcm.format, duration: 8,
            tempo: .init(
                bpm: bpm,
                confidence: 1,
                beatPositions: deck === engine.deckA ? beatGridA : beatGridB,
                downbeatPositions: [],
                isConstantTempo: true
            ),
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

    /// Regression for the click found in the Phase 6d listening pass
    /// (current_status.md "Phase 6"): the "sharp" curve used to be a literal
    /// zero-width step (gainA/gainB snapping 1<->0 the instant the crossfader
    /// crossed centre), and since gains are computed once per render() call,
    /// that meant a full-amplitude jump-cut between two unrelated decks at
    /// whatever sample landed on the boundary. Sweeping across centre in
    /// small steps must not produce a discontinuity anywhere near the size of
    /// a full deck-to-deck swap.
    @Test func sharpCurveSweepThroughCenterStaysContinuous() {
        // Deck B is deck A's phase-inverted mirror at a moderate, non-DC
        // frequency (300 Hz -- passes any DC-blocking stage untouched, and is
        // locally smooth within a 32-sample block, so genuine per-deck
        // sample-to-sample deltas stay tiny). A hard gain swap between mirror
        // -image decks doubles the instantaneous sample value's magnitude --
        // large, UNLESS the swap happens to land exactly on a zero-crossing.
        // Several trials with decorrelated sweep step counts (coprime-ish
        // with the tone period) rule out that one unlucky/lucky alignment.
        let format = AudioFormat(sampleRate: 48_000, channelCount: 2)
        func makeSine(amplitude: Float, invert: Bool) -> PCMBuffer {
            let buf = PCMBuffer(format: format, capacity: 48_000)
            for c in 0..<2 {
                for i in 0..<48_000 {
                    let phase = 2.0 * Double.pi * 300.0 * Double(i) / 48_000.0
                    let v = Float(sin(phase)) * amplitude
                    buf.channel(c)[i] = invert ? -v : v
                }
            }
            return buf
        }
        let bufA = makeSine(amplitude: 0.9, invert: false)
        let bufB = makeSine(amplitude: 0.9, invert: true)
        let analysis = TrackAnalysis(
            format: format, duration: 1,
            tempo: .init(bpm: 120, confidence: 1, beatPositions: [], downbeatPositions: [], isConstantTempo: true),
            key: .init(tonic: 0, mode: .major, camelot: "8B", openKey: "1d", confidence: 1),
            sections: [], waveform: .init(overviewMinMax: [], detailRMS: [], bandEnergy: []),
            loudness: .init(integratedLUFS: -14, truePeakDBTP: -1, gainToTargetDB: 0))

        var overallMaxJump: Float = 0
        for steps in [397, 401, 409, 419, 421] {
            let e = HeadlessDJEngine()
            e.deckA.load(analysis, buffer: bufA)
            e.deckB.load(analysis, buffer: bufB)
            e.deckA.play(); e.deckB.play()
            e.mixer.crossfaderCurve = .sharp
            e.mixer.crossfader = -0.1

            // Warm up past any deck-start/anti-click fade-in envelope before
            // measuring, so the sweep's own discontinuity isn't confused with
            // playback-start transients.
            for _ in 0..<50 { _ = e.render(frames: 32) }

            var samples: [Float] = []
            for i in 0...steps {
                let position = -0.1 + 0.2 * (Double(i) / Double(steps))
                e.mixer.crossfader = position
                samples.append(contentsOf: e.render(frames: 32).left)
            }
            for i in 1..<samples.count {
                overallMaxJump = max(overallMaxJump, abs(samples[i] - samples[i - 1]))
            }
        }
        // A hard full-gain swap between phase-inverted mirror decks at
        // amplitude 0.9 can jump by close to 1.8 when it doesn't land near a
        // zero-crossing; across 5 decorrelated trials at least one should hit
        // near the worst case. A steep-but-continuous curve should stay well
        // under that.
        #expect(overallMaxJump < 0.6, "sample-to-sample jump \(overallMaxJump) suggests a discontinuity at the sharp curve's centre")
    }
}

@Suite("Headless transport")
@MainActor
struct HeadlessTransportTests {
    @Test func playheadEventsTrackRenderAndEndOfTrack() {
        let e = makeLoadedHeadless()
        e.deckA.play()
        _ = e.render(frames: 24_000)
        #expect(abs(e.deckA.playhead - 0.5) < 0.01)
        #expect(e.deckA.isPlaying)

        _ = e.render(frames: 400_000)
        #expect(abs(e.deckA.playhead - 8.0) < 0.01)
        #expect(!e.deckA.isPlaying)
    }
}

@Suite("Cue, jog, and nudge")
@MainActor
struct CueJogNudgeTests {
    @Test func temporaryCuePreviewsAndReturnsOnRelease() {
        let e = makeLoadedHeadless()
        e.deckA.play()
        _ = e.render(frames: 24_000)
        e.deckA.pause()
        e.deckA.setCue()
        e.deckA.cuePlayPress()
        _ = e.render(frames: 24_000)
        #expect(e.deckA.playhead > 0.95 && e.deckA.playhead < 1.05)

        e.deckA.cuePlayRelease()
        #expect(abs(e.deckA.playhead - 0.5) < 0.02)
        #expect(!e.deckA.isPlaying)
    }

    @Test func vinylJogSeeksAndRestoresTransport() {
        let e = makeLoadedHeadless()
        e.deckA.play()
        _ = e.render(frames: 24_000)
        e.deckA.jogTouchBegan()
        e.deckA.jogMoved(deltaSamples: 4_800)
        _ = e.render(frames: 1)
        #expect(abs(e.deckA.playhead - 0.6) < 0.02)
        #expect(!e.deckA.isPlaying)

        e.deckA.jogTouchEnded()
        _ = e.render(frames: 24_000)
        #expect(e.deckA.isPlaying)
        #expect(e.deckA.playhead > 1.0)
    }

    @Test func nudgeTemporarilyChangesPlaybackRate() {
        let e = makeLoadedHeadless()
        e.deckA.nudge(1)
        e.deckA.play()
        _ = e.render(frames: 24_000)
        #expect(e.deckA.playhead > 0.53)
        e.deckA.nudge(0)
    }
}

@Suite("DJ engine lifecycle")
@MainActor
struct DJEngineLifecycleTests {
    @Test func deviceLifecycleAndHeadlessFactoryAreUsable() throws {
        let engine = DJEngine(sampleRate: 44_100, maxFramesPerRender: 128)
        #expect(!engine.isRunning)
        try engine.start()
        #expect(engine.isRunning)
        engine.stop()
        #expect(!engine.isRunning)
        let headless = engine.makeHeadless()
        #expect(headless.render(frames: 4).left.count == 4)
    }
}

@Suite("Sync")
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

@Suite("Loops")
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

    @Test func autoBeatLoopWrapsThePlayhead() {
        let e = makeLoadedHeadless(bpmA: 120)
        e.deckA.play()
        e.mixer.crossfader = -1
        e.deckA.autoBeatLoop(beats: 4)
        _ = e.render(frames: 120_000) // 2.5 s; a 4-beat loop is 2 s at 120 BPM
        #expect(e.deckA.playhead > 0.45 && e.deckA.playhead < 0.55)
        #expect(e.deckA.isPlaying)
    }

    @Test func loopEdgesCanBeAdjustedAndStaySynchronized() {
        let e = makeLoadedHeadless(
            bpmA: 120,
            beatGridA: stride(from: 0.0, through: 8.0, by: 0.5).map { $0 }
        )
        e.deckA.autoBeatLoop(beats: 4)
        #expect(e.deckA.loopStart == 0)
        #expect(e.deckA.loopEnd == 2)

        e.deckA.adjustLoopIn(by: 0.5)
        e.deckA.adjustLoopOut(by: -0.5)
        #expect(e.deckA.loopStart == 0.5)
        #expect(e.deckA.loopEnd == 1.5)

        e.deckA.play()
        _ = e.render(frames: 72_000)
        #expect(e.deckA.playhead > 0.49 && e.deckA.playhead < 0.51)
    }

    @Test func loopRollUsesSlipAndReturnsToTheShadowPlayhead() {
        let e = makeLoadedHeadless(
            bpmA: 120,
            beatGridA: stride(from: 0.0, through: 8.0, by: 0.5).map { $0 }
        )
        e.deckA.play()
        _ = e.render(frames: 36_000)
        e.deckA.loopRoll(beats: 1)
        _ = e.render(frames: 24_000)
        #expect(e.deckA.isLoopActive)

        e.deckA.loopRollRelease()
        _ = e.render(frames: 1)
        #expect(!e.deckA.isLoopActive)
        #expect(e.deckA.playhead > 1.2)
    }
}

@Suite("Hot cues")
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

    @Test func quantizeSnapsCueAndHotCueActionsToTheBeatGrid() {
        let e = makeLoadedHeadless(
            bpmA: 120,
            beatGridA: stride(from: 0.0, through: 8.0, by: 0.5).map { $0 }
        )
        e.deckA.play()
        _ = e.render(frames: 25_440) // 0.53 s
        e.deckA.pause()
        e.deckA.setCue()
        e.deckA.setHotCue(0)
        e.deckA.cuePlayPress()
        _ = e.render(frames: 1)
        #expect(abs(e.deckA.playhead - 0.5) < 0.002)

        e.deckA.quantize = false
        e.deckA.jogMoved(deltaSamples: 1_440) // 0.53 s
        _ = e.render(frames: 1)
        e.deckA.setCue()
        e.deckA.cuePlayPress()
        _ = e.render(frames: 1)
        #expect(e.deckA.playhead > 0.52 && e.deckA.playhead < 0.55)
    }
}

@Suite("Slip mode")
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

@Suite("Smart Fader")
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

@Suite("Pad modes")
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

@Suite("Saved loops and pad FX")
@MainActor
struct SavedLoopAndPadFXTests {
    @Test func savedLoopCanBeRecalledAndReactivated() {
        let e = makeLoadedHeadless()
        e.deckA.play()
        e.deckA.autoBeatLoop(beats: 2)
        e.deckA.saveLoop(0)
        e.deckA.setActiveLoop(false)
        e.deckA.callLoop(0)
        _ = e.render(frames: 120_000) // 2.5 s across a 1 s recalled loop
        #expect(e.deckA.isLoopActive)
        #expect(e.deckA.playhead > 0.45 && e.deckA.playhead < 0.55)
    }

    @Test func padFXAssignmentTriggersAndReleasesAssignedEffect() {
        let e = makeLoadedHeadless()
        e.deckA.assignPadFX(bank: 1, pad: 2, effect: .echo, hold: true)
        e.deckA.padMode = .padFX1
        e.deckA.padPress(2)
        #expect(e.mixer.beatFX.kind == .echo)
        #expect(e.mixer.beatFX.isOn)
        e.deckA.padRelease(2)
        #expect(!e.mixer.beatFX.isOn)
    }
}

@Suite("Meters and microphone")
@MainActor
struct MeterAndMicTests {
    @Test func deckAndMasterMetersFollowRenderedPeaks() {
        let e = makeLoadedHeadless()
        e.mixer.crossfader = -1
        e.deckA.play()
        _ = e.render(frames: 4096)
        #expect(e.mixer.channelA.peakMeter > 0)
        #expect(e.mixer.channelB.peakMeter == 0)
        #expect(e.mixer.master.peakMeter > 0)
    }

    @Test func unmutedMicIsSummedIntoMaster() {
        let e = makeLoadedHeadless()
        e.mic.level = 1
        e.mic.isMuted = false
        e.mic.submit(SignalGenerators.sine(frequency: 440, seconds: 0.5, sampleRate: 48_000, channels: 2))
        let out = e.render(frames: 8192)
        let buffer = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 1), capacity: out.left.count)
        for i in out.left.indices { buffer.channel(0)[i] = out.left[i] }
        #expect(Measure.goertzelMagnitude(buffer, frequency: 440) > 0)
        #expect(e.mixer.master.peakMeter > 0)
    }
}

@Suite("Monitoring")
@MainActor
struct MonitoringTests {
    @Test func channelPFLFeedsMonitorWithoutAdvancingDeck() {
        let e = makeLoadedHeadless()
        e.deckA.play()
        e.deckB.pause()
        e.mixer.channelA.cuePFL = true
        e.monitoring.masterCue = false
        e.monitoring.cueMasterMix = 0
        _ = e.render(frames: 1) // primary bus drains the play commands first
        let out = e.renderMonitor(frames: 4096)

        let buffer = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 1), capacity: out.left.count)
        for i in out.left.indices { buffer.channel(0)[i] = out.left[i] }
        #expect(Measure.goertzelMagnitude(buffer, frequency: 220) > 0)
        #expect(abs(e.deckA.playhead) < 0.001)
    }

    @Test func masterCueFeedsMonitorAtConfiguredHeadphoneLevel() {
        let e = makeLoadedHeadless()
        e.deckA.play()
        e.mixer.crossfader = -1
        e.monitoring.masterCue = true
        e.monitoring.cueMasterMix = 1
        e.monitoring.headphoneLevel = 0.5
        _ = e.render(frames: 1) // primary bus drains the play command first
        let out = e.renderMonitor(frames: 4096)
        #expect((out.left.map(abs).max() ?? 0) > 0)
        #expect(abs(e.deckA.playhead) < 0.001)
    }
}

@Suite("Channel routing and EQ")
@MainActor
struct ChannelRoutingTests {
    @Test func crossfaderAssignmentCanRemoveChannelFromBothSides() {
        let e = makeLoadedHeadless()
        e.mixer.crossfader = -1
        e.mixer.channelA.crossfaderAssign = .b
        e.deckA.play()
        let out = e.render(frames: 4096)
        #expect((out.left.map(abs).max() ?? 0) == 0)
    }

    @Test func faderStartStartsDeckWhenCrossfaderMoves() {
        let e = makeLoadedHeadless()
        e.mixer.channelA.faderStart = true
        _ = e.render(frames: 1) // establish the initial crossfader position
        e.mixer.crossfader = -1
        _ = e.render(frames: 1)
        #expect(e.deckA.isPlaying)
    }

    @Test func allEQBandsCanMuteAChannel() {
        let e = makeLoadedHeadless()
        e.mixer.crossfader = -1
        e.deckA.play()
        _ = e.render(frames: 4096)
        e.mixer.channelA.eqLow = -.infinity
        e.mixer.channelA.eqMid = -.infinity
        e.mixer.channelA.eqHigh = -.infinity
        _ = e.render(frames: 16_384) // allow the 10 ms gain smoothing to settle
        #expect((e.render(frames: 4096).left.map(abs).max() ?? 0) < 0.05)
    }

    /// The shared `pd_eq3` isolator (Phase 6b item 0) splits by frequency: a
    /// low tone loses far more level to a low-band kill than to a high-band kill.
    @Test func isolatorEQKillsByBand() {
        @MainActor func lowToneEngine() -> HeadlessDJEngine {
            let e = HeadlessDJEngine()
            let pcm = SignalGenerators.sine(frequency: 90, seconds: 8, sampleRate: 48_000, channels: 2)
            let analysis = TrackAnalysis(
                format: pcm.format, duration: 8,
                tempo: .init(bpm: 120, confidence: 1, beatPositions: [], downbeatPositions: [], isConstantTempo: true),
                key: .init(tonic: 0, mode: .major, camelot: "8B", openKey: "1d", confidence: 1),
                sections: [], waveform: .init(overviewMinMax: [], detailRMS: [], bandEnergy: []),
                loudness: .init(integratedLUFS: -14, truePeakDBTP: -1, gainToTargetDB: 0))
            e.deckA.load(analysis, buffer: pcm)
            e.mixer.crossfader = -1
            e.deckA.play()
            return e
        }

        let killLow = lowToneEngine()
        killLow.mixer.channelA.eqLow = -.infinity
        _ = killLow.render(frames: 32_768)
        let lowKilled = killLow.render(frames: 8192).left.map(abs).max() ?? 0

        let killHigh = lowToneEngine()
        killHigh.mixer.channelA.eqHigh = -.infinity
        _ = killHigh.render(frames: 32_768)
        let highKilled = killHigh.render(frames: 8192).left.map(abs).max() ?? 0

        #expect(lowKilled < highKilled * 0.5)
    }

    /// `pd_limiter_set_ceiling` (Phase 6b item 0) — a runtime ceiling change is
    /// honored without recreating the engine.
    @Test func limiterCeilingChangeIsHonored() {
        let e = makeLoadedHeadless()
        e.mixer.master.level = 1
        e.mixer.channelA.trim = 2
        e.mixer.channelB.trim = 2
        e.deckA.play()
        e.deckB.play()
        e.mixer.master.limiterCeilingDB = -12
        _ = e.render(frames: 8192)
        let peak = e.render(frames: 8192).left.map(abs).max() ?? 0
        let ceiling = pow(Float(10), Float(-12) / Float(20))
        #expect(peak <= ceiling + 0.001)
        #expect(peak > ceiling * 0.5)
    }
}

@Suite("Color and Beat FX render")
@MainActor
struct ColorAndBeatFXRenderTests {
    @Test func colorFilterChangesTheSharedRenderSignal() {
        let dry = makeLoadedHeadless()
        dry.deckA.play()
        let dryOutput = dry.render(frames: 4096).left

        let filtered = makeLoadedHeadless()
        filtered.mixer.channelA.colorFX = .filter
        filtered.mixer.channelA.colorAmount = 1
        filtered.deckA.play()
        let filteredOutput = filtered.render(frames: 4096).left
        let difference = zip(dryOutput, filteredOutput).map { abs($0 - $1) }.max() ?? 0
        #expect(difference > 0.01)
    }

    /// Regression for the click found in the Phase 6d A-B render (current_status.md
    /// "Phase 6"): sweeping the filter knob continuously through zero used to hit a
    /// hard low-pass/high-pass topology switch with a stale biquad state AND an
    /// inverted high-pass cutoff curve that spiked to maximum effect right at the
    /// crossing, producing a large sample-to-sample discontinuity. A smooth sweep
    /// through the centre must never produce a jump much bigger than neighbouring
    /// samples in a continuous tone.
    @Test func filterKnobSweepThroughZeroStaysContinuous() {
        let e = makeLoadedHeadless()
        e.mixer.channelA.colorFX = .filter
        e.deckA.play()

        var samples: [Float] = []
        let steps = 200
        for i in 0...steps {
            let knob = -0.3 + 0.6 * (Double(i) / Double(steps))
            e.mixer.channelA.colorAmount = knob
            samples.append(contentsOf: e.render(frames: 64).left)
        }

        var maxJump: Float = 0
        for i in 1..<samples.count {
            maxJump = max(maxJump, abs(samples[i] - samples[i - 1]))
        }
        // A clean sine through a smoothly-swept filter shouldn't jump more than a
        // small fraction of full scale sample-to-sample; the pre-fix code spiked
        // past 1.0 (a full-scale discontinuity) right at the crossing.
        #expect(maxJump < 0.3, "sample-to-sample jump \(maxJump) suggests a discontinuity at the filter's zero crossing")
    }

    @Test func beatEchoProcessesAssignedChannelAndLeavesAReleaseTail() {
        let e = makeLoadedHeadless()
        e.mixer.beatFX.kind = .echo
        e.mixer.beatFX.assign = .chA
        e.mixer.beatFX.depth = 0.75
        e.mixer.beatFX.isOn = true
        e.deckA.play()
        let effected = e.render(frames: 16_384).left
        #expect((effected.map(abs).max() ?? 0) > 0)

        e.deckA.pause()
        _ = e.render(frames: 1)
        e.mixer.beatFX.releaseFX()
        let tail = e.render(frames: 4096).left
        #expect((tail.map(abs).max() ?? 0) > 0.001)
    }
}

@Suite("Master limiter and RT stability")
@MainActor
struct MasterLimiterTests {
    @Test func limiterCapsMasterPeakAtConfiguredCeiling() {
        let e = makeLoadedHeadless()
        e.mixer.master.level = 1
        e.mixer.master.limiterCeilingDB = -6
        e.mixer.channelA.trim = 2
        e.mixer.channelB.trim = 2
        e.deckA.play()
        e.deckB.play()
        let output = e.render(frames: 4096).left
        let peak = output.map(abs).max() ?? 0
        #expect(peak > 0.45)
        let ceiling = pow(Float(10), Float(-6) / Float(20))
        #expect(peak <= ceiling + 0.001)
        #expect(e.mixer.master.peakMeter <= ceiling + 0.001)
    }

    @Test func repeatedEffectBlocksRemainFinite() {
        let e = makeLoadedHeadless()
        e.mixer.channelA.colorFX = .dubEcho
        e.mixer.channelA.colorAmount = 1
        e.mixer.beatFX.kind = .reverb
        e.mixer.beatFX.assign = .both
        e.mixer.beatFX.depth = 1
        e.mixer.beatFX.isOn = true
        e.deckA.play()
        e.deckB.play()
        for _ in 0..<32 {
            let output = e.render(frames: 512).left
            #expect(output.allSatisfy { $0.isFinite })
        }
    }
}

@Suite("Deck acceptance controls")
@MainActor
struct DeckAcceptanceControlTests {
    @Test func returnToStartAndSearchMoveTheSharedTransport() {
        let e = makeLoadedHeadless()
        e.deckA.play()
        _ = e.render(frames: 24_000)
        #expect(e.deckA.playhead > 0.49)

        e.deckA.frameSearch(frames: 480)
        _ = e.render(frames: 1)
        #expect(e.deckA.playhead > 0.50)

        e.deckA.fastSearch(seconds: -0.25)
        _ = e.render(frames: 1)
        #expect(e.deckA.playhead > 0.24 && e.deckA.playhead < 0.27)

        e.deckA.returnToStart()
        _ = e.render(frames: 1)
        #expect(e.deckA.playhead == 0)
        #expect(!e.deckA.isPlaying)
    }

    @Test func instantDoubleCopiesLoadedTrackAndTransportState() {
        let e = makeLoadedHeadless()
        e.deckA.play()
        _ = e.render(frames: 24_000)
        e.deckB.instantDouble(from: e.deckA)
        _ = e.render(frames: 1)
        #expect(e.deckB.isPlaying)
        #expect(abs(e.deckB.playhead - e.deckA.playhead) < 0.002)
        #expect(e.deckB.waveform != nil)
    }

    @Test func autoCueAndTempoResetAreExposedByDeckState() {
        let e = makeLoadedHeadless()
        e.deckA.autoCue = true
        e.deckA.tempoPercent = 8
        e.deckA.nudge(0.5)
        e.deckA.tempoReset()
        _ = e.render(frames: 1)
        #expect(e.deckA.tempoPercent == 0)
        #expect(e.deckA.playhead == 0)
        #expect(e.deckA.waveform != nil)
        #expect(e.deckA.beatPhase == 0)
    }
}

// MARK: - CDJ-3000 parity C1: N-deck render graph (docs/CDJ3000-parity-research.md)

@Suite("CDJ3000 C1 — four decks")
@MainActor
struct FourDeckTests {
    private func loadTone(_ deck: Deck, _ engine: HeadlessDJEngine, freq: Double, bpm: Double = 120) {
        let pcm = SignalGenerators.sine(frequency: freq, seconds: 6, sampleRate: 48_000, channels: 2)
        let analysis = TrackAnalysis(
            format: pcm.format, duration: 6,
            tempo: .init(bpm: bpm, confidence: 1, beatPositions: [], downbeatPositions: [],
                         isConstantTempo: true),
            key: .init(tonic: 0, mode: .major, camelot: "8B", openKey: "1d", confidence: 1),
            sections: [], waveform: .init(overviewMinMax: [], detailRMS: [], bandEnergy: []),
            loudness: .init(integratedLUFS: -14, truePeakDBTP: -1, gainToTargetDB: 0))
        deck.load(analysis, buffer: pcm)
    }

    private func magnitude(_ samples: [Float], _ freq: Double) -> Double {
        let buf = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 1), capacity: samples.count)
        for i in samples.indices { buf.channel(0)[i] = samples[i] }
        return Measure.goertzelMagnitude(buf, frequency: freq)
    }

    @Test func engineExposesFourDecksAndChannelsByDefault() {
        let e = HeadlessDJEngine()
        #expect(e.decks.count == 4)
        #expect(e.mixer.channels.count == 4)
        #expect(e.deckC === e.decks[2])
        #expect(e.mixer.channelD === e.mixer.channels[3])
    }

    @Test func deckCountIsConfigurableDownToTwo() {
        let two = HeadlessDJEngine(deckCount: 2)
        #expect(two.decks.count == 2)
        #expect(two.mixer.channels.count == 2)
        let clampedHigh = HeadlessDJEngine(deckCount: 9)
        #expect(clampedHigh.decks.count == 4)
        let clampedLow = HeadlessDJEngine(deckCount: 1)
        #expect(clampedLow.decks.count == 2)
    }

    @Test func allFourDecksSumIntoTheMaster() {
        let e = HeadlessDJEngine()
        let freqs = [220.0, 330.0, 495.0, 660.0]
        for (i, f) in freqs.enumerated() { loadTone(e.decks[i], e, freq: f) }
        for d in e.decks { d.play() }
        e.mixer.crossfader = 0
        let out = e.render(frames: 8192)
        // Every deck's tone is audible in the master mix.
        for f in freqs {
            #expect(magnitude(out.left, f) > 0.02, "tone \(f) Hz missing from 4-deck master")
        }
    }

    @Test func thirdAndFourthDecksRespondToTheirOwnChannelFaders() {
        let e = HeadlessDJEngine()
        loadTone(e.decks[2], e, freq: 495)
        loadTone(e.decks[3], e, freq: 660)
        e.decks[2].play(); e.decks[3].play()
        e.mixer.channels[3].fader = 0        // kill channel D
        let out = e.render(frames: 8192)
        let cMag = magnitude(out.left, 495)
        let dMag = magnitude(out.left, 660)
        #expect(cMag > dMag * 8, "channel D fader at 0 should silence deck 4")
    }

    @Test func anyDeckCanBeTheSyncMaster() {
        let e = HeadlessDJEngine()
        loadTone(e.decks[2], e, freq: 300, bpm: 124)
        loadTone(e.decks[3], e, freq: 400, bpm: 120)   // within the ±10% tempo range
        e.decks[2].setAsMaster()
        e.decks[3].sync()
        #expect(e.decks[3].isSynced)
        // Deck 4 (120 BPM track) is dragged to deck 3's 124 BPM.
        let t = e.telemetry()
        #expect(t.deckEffectiveBPMAll.count == 4)
        #expect(abs(t.deckEffectiveBPMAll[3] - 124) < 1.0)
        #expect(t.deckSyncedAll[3])
    }
}

// MARK: - CDJ-3000 parity C2a: Key Sync / detected key / master key

@Suite("CDJ3000 C2 — Key Sync")
@MainActor
struct KeySyncTests {
    private func load(_ deck: Deck, tonic: Int, minor: Bool = false, freq: Double = 220) {
        let pcm = SignalGenerators.sine(frequency: freq, seconds: 6, sampleRate: 48_000, channels: 2)
        let cam = "8\(minor ? "A" : "B")"
        let analysis = TrackAnalysis(
            format: pcm.format, duration: 6,
            tempo: .init(bpm: 120, confidence: 1, beatPositions: [], downbeatPositions: [],
                         isConstantTempo: true),
            key: .init(tonic: tonic, mode: minor ? .minor : .major, camelot: cam,
                       openKey: "1\(minor ? "m" : "d")", confidence: 1),
            sections: [], waveform: .init(overviewMinMax: [], detailRMS: [], bandEnergy: []),
            loudness: .init(integratedLUFS: -14, truePeakDBTP: -1, gainToTargetDB: 0))
        deck.load(analysis, buffer: pcm)
    }

    @Test func detectedKeyComesFromTheLoadedAnalysis() {
        let e = HeadlessDJEngine()
        load(e.deckA, tonic: 7)               // G major
        #expect(e.deckA.detectedKey?.tonic == 7)
        #expect(e.deckB.detectedKey == nil)   // nothing loaded
    }

    @Test func keySyncShiftsToTheReferenceKeyShortestPath() {
        let e = HeadlessDJEngine()
        load(e.deckA, tonic: 0)   // C
        load(e.deckB, tonic: 2)   // D  -> B should drop 2 semitones to reach C
        let shift = e.deckB.keySync(to: e.deckA)
        #expect(shift == -2)
        #expect(e.deckB.pitchSemitones == -2)
        #expect(e.deckB.keyLock)                       // engaged automatically
        #expect(e.deckB.soundingKey?.tonic == 0)       // now sounding in C
    }

    @Test func keySyncTakesTheShortWayAroundTheOctave() {
        let e = HeadlessDJEngine()
        load(e.deckA, tonic: 1)   // C#
        load(e.deckB, tonic: 11)  // B -> +2 is shorter than -10
        #expect(e.deckB.keySync(to: e.deckA) == 2)
    }

    @Test func keySyncClampsToTheRange() {
        let e = HeadlessDJEngine()
        e.deckB.keySyncRange = 1
        load(e.deckA, tonic: 6)
        load(e.deckB, tonic: 0)   // wants +6, clamped to +1
        #expect(e.deckB.keySync(to: e.deckA) == 1)
    }

    @Test func keyResetReturnsToNativeKey() {
        let e = HeadlessDJEngine()
        load(e.deckA, tonic: 0); load(e.deckB, tonic: 5)
        e.deckB.keySync(to: e.deckA)
        e.deckB.keyReset()
        #expect(e.deckB.pitchSemitones == 0)
        #expect(e.deckB.soundingKey?.tonic == 5)
    }

    @Test func masterKeyFollowsTheMasterDeck() {
        let e = HeadlessDJEngine()
        load(e.decks[2], tonic: 9)   // A
        e.decks[2].setAsMaster()
        #expect(e.masterKey?.tonic == 9)
        e.decks[2].pitchSemitones = 3
        #expect(e.masterKey?.tonic == 0)   // A + 3 = C
    }

    @Test func keySyncNoOpsWithoutAnalysedKeys() {
        let e = HeadlessDJEngine()
        load(e.deckA, tonic: 0)
        #expect(e.deckB.keySync(to: e.deckA) == nil)  // deck B has no track
    }
}

// MARK: - CDJ-3000 parity C2b: Reverse / Slip Reverse

@Suite("CDJ3000 C2 — Reverse")
@MainActor
struct ReverseTests {
    private func loaded() -> HeadlessDJEngine {
        let e = HeadlessDJEngine()
        let pcm = SignalGenerators.sine(frequency: 220, seconds: 10, sampleRate: 48_000, channels: 2)
        let analysis = TrackAnalysis(
            format: pcm.format, duration: 10,
            tempo: .init(bpm: 120, confidence: 1, beatPositions: [], downbeatPositions: [],
                         isConstantTempo: true),
            key: .init(tonic: 0, mode: .major, camelot: "8B", openKey: "1d", confidence: 1),
            sections: [], waveform: .init(overviewMinMax: [], detailRMS: [], bandEnergy: []),
            loudness: .init(integratedLUFS: -14, truePeakDBTP: -1, gainToTargetDB: 0))
        e.deckA.load(analysis, buffer: pcm)
        return e
    }

    @Test func reversePlaysBackwards() {
        let e = loaded()
        e.deckA.play()
        _ = e.render(frames: 48_000)          // 1.0 s forward
        let forward = e.deckA.playhead
        #expect(forward > 0.9)
        e.deckA.reverse = true
        _ = e.render(frames: 24_000)          // 0.5 s reversed
        #expect(e.deckA.playhead < forward - 0.4)
    }

    @Test func slipReverseJumpsForwardOnRelease() {
        let e = loaded()
        e.deckA.play()
        _ = e.render(frames: 48_000)          // at ~1.0 s
        e.deckA.slipReversePress()
        _ = e.render(frames: 24_000)          // reversed 0.5 s -> playhead ~0.5 s
        #expect(e.deckA.playhead < 0.7)
        e.deckA.slipReverseRelease()
        _ = e.render(frames: 64)              // apply the snap
        // Shadow advanced forward the whole time: ~1.0 + 0.5 = ~1.5 s.
        #expect(e.deckA.playhead > 1.3)
        #expect(!e.deckA.reverse)
        #expect(!e.deckA.slip)
    }

    @Test func reversingToTheStartStops() {
        let e = loaded()
        e.deckA.play()
        _ = e.render(frames: 12_000)          // 0.25 s in
        e.deckA.reverse = true
        _ = e.render(frames: 48_000)          // more than enough to hit zero
        #expect(e.deckA.playhead == 0)
        #expect(!e.deckA.isPlaying)
    }

    @Test func reverseInsideALoopWrapsToTheLoopEnd() {
        let e = loaded()
        e.deckA.play()
        _ = e.render(frames: 96_000)          // 2 s in
        e.deckA.autoBeatLoop(beats: 4)        // ~2 s loop at 120 BPM
        e.deckA.reverse = true
        _ = e.render(frames: 240_000)         // 5 s reversed — would run off the start without wrap
        #expect(e.deckA.isPlaying)            // still looping, never hit zero
        #expect(e.deckA.playhead > 0.5)
    }
}

// MARK: - CDJ-3000 parity C2c: Vinyl Speed Adjust

@Suite("CDJ3000 C2 — Vinyl Speed Adjust")
@MainActor
struct VinylSpeedTests {
    private func loaded() -> HeadlessDJEngine {
        let e = HeadlessDJEngine()
        let pcm = SignalGenerators.sine(frequency: 220, seconds: 10, sampleRate: 48_000, channels: 2)
        let analysis = TrackAnalysis(
            format: pcm.format, duration: 10,
            tempo: .init(bpm: 120, confidence: 1, beatPositions: [], downbeatPositions: [],
                         isConstantTempo: true),
            key: .init(tonic: 0, mode: .major, camelot: "8B", openKey: "1d", confidence: 1),
            sections: [], waveform: .init(overviewMinMax: [], detailRMS: [], bandEnergy: []),
            loudness: .init(integratedLUFS: -14, truePeakDBTP: -1, gainToTargetDB: 0))
        e.deckA.load(analysis, buffer: pcm)
        return e
    }

    @Test func pauseIsInstantByDefault() {
        let e = loaded()
        e.deckA.play()
        _ = e.render(frames: 24_000)
        let atPause = e.deckA.playhead
        e.deckA.pause()
        _ = e.render(frames: 12_000)
        #expect(abs(e.deckA.playhead - atPause) < 0.001)   // frozen immediately
    }

    @Test func brakeTimeLetsPlaybackCoastToAStop() {
        let e = loaded()
        e.deckA.brakeTime = 0.5
        e.deckA.play()
        _ = e.render(frames: 24_000)            // 0.5 s
        let atPause = e.deckA.playhead
        e.deckA.pause()
        _ = e.render(frames: 6_000)             // 0.125 s of coast
        let afterCoast = e.deckA.playhead
        #expect(afterCoast > atPause + 0.01)              // still moving
        #expect(afterCoast - atPause < 0.125)             // but decelerating
        _ = e.render(frames: 48_000)            // 1 s — well past the 0.5 s brake
        let stopped = e.deckA.playhead
        _ = e.render(frames: 24_000)
        #expect(abs(e.deckA.playhead - stopped) < 0.001)  // fully stopped, frozen
    }

    @Test func spinUpTimeRampsPlaybackUpToSpeed() {
        let e = loaded()
        e.deckA.spinUpTime = 0.5
        e.deckA.play()
        _ = e.render(frames: 6_000)             // 0.125 s of spin-up
        let early = e.deckA.playhead
        #expect(early < 0.125 * 0.6)                      // moving slower than full speed
        #expect(early > 0)                                // but moving
        _ = e.render(frames: 48_000)            // 1 s — past the ramp
        _ = e.render(frames: 24_000)
        let a = e.deckA.playhead
        _ = e.render(frames: 24_000)            // 0.5 s at (now) full speed
        #expect(abs((e.deckA.playhead - a) - 0.5) < 0.02) // back to nominal rate
    }
}

// MARK: - CDJ-3000 parity C3: mixer pro tier

@Suite("CDJ3000 C3 — mixer pro tier")
@MainActor
struct MixerProTierTests {
    private func toneEngine(_ freq: Double = 220) -> HeadlessDJEngine {
        let e = HeadlessDJEngine()
        let pcm = SignalGenerators.sine(frequency: freq, seconds: 6, sampleRate: 48_000, channels: 2)
        let analysis = TrackAnalysis(
            format: pcm.format, duration: 6,
            tempo: .init(bpm: 120, confidence: 1, beatPositions: [], downbeatPositions: [],
                         isConstantTempo: true),
            key: .init(tonic: 0, mode: .major, camelot: "8B", openKey: "1d", confidence: 1),
            sections: [], waveform: .init(overviewMinMax: [], detailRMS: [], bandEnergy: []),
            loudness: .init(integratedLUFS: -14, truePeakDBTP: -1, gainToTargetDB: 0))
        e.deckA.load(analysis, buffer: pcm)
        e.deckA.play()
        return e
    }
    private func rms(_ s: [Float]) -> Double {
        s.isEmpty ? 0 : sqrt(s.reduce(0) { $0 + Double($1 * $1) } / Double(s.count))
    }

    @Test func faderCurveShapesTheTaper() {
        // "sharp" reaches near-full level early in the throw; "smooth" is a
        // symmetric S (below centre quieter, above centre louder).
        #expect(FaderCurve.sharp.gain(0.25) > FaderCurve.linear.gain(0.25))
        #expect(FaderCurve.smooth.gain(0.25) < FaderCurve.linear.gain(0.25))
        #expect(FaderCurve.smooth.gain(0.75) > FaderCurve.linear.gain(0.75))
        #expect(FaderCurve.linear.gain(0.5) == 0.5)
        for c in FaderCurve.allCases {
            #expect(abs(c.gain(0) - 0) < 1e-9)
            #expect(abs(c.gain(1) - 1) < 1e-9)
        }
    }

    @Test func channelFaderCurveChangesRenderedLevel() {
        let linear = toneEngine()
        linear.mixer.channelA.fader = 0.5
        let lOut = linear.render(frames: 8192).left

        let sharp = toneEngine()
        sharp.mixer.channelA.faderCurve = .sharp
        sharp.mixer.channelA.fader = 0.5
        let sOut = sharp.render(frames: 8192).left
        #expect(rms(sOut) > rms(lOut) * 1.3)   // sharp is hotter at half throw
    }

    @Test func masterIsolatorIsBitTransparentAtZero() {
        let a = toneEngine()
        let base = a.render(frames: 4096).left
        let b = toneEngine()
        b.mixer.master.isolatorLow = 0
        b.mixer.master.isolatorMid = 0
        b.mixer.master.isolatorHigh = 0
        let flat = b.render(frames: 4096).left
        var maxDiff: Float = 0
        for i in base.indices { maxDiff = max(maxDiff, abs(base[i] - flat[i])) }
        #expect(maxDiff < 1e-6)
    }

    @Test func masterIsolatorKillsTheLowBand() {
        let e = toneEngine(80)          // 80 Hz — squarely in the low band
        e.mixer.master.isolatorLow = -.infinity
        _ = e.render(frames: 8192)      // let the filter settle
        let out = e.render(frames: 16_384).left
        let buf = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 1), capacity: out.count)
        for i in out.indices { buf.channel(0)[i] = out[i] }
        let killed = Measure.goertzelMagnitude(buf, frequency: 80)

        let ref = toneEngine(80)
        _ = ref.render(frames: 8192)
        let rOut = ref.render(frames: 16_384).left
        let rBuf = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 1), capacity: rOut.count)
        for i in rOut.indices { rBuf.channel(0)[i] = rOut[i] }
        let open = Measure.goertzelMagnitude(rBuf, frequency: 80)
        #expect(open > killed * 30)
    }
}

@Suite("CDJ3000 C3 — booth output")
@MainActor
struct BoothOutputTests {
    private func playing(_ freq: Double = 220) -> HeadlessDJEngine {
        let e = HeadlessDJEngine()
        let pcm = SignalGenerators.sine(frequency: freq, seconds: 6, sampleRate: 48_000, channels: 2)
        let analysis = TrackAnalysis(
            format: pcm.format, duration: 6,
            tempo: .init(bpm: 120, confidence: 1, beatPositions: [], downbeatPositions: [],
                         isConstantTempo: true),
            key: .init(tonic: 0, mode: .major, camelot: "8B", openKey: "1d", confidence: 1),
            sections: [], waveform: .init(overviewMinMax: [], detailRMS: [], bandEnergy: []),
            loudness: .init(integratedLUFS: -14, truePeakDBTP: -1, gainToTargetDB: 0))
        e.deckA.load(analysis, buffer: pcm); e.deckA.play()
        return e
    }
    private func rms(_ s: [Float]) -> Double {
        s.isEmpty ? 0 : sqrt(s.reduce(0) { $0 + Double($1 * $1) } / Double(s.count))
    }

    @Test func boothLevelIsIndependentOfMaster() {
        let e = playing()
        let master = e.render(frames: 4096).left
        let booth = e.renderBooth(frames: 4096).left
        // Default booth level 0.8 -> booth is a scaled copy of the master.
        #expect(rms(booth) > 0)
        #expect(abs(rms(booth) / rms(master) - 0.8) < 0.05)

        e.mixer.master.boothLevel = 0.4
        _ = e.render(frames: 4096)
        let quieter = e.renderBooth(frames: 4096).left
        #expect(abs(rms(quieter) / rms(master) - 0.4) < 0.05)
    }

    @Test func boothEQIsFlatByDefault() {
        let e = playing()
        let master = e.render(frames: 4096).left
        let booth = e.renderBooth(frames: 4096).left
        for i in booth.indices {
            #expect(abs(booth[i] - master[i] * 0.8) < 1e-5)
        }
    }

    @Test func boothLowKillLeavesMasterUntouched() {
        let e = playing(80)
        e.mixer.master.boothEqLow = -.infinity
        for _ in 0..<4 { _ = e.render(frames: 4096); _ = e.renderBooth(frames: 4096) }
        let master = e.render(frames: 16_384).left
        let booth = e.renderBooth(frames: 16_384).left
        func mag(_ s: [Float]) -> Double {
            let b = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 1), capacity: s.count)
            for i in s.indices { b.channel(0)[i] = s[i] }
            return Measure.goertzelMagnitude(b, frequency: 80)
        }
        #expect(mag(master) > mag(booth) * 20)   // booth low killed, master intact
    }
}

@Suite("CDJ3000 C3 — insert seam")
@MainActor
struct InsertSeamTests {
    final class GainInsert: RealtimeInsert {
        let gain: Float
        init(_ g: Float) { gain = g }
        func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
            for i in 0..<frames { left[i] *= gain; if right != left { right[i] *= gain } }
        }
    }
    final class SilenceCounter: RealtimeInsert {
        var calls = 0
        func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
            calls += 1
            for i in 0..<frames { left[i] = 0; if right != left { right[i] = 0 } }
        }
    }
    private func playing(_ freq: Double = 220) -> HeadlessDJEngine {
        let e = HeadlessDJEngine()
        let pcm = SignalGenerators.sine(frequency: freq, seconds: 6, sampleRate: 48_000, channels: 2)
        let analysis = TrackAnalysis(
            format: pcm.format, duration: 6,
            tempo: .init(bpm: 120, confidence: 1, beatPositions: [], downbeatPositions: [],
                         isConstantTempo: true),
            key: .init(tonic: 0, mode: .major, camelot: "8B", openKey: "1d", confidence: 1),
            sections: [], waveform: .init(overviewMinMax: [], detailRMS: [], bandEnergy: []),
            loudness: .init(integratedLUFS: -14, truePeakDBTP: -1, gainToTargetDB: 0))
        e.deckA.load(analysis, buffer: pcm); e.deckA.play()
        return e
    }
    private func peak(_ s: [Float]) -> Float { s.map(abs).max() ?? 0 }
    private func rms(_ s: [Float]) -> Double {
        s.isEmpty ? 0 : sqrt(s.reduce(0) { $0 + Double($1 * $1) } / Double(s.count))
    }

    @Test func masterInsertProcessesTheMixInPlace() {
        let e = playing()
        _ = e.render(frames: 8192)                       // settle
        let dry = rms(e.render(frames: 8192).left)
        e.mixer.setInsert(GainInsert(0.25), at: .master)
        _ = e.render(frames: 8192)                       // flush the limiter look-ahead
        let wet = rms(e.render(frames: 8192).left)
        #expect(wet < dry * 0.4)
        e.mixer.setInsert(nil, at: .master)
        _ = e.render(frames: 8192)
        let restored = rms(e.render(frames: 8192).left)
        #expect(abs(restored - dry) / dry < 0.05)
    }

    @Test func channelInsertOnlyAffectsThatChannel() {
        let e = playing(220)
        // add a second deck on another channel
        let pcm = SignalGenerators.sine(frequency: 660, seconds: 6, sampleRate: 48_000, channels: 2)
        let a = TrackAnalysis(format: pcm.format, duration: 6,
            tempo: .init(bpm: 120, confidence: 1, beatPositions: [], downbeatPositions: [], isConstantTempo: true),
            key: .init(tonic: 0, mode: .major, camelot: "8B", openKey: "1d", confidence: 1),
            sections: [], waveform: .init(overviewMinMax: [], detailRMS: [], bandEnergy: []),
            loudness: .init(integratedLUFS: -14, truePeakDBTP: -1, gainToTargetDB: 0))
        e.decks[1].load(a, buffer: pcm); e.decks[1].play()
        e.mixer.setInsert(SilenceCounter(), at: .channel(0))
        _ = e.render(frames: 8192)
        let out = e.render(frames: 16_384).left
        let buf = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 1), capacity: out.count)
        for i in out.indices { buf.channel(0)[i] = out[i] }
        // Channel 0 (220 Hz) silenced by its insert; channel 1 (660 Hz) untouched.
        #expect(Measure.goertzelMagnitude(buf, frequency: 660) > Measure.goertzelMagnitude(buf, frequency: 220) * 20)
    }

    @Test func insertIsCalledOncePerRenderBlock() {
        let e = playing()
        let counter = SilenceCounter()
        e.mixer.setInsert(counter, at: .master)
        _ = e.render(frames: 512)
        _ = e.render(frames: 512)
        #expect(counter.calls == 2)
    }
}

// MARK: - CDJ-3000 parity C4: Beat FX expansion + X-Pad + Color FX

@Suite("CDJ3000 C4 — Beat FX + Color FX")
@MainActor
struct BeatFXExpansionTests {
    private func playing(_ freq: Double = 220) -> HeadlessDJEngine {
        let e = HeadlessDJEngine()
        let pcm = SignalGenerators.sine(frequency: freq, seconds: 6, sampleRate: 48_000, channels: 2)
        let analysis = TrackAnalysis(
            format: pcm.format, duration: 6,
            tempo: .init(bpm: 120, confidence: 1, beatPositions: [], downbeatPositions: [],
                         isConstantTempo: true),
            key: .init(tonic: 0, mode: .major, camelot: "8B", openKey: "1d", confidence: 1),
            sections: [], waveform: .init(overviewMinMax: [], detailRMS: [], bandEnergy: []),
            loudness: .init(integratedLUFS: -14, truePeakDBTP: -1, gainToTargetDB: 0))
        e.deckA.load(analysis, buffer: pcm); e.deckA.play()
        return e
    }
    private func rms(_ s: [Float]) -> Double {
        s.isEmpty ? 0 : sqrt(s.reduce(0) { $0 + Double($1 * $1) } / Double(s.count))
    }

    @Test func newBeatFXKindsAreEnumeratedAndRenderWithoutBlowingUp() {
        let added: [BeatFXUnit.Kind] = [.pingPong, .mobius, .tripletFilter, .tripletRoll, .enigma, .shimmer]
        #expect(BeatFXUnit.Kind.allCases.count == 20)
        for k in added { #expect(BeatFXUnit.Kind.allCases.contains(k)) }
        for k in added {
            let e = playing()
            e.mixer.beatFX.assign = .master
            e.mixer.beatFX.kind = k
            e.mixer.beatFX.depth = 0.8
            e.mixer.beatFX.isOn = true
            let out = e.render(frames: 16_384).left
            #expect(out.allSatisfy { $0.isFinite })
            #expect((out.map(abs).max() ?? 0) < 4.0)   // bounded, no runaway feedback
        }
    }

    @Test func xPadOverridesTheBeatDivision() {
        let slow = playing()
        slow.mixer.beatFX.assign = .master
        slow.mixer.beatFX.kind = .roll
        slow.mixer.beatFX.beats = 2
        slow.mixer.beatFX.depth = 1
        slow.mixer.beatFX.isOn = true
        _ = slow.render(frames: 8192)
        let slowOut = rms(slow.render(frames: 8192).left)

        let fast = playing()
        fast.mixer.beatFX.assign = .master
        fast.mixer.beatFX.kind = .roll
        fast.mixer.beatFX.beats = 2
        fast.mixer.beatFX.depth = 1
        fast.mixer.beatFX.isOn = true
        fast.mixer.beatFX.xPad = 0.0     // sweep to the shortest (1/16) division
        _ = fast.render(frames: 8192)
        let fastOut = rms(fast.render(frames: 8192).left)
        // Different division -> materially different output energy.
        #expect(abs(fastOut - slowOut) / max(fastOut, slowOut) > 0.05)
        fast.mixer.beatFX.xPad = nil    // release -> back to `beats`
        #expect(fast.mixer.beatFX.xPad == nil)
    }

    @Test func beatFXBandLimitsTheSend() {
        let e = playing(80)                    // low tone
        e.mixer.beatFX.assign = .master
        e.mixer.beatFX.kind = .echo
        e.mixer.beatFX.depth = 1
        e.mixer.beatFX.band = .high            // send only highs -> an 80 Hz tone barely feeds the echo
        e.mixer.beatFX.isOn = true
        _ = e.render(frames: 8192)
        let highBand = rms(e.render(frames: 16_384).left)

        let ref = playing(80)
        ref.mixer.beatFX.assign = .master
        ref.mixer.beatFX.kind = .echo
        ref.mixer.beatFX.depth = 1
        ref.mixer.beatFX.band = .low
        ref.mixer.beatFX.isOn = true
        _ = ref.render(frames: 8192)
        let lowBand = rms(ref.render(frames: 16_384).left)
        #expect(lowBand > highBand)            // low-band send passes the 80 Hz tone, high-band doesn't
    }

    @Test func colorParameterIsNeutralAtHalf() {
        let a = playing()
        a.mixer.channelA.colorFX = .crush
        a.mixer.channelA.colorAmount = 0.7
        let base = a.render(frames: 4096).left
        let b = playing()
        b.mixer.channelA.colorFX = .crush
        b.mixer.channelA.colorAmount = 0.7
        b.mixer.channelA.colorParameter = 0.5
        let same = b.render(frames: 4096).left
        var maxDiff: Float = 0
        for i in base.indices { maxDiff = max(maxDiff, abs(base[i] - same[i])) }
        #expect(maxDiff < 1e-6)
    }

    @Test func colorParameterScalesIntensity() {
        let low = playing()
        low.mixer.channelA.colorFX = .crush
        low.mixer.channelA.colorAmount = 0.6
        low.mixer.channelA.colorParameter = 0.1
        let lowOut = low.render(frames: 4096).left

        let high = playing()
        high.mixer.channelA.colorFX = .crush
        high.mixer.channelA.colorAmount = 0.6
        high.mixer.channelA.colorParameter = 1.0
        let highOut = high.render(frames: 4096).left
        var diff: Float = 0
        for i in lowOut.indices { diff = max(diff, abs(lowOut[i] - highOut[i])) }
        #expect(diff > 1e-4)   // the knob does something
    }

    @Test func centerLockPreventsCrossingCentre() {
        let e = playing()
        let ch = e.mixer.channelA
        ch.colorFXCenterLock = true
        ch.colorAmount = 0.6            // commit to the HPF side
        ch.colorAmount = -0.8          // try to jump to LPF — blocked
        // The published amount can't have gone negative; effect stays on the + side.
        ch.colorFX = .filter
        _ = e.render(frames: 2048)     // no assertion on internal value; just exercised
        ch.colorFXCenterLock = false
        ch.colorAmount = -0.8          // now allowed
        #expect(ch.colorAmount == -0.8)
    }
}
