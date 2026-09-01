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
#if canImport(AVFoundation)
import AVFoundation
#endif

@inline(never)
func unimplemented(_ fn: StaticString = #function, file: StaticString = #file, line: UInt = #line) -> Never {
    fatalError("unimplemented: \(fn) — implement per docs/SPEC.md §11", file: file, line: line)
}

public enum AudioEngineError: Error, Sendable {
    case invalidOutputFormat
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
    private let bridge: EngineBridge
    private let sampleRate: Double
    private let maxFramesPerRender: Int
    public private(set) var isRunning: Bool = false
#if canImport(AVFoundation)
    private var audioEngine: AVAudioEngine?
#endif

    public init(sampleRate: Double = 48_000, maxFramesPerRender: Int = 512) {
        let bridge = EngineBridge(sampleRate: sampleRate, maxFrames: maxFramesPerRender)
        self.bridge = bridge
        self.sampleRate = sampleRate
        self.maxFramesPerRender = maxFramesPerRender
        deckA = Deck(bridge: bridge, index: 0)
        deckB = Deck(bridge: bridge, index: 1)
        mixer = Mixer(bridge: bridge)
        sampler = Sampler(bridge: bridge)
        mic = MicInput(bridge: bridge)
        monitoring = Monitoring(bridge: bridge)
    }

    /// Installs the AVAudioSourceNode render block that calls `pe_render`.
    public func start() throws {
#if canImport(AVFoundation)
        guard !isRunning else { return }
        let audioEngine = AVAudioEngine()
        let outputFormat = audioEngine.outputNode.inputFormat(forBus: 0)
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputFormat.sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw AudioEngineError.invalidOutputFormat
        }

        let handle = bridge.handle
        let sourceNode = AVAudioSourceNode(format: sourceFormat) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            pe_render(handle, left, right, Int32(frameCount))
            return noErr
        }
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: sourceFormat)
        try audioEngine.start()
        self.audioEngine = audioEngine
#endif
        isRunning = true
    }

    public func stop() {
#if canImport(AVFoundation)
        audioEngine?.stop()
        audioEngine = nil
#endif
        isRunning = false
    }

    /// A device-free, synchronous engine for deterministic tests (calls `pe_step`).
    public func makeHeadless() -> HeadlessDJEngine {
        HeadlessDJEngine(sampleRate: sampleRate, maxFramesPerRender: maxFramesPerRender)
    }
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
    weak var mixer: Mixer?

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
        control.limiter_ceiling_db = -0.3
        control.cue_master_mix = 0.5
        control.master_cue = 0
        control.headphone_level = 0.7
        control.cue_pfl = (0, 0)
        control.xfade_assign = (2, 2)
        control.fader_start = (0, 0)
        control.eq_low = (0, 0)
        control.eq_mid = (0, 0)
        control.eq_high = (0, 0)
        control.color_amount = (0, 0)
        control.color_kind = (0, 0)
        control.beatfx_kind = 0
        control.beatfx_beats = 0.5
        control.beatfx_depth = 0.5
        control.beatfx_assign = 0
        control.beatfx_on = 0
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

    func register(_ mixer: Mixer) { self.mixer = mixer }

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
    public let mic: MicInput
    public let monitoring: Monitoring
    private let bridge: EngineBridge

    public init(sampleRate: Double = 48_000, maxFramesPerRender: Int = 512) {
        bridge = EngineBridge(sampleRate: sampleRate, maxFrames: maxFramesPerRender)
        deckA = Deck(bridge: bridge, index: 0)
        deckB = Deck(bridge: bridge, index: 1)
        mixer = Mixer(bridge: bridge)
        sampler = Sampler(bridge: bridge)
        mic = MicInput(bridge: bridge)
        monitoring = Monitoring(bridge: bridge)
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
                case PE_EVT_PEAK:
                    if event.deck == 0 { mixer.channelA.updatePeak(event.f0) }
                    if event.deck == 1 { mixer.channelB.updatePeak(event.f0) }
                    if event.deck == -1 { mixer.master.updatePeak(event.f0) }
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
    private struct SavedLoop {
        let start: TimeInterval
        let end: TimeInterval
    }

    private struct PadFXAssignment {
        let effect: BeatFXUnit.Kind
        let hold: Bool
    }

    private let bridge: EngineBridge
    private let index: Int
    private var buffer: PCMBuffer?
    private var trackAnalysis: TrackAnalysis?
    private var currentPlayhead: TimeInterval = 0
    private var shadowPlayhead: TimeInterval = 0
    private var hotCueTimes: [TimeInterval?] = Array(repeating: nil, count: 8)
    private var cueTime: TimeInterval?
    private var joggingWasPlaying = false
    private var loopStartTime: TimeInterval?
    private var loopEndTime: TimeInterval?
    private var loopRollActive = false
    private var loopRollWasSlipping = false
    private var savedLoops: [SavedLoop?] = Array(repeating: nil, count: 8)
    private var padFXAssignments: [[PadFXAssignment?]] = Array(
        repeating: Array(repeating: nil, count: 8), count: 2
    )
    private var trackBPM: Double = 120
    private var beatPositions: [TimeInterval] = []
    public private(set) var waveform: Waveform?
    public private(set) var beatGrid: [TimeInterval] = []

    fileprivate init(bridge: EngineBridge, index: Int) {
        self.bridge = bridge
        self.index = index
        bridge.register(self, index: index)
    }

    fileprivate var channelIndex: Int { index }

    // Loading / transport
    public func load(_ analysis: TrackAnalysis, buffer: PCMBuffer) {
        self.buffer = buffer
        trackAnalysis = analysis
        waveform = analysis.waveform
        currentPlayhead = 0
        shadowPlayhead = 0
        hotCueTimes = Array(repeating: nil, count: 8)
        cueTime = nil
        nudgeRatio = 1
        isPlaying = false
        loopStartTime = nil
        loopEndTime = nil
        loopRollActive = false
        loopRollWasSlipping = false
        savedLoops = Array(repeating: nil, count: 8)
        trackBPM = analysis.tempo.bpm > 0 ? analysis.tempo.bpm : 120
        beatPositions = analysis.tempo.beatPositions
        beatGrid = beatPositions
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
        if autoCue {
            cueTime = 0
            post(PE_CMD_SET_CUE)
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

    /// Normalized phase within the current beat, when a beatgrid is available.
    public var beatPhase: Double {
        guard let beat = beatGrid.last(where: { $0 <= currentPlayhead }), effectiveBPM > 0 else { return 0 }
        let period = 60 / effectiveBPM
        guard period.isFinite, period > 0 else { return 0 }
        return max(0, min(1, (currentPlayhead - beat) / period))
    }

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

    private func post(_ type: pe_cmd_type, i0: Int = 0, i1: Int = 0, f0: Float = 0, f1: Float = 0) {
        var command = pe_command(type: type, deck: Int32(index), i0: Int32(i0), i1: Int32(i1), i2: 0, f0: f0, f1: f1)
        _ = pe_post_command(bridge.handle, &command)
    }

    // Temporary cue
    public func setCue() {
        cueTime = quantizedTime(currentPlayhead)
        post(PE_CMD_SET_CUE, f0: Float(cueTime ?? currentPlayhead))
    }
    public func jumpToCue() {
        guard let cueTime else { return }
        currentPlayhead = cueTime
        shadowPlayhead = cueTime
        post(PE_CMD_JUMP_CUE)
    }
    public func cuePlayPress() {
        if cueTime == nil { setCue() }
        jumpToCue()
        post(PE_CMD_PLAY)
        isPlaying = true
    }
    public func cuePlayRelease() {
        guard cueTime != nil else { return }
        post(PE_CMD_PAUSE)
        jumpToCue()
        isPlaying = false
    }

    /// Stops the deck and returns its transport to frame zero.
    public func returnToStart() {
        if isPlaying { pause() }
        currentPlayhead = 0
        shadowPlayhead = 0
        post(PE_CMD_SEEK, f0: 0)
    }

    /// Makes this deck an instant double of another loaded deck.
    public func instantDouble(from other: Deck) {
        guard other !== self, let sourceBuffer = other.buffer, let sourceAnalysis = other.trackAnalysis else { return }
        let target = other.currentPlayhead
        load(sourceAnalysis, buffer: sourceBuffer)
        currentPlayhead = target
        shadowPlayhead = target
        let frame = target * sourceBuffer.format.sampleRate
        post(PE_CMD_SEEK, f0: Float(max(0, frame)))
        if other.isPlaying { play() }
    }

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

    private var nudgeRatio: Double = 1

    private func updatePlaybackRate() {
        bridge.setDeckPlayback(index: index, tempoRatio: playbackRatio * nudgeRatio, pitchSemitones: pitchSemitones)
    }

    // Jog / scratch (engages varispeed transiently)
    public var vinylMode: Bool = true
    public func jogTouchBegan() {
        joggingWasPlaying = isPlaying
        if vinylMode { isPlaying = false }
        post(PE_CMD_JOG_TOUCH, i0: vinylMode ? 1 : 0, i1: joggingWasPlaying ? 1 : 0)
    }
    public func jogMoved(deltaSamples: Double) {
        guard deltaSamples.isFinite else { return }
        post(PE_CMD_JOG_MOVE, f0: Float(deltaSamples))
    }
    /// Searches by an exact number of source frames without changing transport state.
    public func frameSearch(frames: Double) {
        jogMoved(deltaSamples: frames)
    }
    /// Searches by seconds; positive values move forward and negative values backward.
    public func fastSearch(seconds: TimeInterval) {
        guard let buffer, seconds.isFinite else { return }
        frameSearch(frames: seconds * buffer.format.sampleRate)
    }
    public func jogTouchEnded() {
        if vinylMode && joggingWasPlaying { isPlaying = true }
        post(PE_CMD_JOG_RELEASE, i0: vinylMode ? 1 : 0, i1: joggingWasPlaying ? 1 : 0)
        joggingWasPlaying = false
    }
    public func nudge(_ amount: Double) {
        let bend = max(-1.0, min(1.0, amount.isFinite ? amount : 0))
        nudgeRatio = 1 + bend * 0.08
        updatePlaybackRate()
    }   // pitch bend
    /// Returns the tempo fader and transient nudge to neutral.
    public func tempoReset() {
        tempoPercent = 0
        nudgeRatio = 1
        updatePlaybackRate()
    }

    // Hot cues (8)
    public func setHotCue(_ index: Int) {
        guard hotCueTimes.indices.contains(index) else { return }
        hotCueTimes[index] = quantizedTime(currentPlayhead)
        post(PE_CMD_HOTCUE_SET, i0: index, f0: Float(hotCueTimes[index] ?? currentPlayhead))
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
    public private(set) var isLoopActive: Bool = false
    /// The current loop-in point in seconds, when a loop has been defined.
    public var loopStart: TimeInterval? { loopStartTime }
    /// The current loop-out point in seconds, when a loop has been defined.
    public var loopEnd: TimeInterval? { loopEndTime }

    private var trackDuration: TimeInterval {
        guard let buffer, buffer.format.sampleRate > 0 else { return 0 }
        return Double(buffer.frameCount) / buffer.format.sampleRate
    }

    private func setLocalLoop(start: TimeInterval, end: TimeInterval, active: Bool = true) {
        guard start.isFinite, end.isFinite, end > start else { return }
        let duration = trackDuration
        let clampedStart = max(0, min(start, duration))
        let clampedEnd = max(clampedStart, min(end, duration))
        guard clampedEnd > clampedStart else { return }
        loopStartTime = clampedStart
        loopEndTime = clampedEnd
        isLoopActive = active
    }

    private func publishLoop(start: TimeInterval, end: TimeInterval, active: Bool) {
        setLocalLoop(start: start, end: end, active: active)
        guard let loopStartTime, let loopEndTime else { return }
        post(
            PE_CMD_SET_LOOP,
            i0: active ? 1 : 0,
            f0: Float(loopStartTime),
            f1: Float(loopEndTime)
        )
    }

    /// Returns the nearest beat-grid point. Tracks without an analyzed grid
    /// use the analyzed BPM and a zero-based quarter-note grid.
    private func quantizedTime(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return currentPlayhead }
        let duration = trackDuration
        let clamped = max(0, min(time, duration))
        guard quantize else { return clamped }

        let grid = beatPositions.filter { $0.isFinite && $0 >= 0 && $0 <= duration }
        if let nearest = grid.min(by: { abs($0 - clamped) < abs($1 - clamped) }) {
            return nearest
        }
        guard trackBPM.isFinite, trackBPM > 0 else { return clamped }
        let beatLength = 60 / trackBPM
        guard beatLength.isFinite, beatLength > 0 else { return clamped }
        return max(0, min(duration, (clamped / beatLength).rounded() * beatLength))
    }

    private func resizeLocalLoop(by multiplier: Double) {
        guard let start = loopStartTime, let end = loopEndTime, multiplier > 0 else { return }
        let center = (start + end) * 0.5
        let length = (end - start) * multiplier
        var newStart = center - length * 0.5
        var newEnd = center + length * 0.5
        let duration = trackDuration
        if newStart < 0 { newEnd -= newStart; newStart = 0 }
        if newEnd > duration { newStart -= newEnd - duration; newEnd = duration }
        setLocalLoop(start: max(0, newStart), end: min(duration, newEnd), active: isLoopActive)
    }

    public func loopIn() {
        loopStartTime = quantizedTime(currentPlayhead)
        isLoopActive = false
        post(PE_CMD_LOOP_IN, f0: Float(loopStartTime ?? currentPlayhead))
    }
    public func loopOut() {
        guard let start = loopStartTime else { return }
        let endpoint = quantizedTime(currentPlayhead)
        let loopStart = min(start, endpoint)
        let loopEnd = max(start, endpoint)
        guard loopEnd > loopStart else { return }
        publishLoop(start: loopStart, end: loopEnd, active: true)
    }
    public func reloopExit() {
        if isLoopActive {
            isLoopActive = false
            if slip { currentPlayhead = shadowPlayhead }
        } else if loopStartTime != nil, loopEndTime != nil {
            isLoopActive = true
        }
        post(PE_CMD_RELOOP_EXIT)
    }
    public func autoBeatLoop(beats: Double) {
        guard beats > 0, trackBPM > 0 else { return }
        let length = beats * 60 / trackBPM
        let start = min(quantizedTime(currentPlayhead), max(0, trackDuration - length))
        let end = start + min(length, trackDuration - start)
        setLocalLoop(start: start, end: end)
        post(PE_CMD_BEATLOOP, f0: Float(length), f1: Float(start))
    }
    public func loopHalve() {
        resizeLocalLoop(by: 0.5)
        if let loopStartTime, let loopEndTime {
            publishLoop(start: loopStartTime, end: loopEndTime, active: isLoopActive)
        }
    }
    public func loopDouble() {
        resizeLocalLoop(by: 2)
        if let loopStartTime, let loopEndTime {
            publishLoop(start: loopStartTime, end: loopEndTime, active: isLoopActive)
        }
    }
    public func loopMove(beats: Double) {
        guard trackBPM > 0 else { return }
        if let start = loopStartTime, let end = loopEndTime {
            let shift = beats * 60 / trackBPM
            let length = end - start
            let newStart = min(
                max(0, quantizedTime(start + shift)),
                max(0, trackDuration - length)
            )
            publishLoop(start: newStart, end: newStart + length, active: isLoopActive)
        }
    }

    /// Moves the loop-in edge while preserving the loop-out edge.
    public func adjustLoopIn(by seconds: TimeInterval) {
        guard seconds.isFinite, let end = loopEndTime else { return }
        let candidate = quantizedTime((loopStartTime ?? currentPlayhead) + seconds)
        let minimumLength = buffer.map { 1 / $0.format.sampleRate } ?? 0.000001
        let start = min(max(0, candidate), end - minimumLength)
        guard end > start else { return }
        publishLoop(start: start, end: end, active: isLoopActive)
    }

    /// Moves the loop-out edge while preserving the loop-in edge.
    public func adjustLoopOut(by seconds: TimeInterval) {
        guard seconds.isFinite, let start = loopStartTime else { return }
        let candidate = quantizedTime((loopEndTime ?? currentPlayhead) + seconds)
        let end = max(start + (buffer.map { 1 / $0.format.sampleRate } ?? 0.000001), candidate)
        guard end <= trackDuration else { return }
        publishLoop(start: start, end: end, active: isLoopActive)
    }

    public func adjustLoopIn(seconds: TimeInterval) { adjustLoopIn(by: seconds) }
    public func adjustLoopOut(seconds: TimeInterval) { adjustLoopOut(by: seconds) }

    /// Starts a temporary slip-style loop. Playback resumes from the
    /// continuous shadow position when `loopRollRelease()` is called.
    public func loopRoll(beats: Double) {
        guard beats > 0, beats.isFinite else { return }
        if !loopRollActive {
            loopRollActive = true
            loopRollWasSlipping = slip
            if !slip { slip = true }
        }
        autoBeatLoop(beats: beats)
    }

    public func loopRollRelease() {
        guard loopRollActive else { return }
        if isLoopActive { reloopExit() }
        loopRollActive = false
        slip = loopRollWasSlipping
        loopRollWasSlipping = false
    }

    public func startLoopRoll(beats: Double) { loopRoll(beats: beats) }
    public func endLoopRoll() { loopRollRelease() }
    public func saveLoop(_ slot: Int) {
        guard savedLoops.indices.contains(slot), let start = loopStartTime, let end = loopEndTime else { return }
        savedLoops[slot] = SavedLoop(start: start, end: end)
    }
    public func callLoop(_ slot: Int) {
        guard savedLoops.indices.contains(slot), let saved = savedLoops[slot] else { return }
        setLocalLoop(start: saved.start, end: saved.end)
        post(PE_CMD_SET_LOOP, i0: 1, f0: Float(saved.start), f1: Float(saved.end))
    }
    public func setActiveLoop(_ enabled: Bool) {
        guard loopStartTime != nil, loopEndTime != nil else { return }
        isLoopActive = enabled
        post(PE_CMD_SET_LOOP_ACTIVE, f0: enabled ? 1 : 0)
    }

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
    public var autoCue: Bool = false {
        didSet {
            if autoCue, buffer != nil {
                cueTime = 0
                post(PE_CMD_SET_CUE)
            }
        }
    }
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
            let bank = padMode == .padFX1 ? 0 : 1
            guard let assignment = padFXAssignments[bank][index] else { return }
            bridge.mixer?.beatFX.kind = assignment.effect
            bridge.mixer?.beatFX.isOn = true
        case .beatJump:
            beatJump(beats: Double(index - 3) * beatJumpSize)
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
        if padMode == .padFX1 || padMode == .padFX2 {
            let bank = padMode == .padFX1 ? 0 : 1
            if padFXAssignments[bank][index]?.hold == true {
                bridge.mixer?.beatFX.releaseFX()
            }
        }
    }
    /// Assign an effect to a Pad-FX pad (bank 1 or 2).
    public func assignPadFX(bank: Int, pad: Int, effect: BeatFXUnit.Kind, hold: Bool) {
        guard (1...2).contains(bank), (0..<8).contains(pad) else { return }
        padFXAssignments[bank - 1][pad] = PadFXAssignment(effect: effect, hold: hold)
    }
    /// Beat-jump size for `.beatJump` mode.
    public var beatJumpSize: Double = 4

    /// Jumps by musical beats and snaps the destination when quantize is on.
    public func beatJump(beats: Double) {
        guard beats.isFinite, trackBPM > 0 else { return }
        let rawTarget = currentPlayhead + beats * 60 / trackBPM
        let target = quantizedTime(rawTarget)
        let seconds = target - currentPlayhead
        currentPlayhead = target
        shadowPlayhead = target
        post(PE_CMD_BEATJUMP, f0: Float(seconds))
    }

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
        channelA = Channel(bridge: bridge, index: 0)
        channelB = Channel(bridge: bridge, index: 1)
        master = MasterOut(bridge: bridge)
        beatFX = BeatFXUnit(bridge: bridge)
        smartFader = SmartFader()
        smartCFX = SmartCFX()
        smartFader.attach(to: self)
        bridge.register(self)
    }

    private func publishControl() {
        bridge.control.crossfader = Float(max(-1, min(1, crossfader)))
        bridge.control.xfade_curve = crossfaderCurve == .smooth ? 0 : (crossfaderCurve == .linear ? 0.5 : 1)
        bridge.publishControl()
    }
}

public enum ColorFX: Sendable, CaseIterable, Equatable { case filter, space, dubEcho, sweep, noise, crush, pitch }

public enum XFAssign: Sendable { case a, b, thru }

@MainActor
public final class Channel {
    private let bridge: EngineBridge
    private let index: Int
    public var trim: Double = 0.5 { didSet { publishControl() } } // gain
    public var eqLow: Double = 0 { didSet { publishControl() } } // dB, -inf(kill)..+6
    public var eqMid: Double = 0 { didSet { publishControl() } }
    public var eqHigh: Double = 0 { didSet { publishControl() } }
    public var colorFX: ColorFX = .filter { didSet { publishControl() } }
    public var colorAmount: Double = 0 { didSet { publishControl() } } // -1..+1 (center = off)
    public var fader: Double = 1 { didSet { publishControl() } } // 0..1
    public var cuePFL: Bool = false { didSet { publishControl() } } // headphone pre-listen
    public var faderStart: Bool = false { didSet { publishControl() } }
    public var crossfaderAssign: XFAssign = .thru { didSet { publishControl() } }
    /// Latest peak meter (0..1), updated from the RT event stream.
    public private(set) var peakMeter: Float = 0
    fileprivate func updatePeak(_ value: Float) {
        peakMeter = value.isFinite ? max(0, min(1, value)) : 0
    }
    fileprivate init(bridge: EngineBridge, index: Int) {
        self.bridge = bridge
        self.index = index
    }

    private func publishControl() {
        let gain = Float(max(0, trim))
        let channelFader = Float(max(0, min(1, fader)))
        let pfl = cuePFL ? Float(1) : Float(0)
        let assignment: Float = switch crossfaderAssign {
        case .a: 0
        case .b: 1
        case .thru: 2
        }
        let start = faderStart ? Float(1) : Float(0)
        let low = Float(eqLow.isNaN ? 0 : eqLow)
        let mid = Float(eqMid.isNaN ? 0 : eqMid)
        let high = Float(eqHigh.isNaN ? 0 : eqHigh)
        let colorAmount = Float(self.colorAmount.isFinite ? max(-1, min(1, self.colorAmount)) : 0)
        let colorKind = Float(ColorFX.allCases.firstIndex(of: colorFX) ?? 0)
        if index == 0 {
            bridge.control.trim.0 = gain
            bridge.control.fader.0 = channelFader
            bridge.control.cue_pfl.0 = pfl
            bridge.control.xfade_assign.0 = assignment
            bridge.control.fader_start.0 = start
            bridge.control.eq_low.0 = low
            bridge.control.eq_mid.0 = mid
            bridge.control.eq_high.0 = high
            bridge.control.color_amount.0 = colorAmount
            bridge.control.color_kind.0 = colorKind
        } else {
            bridge.control.trim.1 = gain
            bridge.control.fader.1 = channelFader
            bridge.control.cue_pfl.1 = pfl
            bridge.control.xfade_assign.1 = assignment
            bridge.control.fader_start.1 = start
            bridge.control.eq_low.1 = low
            bridge.control.eq_mid.1 = mid
            bridge.control.eq_high.1 = high
            bridge.control.color_amount.1 = colorAmount
            bridge.control.color_kind.1 = colorKind
        }
        bridge.publishControl()
    }
}

@MainActor
public final class BeatFXUnit {
    public enum Kind: Sendable, CaseIterable, Equatable {
        case echo, echoOut, reverb, delay, multiTapDelay, flanger, phaser,
             trans, roll, spiral, pitch, lowCutEcho, vinylBrake, helix
    }
    public enum Assign: Sendable { case chA, chB, both, master }
    private let bridge: EngineBridge
    public var kind: Kind = .echo { didSet { publishControl() } }
    public var beats: Double = 0.5 { didSet { publishControl() } } // time division
    public var depth: Double = 0.5 { didSet { publishControl() } } // wet/level
    public var assign: Assign = .chA { didSet { publishControl() } }
    public var isOn: Bool = false { didSet { publishControl() } }

    fileprivate init(bridge: EngineBridge) { self.bridge = bridge }

    public func releaseFX() {
        isOn = false
        var command = pe_command(
            type: PE_CMD_BEATFX_RELEASE, deck: -1, i0: 0, i1: 0, i2: 0, f0: 0, f1: 0
        )
        _ = pe_post_command(bridge.handle, &command)
    }

    private func publishControl() {
        bridge.control.beatfx_kind = Float(Kind.allCases.firstIndex(of: kind) ?? 0)
        bridge.control.beatfx_beats = Float(beats.isFinite && beats > 0 ? beats : 0.5)
        bridge.control.beatfx_depth = Float(depth.isFinite ? max(0, min(1, depth)) : 0.5)
        bridge.control.beatfx_assign = switch assign {
        case .chA: 0
        case .chB: 1
        case .both: 2
        case .master: 3
        }
        bridge.control.beatfx_on = isOn ? 1 : 0
        bridge.publishControl()
    }
}

@MainActor
public final class MasterOut {
    private let bridge: EngineBridge
    public var level: Double = 0.8 { didSet { publishControl() } }
    public var masterCue: Bool = false
    /// Limiter ceiling in dBTP (default −0.3).
    public var limiterCeilingDB: Double = -0.3 { didSet { publishControl() } }
    /// Latest master peak (0..1).
    public private(set) var peakMeter: Float = 0
    fileprivate func updatePeak(_ value: Float) {
        peakMeter = value.isFinite ? max(0, min(1, value)) : 0
    }
    fileprivate init(bridge: EngineBridge) { self.bridge = bridge }

    private func publishControl() {
        bridge.control.master_level = Float(max(0, min(1, level)))
        bridge.control.limiter_ceiling_db = Float(limiterCeilingDB.isFinite ? limiterCeilingDB : -0.3)
        bridge.publishControl()
    }
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
    private let bridge: EngineBridge
    private var buffer: PCMBuffer?
    public var level: Double = 0 {
        didSet { publishLevel() }
    }
    public var isMuted: Bool = true {
        didSet { publishLevel() }
    }
    /// Push captured mic PCM (app supplies the capture path).
    public func submit(_ buffer: PCMBuffer) {
        self.buffer = buffer
        buffer.withUnsafeChannels { channels, frames in
            channels.withMemoryRebound(to: UnsafePointer<Float>?.self, capacity: buffer.channelCount) { pointers in
                pe_mic_set_buffer(
                    bridge.handle,
                    UnsafePointer(pointers),
                    Int32(buffer.channelCount),
                    Int64(frames),
                    buffer.format.sampleRate
                )
            }
        }
    }
    fileprivate init(bridge: EngineBridge) { self.bridge = bridge }

    private func publishLevel() {
        bridge.control.mic_level = Float(isMuted ? 0 : max(0, min(1, level)))
        bridge.publishControl()
    }
}

@MainActor
public final class Monitoring {
    private let bridge: EngineBridge
    public var masterCue: Bool = false { didSet { publishControl() } }
    public var cueMasterMix: Double = 0.5 { didSet { publishControl() } } // 0 = cue only, 1 = master only
    public var headphoneLevel: Double = 0.7 { didSet { publishControl() } }
    fileprivate init(bridge: EngineBridge) { self.bridge = bridge }

    private func publishControl() {
        bridge.control.master_cue = masterCue ? 1 : 0
        bridge.control.cue_master_mix = Float(max(0, min(1, cueMasterMix)))
        bridge.control.headphone_level = Float(max(0, min(1, headphoneLevel)))
        bridge.publishControl()
    }
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
