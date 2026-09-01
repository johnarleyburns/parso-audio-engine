//
//  ParsoDJEngine.swift
//  DDJ-FLX4-equivalent DJ orchestration over CParsoEngine + Core + Analysis.
//  Control objects are @MainActor; the real-time DSP runs in CParsoEngine.
//
//  STATUS: SCAFFOLD. Implement per docs/SPEC.md §11 and make
//  Tests/ParsoDJEngineTests pass (headless/offline render).
//

import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import CParsoEngine

@inline(never)
func unimplemented(_ fn: StaticString = #function, file: StaticString = #file, line: UInt = #line) -> Never {
    fatalError("unimplemented: \(fn) — implement per docs/SPEC.md §11", file: file, line: line)
}

// MARK: - Top-level engine

/// The complete two-deck software DJ engine. Owns two `Deck`s, a `Mixer`, a
/// `Sampler`, a `MicInput`, and `Monitoring`. Install with `start()`.
@MainActor
public final class DJEngine {
    public let deckA: Deck
    public let deckB: Deck
    public let mixer: Mixer
    public let sampler: Sampler
    public let mic: MicInput
    public let monitoring: Monitoring

    public init(sampleRate: Double = 48_000, maxFramesPerRender: Int = 512) { unimplemented() }

    /// Installs the AVAudioSourceNode render block that calls `pe_render`.
    public func start() throws { unimplemented() }
    public func stop() { unimplemented() }

    /// A device-free, synchronous engine for deterministic tests (calls `pe_step`).
    public func makeHeadless() -> HeadlessDJEngine { unimplemented() }
}

@MainActor
fileprivate final class EngineBridge {
    private let handleBits: UInt
    var control: pe_control
    private(set) var masterDeckIndex: Int?
    private var trackBPM: [Double] = [120, 120]
    weak var deckA: Deck?
    weak var deckB: Deck?
    weak var sampler: Sampler?

    var handle: OpaquePointer {
        // The C handle is owned and used exclusively on the main/control actor.
        OpaquePointer(bitPattern: handleBits)!
    }

    init(sampleRate: Double, maxFrames: Int) {
        guard let handle = pe_create(sampleRate, Int32(maxFrames)) else {
            fatalError("CParsoEngine could not be created")
        }
        self.handleBits = UInt(bitPattern: handle)
        var control = pe_control()
        control.crossfader = 0
        control.xfade_curve = 0
        control.master_level = 0.8
        control.trim = (0.5, 0.5)
        control.fader = (1, 1)
        control.deck_time_ratio = (1, 1)
        control.deck_pitch = (0, 0)
        self.control = control
        pe_set_control(handle, &self.control)
    }

    deinit { pe_destroy(OpaquePointer(bitPattern: handleBits)) }

    func publishControl() { pe_set_control(handle, &control) }

    func register(_ deck: Deck, index: Int) {
        if index == 0 { deckA = deck } else if index == 1 { deckB = deck }
    }

    func register(_ sampler: Sampler) { self.sampler = sampler }

    func setTrackBPM(_ bpm: Double, index: Int) {
        guard trackBPM.indices.contains(index), bpm.isFinite, bpm > 0 else { return }
        trackBPM[index] = bpm
    }

    func bpm(for index: Int) -> Double {
        trackBPM.indices.contains(index) ? trackBPM[index] : 120
    }

    func deck(at index: Int) -> Deck? {
        index == 0 ? deckA : (index == 1 ? deckB : nil)
    }

    func setMaster(index: Int) {
        guard index == 0 || index == 1 else { return }
        masterDeckIndex = index
        deckA?.refreshSyncFromMasterIfNeeded()
        deckB?.refreshSyncFromMasterIfNeeded()
    }

    func setDeckPlayback(index: Int, tempoRatio: Double, pitchSemitones: Double) {
        let ratio = tempoRatio.isFinite && tempoRatio > 0 ? tempoRatio : 1
        let pitch = pitchSemitones.isFinite ? pitchSemitones : 0
        if index == 0 {
            control.deck_time_ratio.0 = Float(ratio)
            control.deck_pitch.0 = Float(pitch)
        } else if index == 1 {
            control.deck_time_ratio.1 = Float(ratio)
            control.deck_pitch.1 = Float(pitch)
        } else {
            return
        }
        publishControl()
    }
}

/// Synchronous render harness for tests. Same DSP as `DJEngine`, no audio device.
@MainActor
public final class HeadlessDJEngine {
    public let deckA: Deck
    public let deckB: Deck
    public let mixer: Mixer
    public let sampler: Sampler
    private let bridge: EngineBridge

    public init(sampleRate: Double = 48_000, maxFramesPerRender: Int = 512) {
        bridge = EngineBridge(sampleRate: sampleRate, maxFrames: maxFramesPerRender)
        deckA = Deck(bridge: bridge, index: 0)
        deckB = Deck(bridge: bridge, index: 1)
        mixer = Mixer(bridge: bridge)
        sampler = Sampler(bridge: bridge)
    }
    /// Advance `frames` and return non-interleaved stereo master output.
    public func render(frames: Int) -> (left: [Float], right: [Float]) {
        let count = max(0, frames)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                pe_step(bridge.handle, leftPointer.baseAddress, rightPointer.baseAddress, Int32(count))
            }
        }
        drainEvents()
        return (left, right)
    }
    /// Advance the monitor/headphone bus.
    public func renderMonitor(frames: Int) -> (left: [Float], right: [Float]) {
        let count = max(0, frames)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                pe_render_monitor(bridge.handle, leftPointer.baseAddress, rightPointer.baseAddress, Int32(count))
            }
        }
        drainEvents()
        return (left, right)
    }

    private func drainEvents() {
        var events = [pe_event](repeating: pe_event(type: PE_EVT_PLAYHEAD, deck: -1, frame: 0, f0: 0, f1: 0), count: 64)
        while true {
            let count = events.withUnsafeMutableBufferPointer { pointer in
                pe_poll_events(bridge.handle, pointer.baseAddress, Int32(pointer.count))
            }
            if count == 0 { return }
            for event in events.prefix(Int(count)) {
                switch event.type {
                case PE_EVT_PLAYHEAD, PE_EVT_STATE:
                    if event.deck == 0 { deckA.apply(event) }
                    if event.deck == 1 { deckB.apply(event) }
                case PE_EVT_END_OF_TRACK:
                    if event.deck == 0 { deckA.applyEndOfTrack(event) }
                    if event.deck == 1 { deckB.applyEndOfTrack(event) }
                default:
                    break
                }
            }
        }
    }
}

// MARK: - Deck (mirror ×2)

public enum PadMode: Sendable {
    case hotCue        // 8 cues
    case keyboard      // pitch-play a selected hot cue chromatically
    case padFX1        // bank 1 assignable effects
    case padFX2        // bank 2 assignable effects
    case beatJump      // jump by beats; halve/double
    case beatLoop      // instant fixed-length loops
    case sampler       // trigger 16 sampler slots
    case keyShift      // shift playing-track key ± semitones
}

@MainActor
public final class Deck {
    private let bridge: EngineBridge
    private let index: Int
    private var buffer: PCMBuffer?
    private var currentPlayhead: TimeInterval = 0
    private var shadowPlayhead: TimeInterval = 0
    private var hotCueTimes: [TimeInterval?] = Array(repeating: nil, count: 8)
    private var trackBPM: Double = 120
    private var beatPositions: [TimeInterval] = []

    fileprivate init(bridge: EngineBridge, index: Int) {
        self.bridge = bridge
        self.index = index
        bridge.register(self, index: index)
    }

    fileprivate var channelIndex: Int { index }

    // Loading / transport
    public func load(_ analysis: TrackAnalysis, buffer: PCMBuffer) {
        self.buffer = buffer
        currentPlayhead = 0
        shadowPlayhead = 0
        hotCueTimes = Array(repeating: nil, count: 8)
        trackBPM = analysis.tempo.bpm > 0 ? analysis.tempo.bpm : 120
        beatPositions = analysis.tempo.beatPositions
        bridge.setTrackBPM(trackBPM, index: index)
        updatePlaybackRate()
        buffer.withUnsafeChannels { channels, frames in
            channels.withMemoryRebound(to: UnsafePointer<Float>?.self, capacity: buffer.channelCount) { pointers in
                pe_deck_set_buffer(
                    bridge.handle,
                    Int32(index),
                    UnsafePointer(pointers),
                    Int32(buffer.channelCount),
                    Int64(frames),
                    buffer.format.sampleRate
                )
            }
        }
    }

    public func play() {
        post(PE_CMD_PLAY)
        isPlaying = true
    }

    public func pause() {
        post(PE_CMD_PAUSE)
        isPlaying = false
    }

    public private(set) var isPlaying: Bool = false
    /// Latest playhead in seconds (updated from the RT event stream).
    public var playhead: TimeInterval { currentPlayhead }

    fileprivate func apply(_ event: pe_event) {
        guard event.deck == index else { return }
        if event.type == PE_EVT_PLAYHEAD || event.type == PE_EVT_STATE {
            currentPlayhead = TimeInterval(event.frame) / (buffer?.format.sampleRate ?? 1)
        }
        if event.type == PE_EVT_PLAYHEAD {
            shadowPlayhead = TimeInterval(event.f1) / (buffer?.format.sampleRate ?? 1)
        }
        if event.type == PE_EVT_STATE {
            isPlaying = event.f0 > 0.5
        }
    }

    fileprivate func applyEndOfTrack(_ event: pe_event) {
        guard event.deck == index else { return }
        currentPlayhead = TimeInterval(event.frame) / (buffer?.format.sampleRate ?? 1)
        isPlaying = false
    }

    private func post(_ type: pe_cmd_type, i0: Int = 0, f0: Float = 0, f1: Float = 0) {
        var command = pe_command(type: type, deck: Int32(index), i0: Int32(i0), i1: 0, i2: 0, f0: f0, f1: f1)
        _ = pe_post_command(bridge.handle, &command)
    }

    // Temporary cue
    public func setCue() { unimplemented() }
    public func jumpToCue() { unimplemented() }
    public func cuePlayPress() { unimplemented() }   // preview from cue while held
    public func cuePlayRelease() { unimplemented() }

    // Tempo / pitch
    public enum TempoRange: Sendable { case p6, p10, p16, wide }
    public var tempoRange: TempoRange = .p10 { didSet { updatePlaybackRate() } }
    /// Fader position in percent within `tempoRange` (e.g. −16.0 … +16.0).
    public var tempoPercent: Double = 0 { didSet { updatePlaybackRate() } }
    /// `true` keeps pitch constant while tempo changes (key-lock beatmatch).
    public var keyLock: Bool = true {
        didSet {
            post(PE_CMD_SET_KEYLOCK, f0: keyLock ? 1 : 0)
            updatePlaybackRate()
        }
    }
    /// Independent key change (Key Shift), in semitones.
    public var pitchSemitones: Double = 0 { didSet { updatePlaybackRate() } }

    /// `true` when this deck is following the current master deck's tempo.
    public private(set) var isSynced: Bool = false

    /// `true` when this deck is the engine's current tempo master.
    public var isMaster: Bool { bridge.masterDeckIndex == index }

    private var tempoLimit: Double {
        switch tempoRange {
        case .p6: return 6
        case .p10: return 10
        case .p16: return 16
        case .wide: return 100
        }
    }

    private var playbackRatio: Double {
        let percent = max(-tempoLimit, min(tempoLimit, tempoPercent))
        return max(0.01, 1 + percent / 100)
    }

    private func updatePlaybackRate() {
        bridge.setDeckPlayback(index: index, tempoRatio: playbackRatio, pitchSemitones: pitchSemitones)
    }

    // Jog / scratch (engages varispeed transiently)
    public var vinylMode: Bool = true
    public func jogTouchBegan() { unimplemented() }
    public func jogMoved(deltaSamples: Double) { unimplemented() }
    public func jogTouchEnded() { unimplemented() }
    public func nudge(_ amount: Double) { unimplemented() }   // pitch bend

    // Hot cues (8)
    public func setHotCue(_ index: Int) {
        guard hotCueTimes.indices.contains(index) else { return }
        hotCueTimes[index] = currentPlayhead
        post(PE_CMD_HOTCUE_SET, i0: index)
    }
    public func jumpHotCue(_ index: Int) {
        guard hotCueTimes.indices.contains(index), let time = hotCueTimes[index] else { return }
        currentPlayhead = time
        post(PE_CMD_HOTCUE_JUMP, i0: index)
    }
    public func deleteHotCue(_ index: Int) {
        guard hotCueTimes.indices.contains(index) else { return }
        hotCueTimes[index] = nil
        post(PE_CMD_HOTCUE_DELETE, i0: index)
    }

    // Loops
    public func loopIn() { post(PE_CMD_LOOP_IN) }
    public func loopOut() { post(PE_CMD_LOOP_OUT) }
    public func reloopExit() {
        if slip { currentPlayhead = shadowPlayhead }
        post(PE_CMD_RELOOP_EXIT)
    }
    public func autoBeatLoop(beats: Double) {
        guard beats > 0, trackBPM > 0 else { return }
        post(PE_CMD_BEATLOOP, f0: Float(beats * 60 / trackBPM))
    }
    public func loopHalve() { post(PE_CMD_LOOP_SCALE, f0: 0.5) }
    public func loopDouble() { post(PE_CMD_LOOP_SCALE, f0: 2) }
    public func loopMove(beats: Double) {
        guard trackBPM > 0 else { return }
        post(PE_CMD_LOOP_MOVE, f0: Float(beats * 60 / trackBPM))
    }
    public func saveLoop(_ slot: Int) { unimplemented() }
    public func callLoop(_ slot: Int) { unimplemented() }
    public func setActiveLoop(_ enabled: Bool) { unimplemented() }

    // Sync
    public func sync() {
        let masterIndex = bridge.masterDeckIndex ?? (index == 0 ? 1 : 0)
        guard masterIndex != index else { return }
        if bridge.masterDeckIndex == nil { bridge.setMaster(index: masterIndex) }
        isSynced = true
        refreshSyncFromMasterIfNeeded()
    }

    public func setAsMaster() {
        isSynced = false
        bridge.setMaster(index: index)
        post(PE_CMD_SET_MASTER)
        updatePlaybackRate()
    }

    fileprivate func refreshSyncFromMasterIfNeeded() {
        guard isSynced, let masterIndex = bridge.masterDeckIndex, masterIndex != index else { return }
        let master = bridge.deck(at: masterIndex)
        let masterBPM = master?.effectiveBPM ?? bridge.bpm(for: masterIndex)
        guard masterBPM.isFinite, masterBPM > 0, trackBPM > 0 else { return }

        let ratio = masterBPM / trackBPM
        tempoPercent = (ratio - 1) * 100
        updatePlaybackRate()

        let target = syncTargetPosition(master: master, masterBPM: masterBPM)
        post(PE_CMD_SYNC, f0: Float(target))
    }

    private var effectiveBPM: Double { trackBPM * playbackRatio }

    private func syncTargetPosition(master: Deck?, masterBPM: Double) -> TimeInterval {
        guard let master else { return 0 }
        let masterPeriod = 60 / masterBPM
        let targetPeriod = 60 / trackBPM
        let trackDuration = buffer.map { Double($0.frameCount) / $0.format.sampleRate } ?? .greatestFiniteMagnitude
        guard masterPeriod.isFinite, targetPeriod.isFinite, masterPeriod > 0 else { return 0 }

        if let masterBeat = master.beatPositions.first, !beatPositions.isEmpty {
            let beatNumber = max(0, (master.currentPlayhead - masterBeat) / masterPeriod)
            let target = beatPositions[0] + beatNumber * targetPeriod
            return max(0, min(trackDuration, target))
        }

        // Tracks without a beat grid still start on beat zero. Preserve the
        // current musical beat count while accounting for the source BPM.
        let target = max(0, master.currentPlayhead * masterBPM / trackBPM)
        return max(0, min(trackDuration, target))
    }
    public var quantize: Bool = true
    public var slip: Bool = false {
        didSet { post(PE_CMD_SET_SLIP, f0: slip ? 1 : 0) }
    }

    // Performance pads
    public var padMode: PadMode = .hotCue
    /// For `.keyboard` mode: which hot cue is pitched across the pads.
    public var keyboardCueIndex: Int = 0
    public func padPress(_ index: Int) {
        guard (0..<8).contains(index) else { return }
        switch padMode {
        case .hotCue:
            jumpHotCue(index)
        case .keyboard:
            pitchSemitones = Double(index - 4)
        case .padFX1, .padFX2:
            break
        case .beatJump:
            let seconds = trackBPM > 0 ? Double(index - 3) * beatJumpSize * 60 / trackBPM : 0
            post(PE_CMD_BEATJUMP, f0: Float(seconds))
        case .beatLoop:
            let sizes = [1.0, 2, 4, 8, 16, 32, 64, 0.5]
            autoBeatLoop(beats: sizes[index])
        case .sampler:
            bridge.sampler?.trigger(index)
        case .keyShift:
            pitchSemitones = Double(index - 3)
        }
    }

    public func padRelease(_ index: Int) {
        guard (0..<8).contains(index) else { return }
        if padMode == .keyboard { pitchSemitones = 0 }
    }
    /// Assign an effect to a Pad-FX pad (bank 1 or 2).
    public func assignPadFX(bank: Int, pad: Int, effect: BeatFXUnit.Kind, hold: Bool) { unimplemented() }
    /// Beat-jump size for `.beatJump` mode.
    public var beatJumpSize: Double = 4

}

// MARK: - Mixer / channels / FX

@MainActor
public final class Mixer {
    public let channelA: Channel
    public let channelB: Channel
    public let master: MasterOut
    public let beatFX: BeatFXUnit
    public let smartFader: SmartFader
    public let smartCFX: SmartCFX

    private let bridge: EngineBridge

    public var crossfader: Double = 0 { didSet { publishControl() } } // -1..+1
    public enum Curve: Sendable { case smooth, linear, sharp }
    public var crossfaderCurve: Curve = .smooth { didSet { publishControl() } }

    fileprivate init(bridge: EngineBridge) {
        self.bridge = bridge
        channelA = Channel()
        channelB = Channel()
        master = MasterOut()
        beatFX = BeatFXUnit()
        smartFader = SmartFader()
        smartCFX = SmartCFX()
        smartFader.attach(to: self)
    }

    private func publishControl() {
        bridge.control.crossfader = Float(max(-1, min(1, crossfader)))
        bridge.control.xfade_curve = crossfaderCurve == .smooth ? 0 : (crossfaderCurve == .linear ? 0.5 : 1)
        bridge.publishControl()
    }
}

public enum ColorFX: Sendable { case filter, space, dubEcho, sweep, noise, crush, pitch }

public enum XFAssign: Sendable { case a, b, thru }

@MainActor
public final class Channel {
    public var trim: Double = 0.5                     // gain
    public var eqLow: Double = 0                      // dB, -inf(kill)..+6
    public var eqMid: Double = 0
    public var eqHigh: Double = 0
    public var colorFX: ColorFX = .filter
    public var colorAmount: Double = 0                // -1..+1 (center = off)
    public var fader: Double = 1                      // 0..1
    public var cuePFL: Bool = false                   // headphone pre-listen
    public var faderStart: Bool = false
    public var crossfaderAssign: XFAssign = .thru
    /// Latest peak meter (0..1), updated from the RT event stream.
    public var peakMeter: Float { unimplemented() }
    internal init() {}
}

@MainActor
public final class BeatFXUnit {
    public enum Kind: Sendable, CaseIterable {
        case echo, echoOut, reverb, delay, multiTapDelay, flanger, phaser,
             trans, roll, spiral, pitch, lowCutEcho, vinylBrake, helix
    }
    public enum Assign: Sendable { case chA, chB, both, master }
    public var kind: Kind = .echo
    public var beats: Double = 0.5                    // time division
    public var depth: Double = 0.5                    // wet/level
    public var assign: Assign = .chA
    public var isOn: Bool = false
    public func releaseFX() { unimplemented() }       // tail on release
    internal init() {}
}

@MainActor
public final class MasterOut {
    public var level: Double = 0.8
    public var masterCue: Bool = false
    /// Limiter ceiling in dBTP (default −0.3).
    public var limiterCeilingDB: Double = -0.3
    /// Latest master peak (0..1).
    public var peakMeter: Float { unimplemented() }
    internal init() {}
}

// MARK: - Smart features

@MainActor
public final class SmartFader {
    public enum Tail: Sendable { case echo, reverb }
    private weak var mixer: Mixer?
    public var isEnabled: Bool = false
    public var tail: Tail = .echo
    /// Optional: call once to run an automated transition (§11.5). Normally the
    /// engine reacts to fader movement while enabled.
    fileprivate func attach(to mixer: Mixer) { self.mixer = mixer }

    public func performTransition(from: Deck, to: Deck, over seconds: TimeInterval) {
        guard isEnabled, seconds > 0, from !== to else { return }
        from.setAsMaster()
        to.sync()
        if from.channelIndex == 0 {
            mixer?.channelA.eqLow = -6
        } else if from.channelIndex == 1 {
            mixer?.channelB.eqLow = -6
        }
    }
    internal init() {}
}

@MainActor
public final class SmartCFX {
    public var isEnabled: Bool = false
    public var amount: Double = 0                     // single control
    public var preset: Int = 0                        // curated multi-FX chains
    internal init() {}
}

// MARK: - Sampler / mic / monitoring / recording

@MainActor
public final class Sampler {
    public enum Play: Sendable { case oneShot, loop, gate }
    private let bridge: EngineBridge
    private var buffers: [PCMBuffer?] = Array(repeating: nil, count: 16)
    private var modes: [Play] = Array(repeating: .oneShot, count: 16)
    private var gains: [Double] = Array(repeating: 1, count: 16)

    fileprivate init(bridge: EngineBridge) {
        self.bridge = bridge
        bridge.register(self)
    }

    public func load(_ slot: Int, buffer: PCMBuffer) {
        guard buffers.indices.contains(slot) else { return }
        buffers[slot] = buffer
        buffer.withUnsafeChannels { channels, frames in
            channels.withMemoryRebound(to: UnsafePointer<Float>?.self, capacity: buffer.channelCount) { pointers in
                pe_sampler_set_slot(
                    bridge.handle,
                    Int32(slot),
                    UnsafePointer(pointers),
                    Int32(buffer.channelCount),
                    Int64(frames)
                )
            }
        }
    }

    public func trigger(_ slot: Int) {
        guard buffers.indices.contains(slot), buffers[slot] != nil else { return }
        var command = pe_command(
            type: PE_CMD_SAMPLER_TRIGGER, deck: -1, i0: Int32(slot), i1: 0, i2: 0, f0: 0, f1: 0
        )
        _ = pe_post_command(bridge.handle, &command)
    }

    public func stop(_ slot: Int) {
        guard buffers.indices.contains(slot) else { return }
        var command = pe_command(
            type: PE_CMD_SAMPLER_STOP, deck: -1, i0: Int32(slot), i1: 0, i2: 0, f0: 0, f1: 0
        )
        _ = pe_post_command(bridge.handle, &command)
    }

    public func setMode(_ slot: Int, _ mode: Play) {
        guard modes.indices.contains(slot) else { return }
        modes[slot] = mode
    }

    public func setGain(_ slot: Int, _ gain: Double) {
        guard gains.indices.contains(slot) else { return }
        gains[slot] = max(0, gain)
    }

    public var masterGain: Double = 0.8
}

@MainActor
public final class MicInput {
    public var level: Double = 0
    public var isMuted: Bool = true
    /// Push captured mic PCM (app supplies the capture path).
    public func submit(_ buffer: PCMBuffer) { unimplemented() }
    internal init() { unimplemented() }
}

@MainActor
public final class Monitoring {
    public var masterCue: Bool = false
    public var cueMasterMix: Double = 0.5   // 0 = cue only, 1 = master only
    public var headphoneLevel: Double = 0.7
    internal init() { unimplemented() }
}

/// Records the master bus off the RT thread. **No MP3** (see `ExportCodec`).
@MainActor
public final class MixRecorder {
    private let codec: ExportCodec
    private let url: URL
    private var chunks: [PCMBuffer] = []
    private var captureFormat: AudioFormat?
    public private(set) var isRecording: Bool = false

    public init(codec: ExportCodec, url: URL) throws {
        self.codec = codec
        self.url = url
    }

    public func start() {
        chunks.removeAll(keepingCapacity: true)
        captureFormat = nil
        isRecording = true
    }

    /// Append a non-interleaved master-bus block. The engine may call this
    /// from its off-thread capture handoff; the recorder performs final file
    /// encoding only when `stop()` is called on the control actor.
    public func append(_ buffer: PCMBuffer) {
        guard isRecording else { return }
        if let captureFormat {
            guard captureFormat == buffer.format else { return }
        } else {
            captureFormat = buffer.format
        }
        chunks.append(buffer)
    }

    public func stop() throws {
        guard isRecording else { return }
        defer {
            isRecording = false
            chunks.removeAll(keepingCapacity: true)
            captureFormat = nil
        }

        let format = captureFormat ?? AudioFormat(sampleRate: 48_000, channelCount: 2)
        let frameCount = chunks.reduce(0) { $0 + $1.frameCount }
        let output = PCMBuffer(format: format, capacity: frameCount)
        var offset = 0
        for chunk in chunks {
            for channel in 0..<format.channelCount {
                for frame in 0..<chunk.frameCount {
                    output.channel(channel)[offset + frame] = chunk.channel(channel)[frame]
                }
            }
            offset += chunk.frameCount
        }

        let writer = try AudioFileWriter(url: url, format: format, codec: codec)
        try writer.write(output)
        try writer.finish()
    }
}
