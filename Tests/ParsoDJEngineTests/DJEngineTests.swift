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
