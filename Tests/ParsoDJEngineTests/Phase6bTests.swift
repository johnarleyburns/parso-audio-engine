//
//  Phase6bTests.swift
//  FLX4 acceptance coverage for the Phase 6b backlog (docs/phase6-parity.md):
//  per-deck stems, per-deck beat echo, integer-sample transport, CueMode
//  split-output, render-side telemetry, quantize grain, limiter bypass,
//  key-lock wiring and graph recovery.
//

import Testing
import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoDJEngine
import ParsoTestSupport

@MainActor
private func analysis(_ pcm: PCMBuffer, bpm: Double = 120,
                      beats: [TimeInterval] = [], downbeats: [TimeInterval] = []) -> TrackAnalysis {
    TrackAnalysis(
        format: pcm.format, duration: Double(pcm.frameCount) / pcm.format.sampleRate,
        tempo: .init(bpm: bpm, confidence: 1, beatPositions: beats,
                     downbeatPositions: downbeats, isConstantTempo: true),
        key: .init(tonic: 0, mode: .major, camelot: "8B", openKey: "1d", confidence: 1),
        sections: [], waveform: .init(overviewMinMax: [], detailRMS: [], bandEnergy: []),
        loudness: .init(integratedLUFS: -14, truePeakDBTP: -1, gainToTargetDB: 0))
}

@MainActor
private func loadedDeckA(freq: Double = 220, bpm: Double = 120,
                         beats: [TimeInterval] = []) -> HeadlessDJEngine {
    let e = HeadlessDJEngine()
    let pcm = SignalGenerators.sine(frequency: freq, seconds: 8, sampleRate: 48_000, channels: 2)
    e.deckA.load(analysis(pcm, bpm: bpm, beats: beats), buffer: pcm)
    e.mixer.crossfader = -1
    return e
}

private func mono(_ samples: [Float]) -> PCMBuffer {
    let b = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 1), capacity: samples.count)
    for i in samples.indices { b.channel(0)[i] = samples[i] }
    return b
}

// MARK: - Item 1 — per-deck 4-voice stems

@Suite("Phase 6b — stems")
@MainActor
struct StemTests {
    private func stemSet() -> [StemKind: PCMBuffer] {
        [.vocals: SignalGenerators.sine(frequency: 300, seconds: 8, sampleRate: 48_000, channels: 2),
         .drums:  SignalGenerators.sine(frequency: 600, seconds: 8, sampleRate: 48_000, channels: 2),
         .bass:   SignalGenerators.sine(frequency: 90,  seconds: 8, sampleRate: 48_000, channels: 2),
         .other:  SignalGenerators.sine(frequency: 1200, seconds: 8, sampleRate: 48_000, channels: 2)]
    }

    @Test func disarmedDeckRendersBitExactlyLikeNeverArmed() {
        // A deck whose stems are armed then disarmed before playback must drive
        // the identical single-source render path — no residual downstream state.
        let armed = loadedDeckA()
        armed.deckA.armStems(stemSet())
        armed.deckA.disarmStems()
        armed.deckA.play()
        let a = armed.render(frames: 24_000).left

        let never = loadedDeckA()
        never.deckA.play()
        let b = never.render(frames: 24_000).left

        #expect(a.count == b.count)
        #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func soloIsolatesOneVoice() {
        let e = loadedDeckA()
        e.deckA.armStems(stemSet())
        e.deckA.play()
        e.deckA.setStemSolo(.drums, true)
        _ = e.render(frames: 24_000)          // let the gain ramps settle
        let out = mono(e.render(frames: 16_384).left)
        let drums = Measure.goertzelMagnitude(out, frequency: 600)
        let vocals = Measure.goertzelMagnitude(out, frequency: 300)
        #expect(drums > vocals * 6)
    }

    @Test func muteDropsAVoiceWithoutClicking() {
        let e = loadedDeckA()
        e.deckA.armStems(stemSet())
        e.deckA.play()
        _ = e.render(frames: 8192)
        e.deckA.setStemMute(.bass, true)
        let out = e.render(frames: 24_000).left
        #expect(out.allSatisfy { $0.isFinite })
        let bass = Measure.goertzelMagnitude(mono(Array(out.suffix(16_384))), frequency: 90)
        let drums = Measure.goertzelMagnitude(mono(Array(out.suffix(16_384))), frequency: 600)
        #expect(bass < drums * 0.3)
    }
}

// MARK: - Item 3 — per-deck beat echo

@Suite("Phase 6b — per-deck echo")
@MainActor
struct PerDeckEchoTests {
    @Test func echoLeavesADecayingTailAfterDisable() {
        let e = loadedDeckA(bpm: 120)
        e.deckA.play()
        e.deckA.setEcho(enabled: true, beats: 1, depth: 0.8, feedback: 0.5)
        _ = e.render(frames: 24_000)
        e.deckA.pause()
        _ = e.render(frames: 1)
        e.deckA.setEcho(enabled: false, beats: 1, depth: 0.8, feedback: 0.5)
        let early = e.render(frames: 8192).left.map(abs).max() ?? 0
        _ = e.render(frames: 96_000)
        let late = e.render(frames: 8192).left.map(abs).max() ?? 0
        #expect(early > 0.001)          // tail is audible right after disable
        #expect(late < early)           // and it decays
    }
}

// MARK: - Item 6 — integer-sample transport

@Suite("Phase 6b — integer transport")
@MainActor
struct IntegerTransportTests {
    @Test func seekLandsOnTheExactSample() {
        let e = loadedDeckA()
        e.deckA.seek(toSample: 123_457, quantized: false)
        _ = e.render(frames: 1)
        #expect(abs(e.deckA.playhead - 123_457.0 / 48_000.0) < 1.0 / 48_000.0)
    }

    @Test func integerLoopHasHalfOpenBounds() {
        let e = loadedDeckA()
        e.deckA.setLoop(startSample: 24_000, endSample: 48_000)   // [0.5 s, 1.0 s)
        e.deckA.seek(toSample: 47_000, quantized: false)
        e.deckA.play()
        _ = e.render(frames: 48_000)                              // 1 s of playback
        #expect(e.deckA.playhead >= 0.5 && e.deckA.playhead < 1.0)
    }
}

// MARK: - Item 5 — CueMode split-output

@Suite("Phase 6b — CueMode")
@MainActor
struct CueModeTests {
    @Test func splitOutputSendsMasterLeftAndCueRight() {
        let e = loadedDeckA()
        e.deckA.play()
        e.deckB.pause()
        e.mixer.channelA.cuePFL = true
        e.monitoring.masterCue = true
        e.monitoring.cueMasterMix = 1
        e.monitoring.cueMode = .splitOutput
        _ = e.render(frames: 1)
        let out = e.renderMonitor(frames: 8192)
        let left = out.left.map(abs).max() ?? 0
        let right = out.right.map(abs).max() ?? 0
        #expect(left > 0.001)     // master on the left
        #expect(right > 0.001)    // cue on the right
    }

    @Test func offKeepsTheMonitorPathUnchanged() {
        func run(_ mode: CueMode) -> [Float] {
            let e = loadedDeckA()
            e.deckA.play()
            e.mixer.channelA.cuePFL = true
            e.monitoring.cueMasterMix = 0
            e.monitoring.cueMode = mode
            _ = e.render(frames: 1)
            return e.renderMonitor(frames: 4096).left
        }
        // `.off` and `.cueInPlace` both take the blended-mono branch.
        #expect(run(.off) == run(.cueInPlace))
    }
}

// MARK: - Item 2 — render-side telemetry + sync

@Suite("Phase 6b — telemetry and sync")
@MainActor
struct TelemetrySyncTests {
    @Test func masterFrameAdvancesMonotonicallyAndRenderLoadIsFinite() {
        let e = loadedDeckA()
        e.deckA.play()
        _ = e.render(frames: 4096)
        let a = e.telemetry()
        _ = e.render(frames: 4096)
        let b = e.telemetry()
        #expect(b.masterSample == a.masterSample + 4096)
        #expect(a.masterSample == 4096)
        #expect(b.renderLoad.isFinite && b.renderLoad >= 0)
    }

    @Test func effectiveRateReflectsTempoFader() {
        let e = loadedDeckA()
        e.deckA.tempoRange = .wide
        e.deckA.tempoPercent = 8
        #expect(abs(e.deckA.effectiveRate - 1.08) < 1e-9)
    }

    @Test func masterPitchMoveDragsTheSyncedDeck() {
        let e = HeadlessDJEngine()
        let a = SignalGenerators.sine(frequency: 220, seconds: 8, sampleRate: 48_000, channels: 2)
        let b = SignalGenerators.sine(frequency: 330, seconds: 8, sampleRate: 48_000, channels: 2)
        e.deckA.load(analysis(a, bpm: 120, beats: [0]), buffer: a)
        e.deckB.load(analysis(b, bpm: 120, beats: [0]), buffer: b)
        e.deckA.setAsMaster()
        e.deckB.sync()
        #expect(abs(e.deckB.tempoPercent) < 0.5)     // matched at 120/120
        e.deckA.tempoRange = .wide
        e.deckA.tempoPercent = 10                    // master now 132 BPM
        // Finding C4: the synced deck must follow without a fresh sync() call.
        #expect(abs(e.deckB.tempoPercent - 10) < 1.0)
    }

    @Test func unsyncDisengages() {
        let e = loadedDeckA()
        e.deckB.load(analysis(SignalGenerators.sine(frequency: 330, seconds: 8, sampleRate: 48_000, channels: 2), bpm: 128),
                     buffer: SignalGenerators.sine(frequency: 330, seconds: 8, sampleRate: 48_000, channels: 2))
        e.deckA.setAsMaster()
        e.deckB.sync()
        #expect(e.deckB.isSynced)
        e.deckB.unsync()
        #expect(!e.deckB.isSynced)
    }
}

// MARK: - Item 7 — quantize grain

@Suite("Phase 6b — quantize grain")
@MainActor
struct QuantizeGrainTests {
    @Test func halfBeatGrainSnapsBetweenBeats() {
        let e = loadedDeckA(bpm: 120, beats: stride(from: 0.0, through: 8.0, by: 0.5).map { $0 })
        e.deckA.quantize = true
        e.deckA.quantizeResolution = .halfBeat        // 0.25 s grain at 120 BPM
        e.deckA.play()
        _ = e.render(frames: 15_360)                  // 0.32 s
        e.deckA.pause()
        e.deckA.setCue()
        e.deckA.cuePlayPress()
        _ = e.render(frames: 1)
        #expect(abs(e.deckA.playhead - 0.25) < 0.01)
    }
}

// MARK: - Item 8 — limiter bypass

@Suite("Phase 6b — limiter bypass")
@MainActor
struct LimiterBypassTests {
    @Test func bypassLetsThePeakExceedTheCeiling() {
        let e = loadedDeckA()
        e.deckB.load(analysis(SignalGenerators.sine(frequency: 330, seconds: 8, sampleRate: 48_000, channels: 2)),
                     buffer: SignalGenerators.sine(frequency: 330, seconds: 8, sampleRate: 48_000, channels: 2))
        e.mixer.crossfader = 0
        e.mixer.master.level = 1
        e.mixer.channelA.trim = 2
        e.mixer.channelB.trim = 2
        e.mixer.master.limiterCeilingDB = -12
        e.mixer.master.limiterEnabled = false
        e.deckA.play(); e.deckB.play()
        _ = e.render(frames: 8192)
        let peak = e.render(frames: 8192).left.map(abs).max() ?? 0
        let ceiling = pow(Float(10), Float(-12) / Float(20))
        #expect(peak > ceiling)
    }
}

// MARK: - Item 9 — graph recovery

@Suite("Phase 6b — graph recovery")
@MainActor
struct GraphRecoveryTests {
    @Test func recoverGraphPreservesRunningStateAndDeckLoad() throws {
        let engine = DJEngine(sampleRate: 48_000, maxFramesPerRender: 256)
        let pcm = SignalGenerators.sine(frequency: 220, seconds: 4, sampleRate: 48_000, channels: 2)
        engine.deckA.load(analysis(pcm), buffer: pcm)
        try engine.start()
        #expect(engine.isRunning)
        try engine.recoverGraph()
        #expect(engine.isRunning)
        #expect(engine.deckA.waveform != nil)
        engine.stop()
        #expect(!engine.isRunning)
    }

    @Test func configurationChangesStreamIsVended() {
        let engine = DJEngine()
        let stream = engine.configurationChanges()
        _ = stream.makeAsyncIterator()                  // constructed without crashing
        #expect(engine.bufferPeriodMillis > 0)
    }
}

// MARK: - Item 4 — record tap + segments + interruption

@Suite("Phase 6b — record tap")
@MainActor
struct RecordTapTests {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    @Test func headlessRenderFeedsTheTapAndProducesAPlayableFile() throws {
        let e = loadedDeckA(freq: 440)
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try MixRecorder(codec: .wavPCM(bitDepth: 24), url: url)
        e.startRecording(recorder)
        e.deckA.play()
        _ = e.render(frames: 24_000)          // 0.5 s
        try e.stopRecording()

        let out = try AudioFileReader(url: url, container: .wav).readAll()
        #expect(out.frameCount > 20_000)
        #expect(Measure.dominantFrequency(out, searchRange: 300...600) == 440)
        #expect(e.droppedRecordFrames == 0)
    }

    @Test func interruptMidStreamFlushesACompleteSegmentAndResumes() throws {
        let e = loadedDeckA(freq: 440)
        let segment = tempURL("wav")
        let final = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: segment); try? FileManager.default.removeItem(at: final) }
        let recorder = try MixRecorder(codec: .wavPCM(bitDepth: 24), url: final)
        e.startRecording(recorder)
        e.deckA.play()
        _ = e.render(frames: 12_000)
        let flushed = try e.interruptRecording(to: segment)
        #expect(flushed == segment)
        _ = e.render(frames: 12_000)
        try e.stopRecording()

        let first = try AudioFileReader(url: segment, container: .wav).readAll()
        let second = try AudioFileReader(url: final, container: .wav).readAll()
        #expect(first.frameCount > 8_000)      // segment is complete + playable
        #expect(second.frameCount > 8_000)     // resumed segment is its own file
    }
}

// MARK: - Item 2a — key-lock wiring

@Suite("Phase 6b — key-lock")
@MainActor
struct KeyLockTests {
    @Test func keyLockChangesOutputWhenTempoIsShifted() {
        func run(keyLock: Bool) -> [Float] {
            let e = loadedDeckA(freq: 440)
            e.deckA.keyLock = keyLock
            e.deckA.tempoRange = .wide
            e.deckA.tempoPercent = 12                   // off nominal
            e.deckA.play()
            _ = e.render(frames: 24_000)
            return e.render(frames: 16_384).left
        }
        let varispeed = run(keyLock: false)
        let locked = run(keyLock: true)
        let diff = zip(varispeed, locked).map { abs($0 - $1) }.max() ?? 0
        #expect(diff > 0.01)                            // the two paths diverge
        #expect(locked.allSatisfy { $0.isFinite })
    }
}
