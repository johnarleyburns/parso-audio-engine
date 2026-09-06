//
//  ParsoDJEngine.swift
//  DDJ-FLX4-equivalent DJ orchestration over CParsoEngine + Core + Analysis.
//  Control objects are @MainActor; the real-time DSP runs in CParsoEngine.
//
//  STATUS: implemented per docs/SPEC.md §11. `DJEngine` drives an
//  AVAudioSourceNode via `pe_render`; `HeadlessDJEngine` drives the same DSP
//  synchronously via `pe_step` for the deterministic test suite.
//

import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import CParsoEngine
import AVFoundation

public enum AudioEngineError: Error, Sendable {
    case invalidOutputFormat
}

/// Render-side telemetry snapshot (Phase 6b item 2). The Tonearm adapter maps
/// this onto its app-facing `EngineTelemetry` value type.
public struct EngineStats: Sendable {
    public var masterSample: Int64
    public var masterBPM: Double
    public var downbeatPhase: Double
    /// Decks 0/1 only — kept for source compatibility. Prefer the `*All` arrays,
    /// which cover every deck the engine was created with (up to 4).
    public var deckEffectiveBPM: (Double, Double)
    public var deckBeatPhase: (Double, Double)
    public var deckSynced: (Bool, Bool)
    /// Per-deck telemetry for all `deckCount` decks (CDJ3000 parity C1).
    public var deckEffectiveBPMAll: [Double]
    public var deckBeatPhaseAll: [Double]
    public var deckSyncedAll: [Bool]
    public var renderLoad: Double
    public var starvedFrames: Int64
}

// MARK: - Top-level engine

/// The complete two-deck software DJ engine. Owns two `Deck`s, a `Mixer`, a
/// `Sampler`, a `MicInput`, and `Monitoring`. Install with `start()`.
@MainActor
public final class DJEngine {
    /// All decks (2…4). `deckA`/`deckB` alias `decks[0]`/`decks[1]`.
    public let decks: [Deck]
    public var deckA: Deck { decks[0] }
    public var deckB: Deck { decks[1] }
    /// Third / fourth decks — present when created with `deckCount >= 3` / `>= 4`
    /// (the default is 4, the CDJ-3000 booth target). Trap on a 2-deck engine.
    public var deckC: Deck { decks[2] }
    public var deckD: Deck { decks[3] }
    public let mixer: Mixer
    public let sampler: Sampler
    public let mic: MicInput
    public let monitoring: Monitoring
    private let bridge: EngineBridge
    private let sampleRateValue: Double
    /// Engine sample rate (Phase 6a `WorkspaceEngine.sampleRate`).
    public var sampleRate: Double { sampleRateValue }
    private let maxFramesPerRender: Int
    /// Nominal render buffer period in milliseconds.
    public var bufferPeriodMillis: Double { Double(maxFramesPerRender) / sampleRateValue * 1000 }
    public private(set) var isRunning: Bool = false
    private var audioEngine: AVAudioEngine?
    private var configChangeObserver: NSObjectProtocol?
    private var configChangeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(sampleRate: Double = 48_000, maxFramesPerRender: Int = 512, deckCount: Int = 4) {
        let bridge = EngineBridge(sampleRate: sampleRate, maxFrames: maxFramesPerRender, deckCount: deckCount)
        self.bridge = bridge
        self.sampleRateValue = sampleRate
        self.maxFramesPerRender = maxFramesPerRender
        decks = (0..<bridge.deckCount).map { Deck(bridge: bridge, index: $0) }
        mixer = Mixer(bridge: bridge)
        sampler = Sampler(bridge: bridge)
        mic = MicInput(bridge: bridge)
        monitoring = Monitoring(bridge: bridge)
    }

    /// Installs the AVAudioSourceNode render block that calls `pe_render`.
    public func start() throws {
        guard !isRunning else { return }
        try buildGraph()
        isRunning = true
        installConfigurationObserver()
    }

    /// Tears the `AVAudioEngine` graph down and rebuilds it in place without
    /// dropping `pe_engine` state — deck buffers, playheads, loops and control
    /// all survive (Phase 6b item 9 / `WorkspaceEngine.recoverGraph()`).
    public func recoverGraph() throws {
        audioEngine?.stop()
        audioEngine = nil
        try buildGraph()
        isRunning = true
    }

    /// Emits when the audio hardware configuration changes (route change,
    /// sample-rate change). Consumers typically call `recoverGraph()` in response.
    public func configurationChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            configChangeContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.configChangeContinuations[id] = nil }
            }
        }
    }

    private func installConfigurationObserver() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.configChangeContinuations.values.forEach { $0.yield(()) }
            }
        }
    }

    private func buildGraph() throws {
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

        let sourceNode = AVAudioSourceNode(format: sourceFormat,
                                          renderBlock: Self.makeRenderBlock(handle: bridge.handle))
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: sourceFormat)
        try audioEngine.start()
        self.audioEngine = audioEngine
    }

    /// Builds the `AVAudioSourceNode` render callback in a `nonisolated`
    /// static context so the closure literal does not inherit `DJEngine`'s
    /// `@MainActor` isolation. Core Audio invokes this from its own
    /// dedicated real-time thread (`AURemoteIO::IOThread`), never the main
    /// actor's executor — a MainActor-isolated closure compiles in a runtime
    /// isolation check that fires (and traps, `EXC_BREAKPOINT`/`SIGTRAP` via
    /// `dispatch_assert_queue_fail`) the moment the engine starts rendering.
    /// `handle` is an `OpaquePointer`, so it crosses into this nonisolated
    /// scope safely with no shared mutable state.
    nonisolated private static func makeRenderBlock(handle: OpaquePointer) -> AVAudioSourceNodeRenderBlock {
        { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            pe_render(handle, left, right, Int32(frameCount))
            return noErr
        }
    }

    public func stop() {
        audioEngine?.stop()
        audioEngine = nil
        isRunning = false
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
    }

    /// Snapshot of the render-side telemetry atomics (Phase 6b item 2).
    public func telemetry() -> EngineStats { bridge.engineStats() }

    /// The current tempo-master deck's sounding key, or nil if no master is set
    /// or it has no analysed key (CDJ3000 parity C2 — the DJM/CDJ "master key").
    public var masterKey: KeyResult? {
        guard let idx = bridge.masterDeckIndex, decks.indices.contains(idx) else { return nil }
        return decks[idx].soundingKey
    }

    // MARK: Recording (Phase 6b item 4)
    private var recordingPump: Task<Void, Never>?

    /// Begins tapping the master bus into `recorder`. A background pump drains the
    /// render-thread ring ~20×/s; if it can't keep up, frames are dropped and
    /// counted on `droppedRecordFrames`.
    public func startRecording(_ recorder: MixRecorder) {
        bridge.startRecording(recorder)
        recordingPump?.cancel()
        recordingPump = Task { @MainActor [weak self] in
            while !Task.isCancelled, self?.bridge.isRecordingActive == true {
                self?.bridge.drainRecordTap()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
    @discardableResult
    public func interruptRecording(to url: URL) throws -> URL? { try bridge.interruptRecording(to: url) }
    public func stopRecording() throws {
        recordingPump?.cancel()
        recordingPump = nil
        try bridge.stopRecording()
    }
    public var droppedRecordFrames: Int64 { bridge.droppedRecordFrames }

    /// A device-free, synchronous engine for deterministic tests (calls `pe_step`).
    public func makeHeadless() -> HeadlessDJEngine {
        HeadlessDJEngine(sampleRate: sampleRate, maxFramesPerRender: maxFramesPerRender,
                         deckCount: decks.count)
    }
}

/// Maximum decks / mixer channels — mirrors `PE_MAX_DECKS` in parso_engine.h.
fileprivate let kPEMaxDecks = 4

@inline(__always)
fileprivate func peSet(_ t: inout (Float, Float, Float, Float), _ i: Int, _ v: Float) {
    switch i {
    case 0: t.0 = v
    case 1: t.1 = v
    case 2: t.2 = v
    default: t.3 = v
    }
}
@inline(__always) fileprivate func peQuad(_ v: Float) -> (Float, Float, Float, Float) { (v, v, v, v) }

// MARK: - Insert / send-return seam (CDJ3000 parity C3)

/// An app-supplied realtime effect insert. `process` runs on the audio render
/// thread: it **must be realtime-safe** — no locks, no allocation, no syscalls,
/// bounded work. For a channel insert the signal is mono (`left == right`). Use
/// it to host an AUv3, a hand-written kernel, or an external hardware send/return
/// loop (the DJM SEND/RETURN). Mirrors the BYO-codec / BYO-model pattern.
public protocol RealtimeInsert: AnyObject {
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int)
}

/// Where a `RealtimeInsert` sits in the signal path.
public enum InsertPoint: Sendable, Hashable {
    case channel(Int)   // 0…3, post-EQ / pre-gain
    case master         // post master fader, pre isolator + limiter

    fileprivate var raw: Int32 {
        switch self {
        case .channel(let i): return Int32(max(0, min(3, i)))   // PE_INSERT_CH0…CH3
        case .master: return 4                                  // PE_INSERT_MASTER
        }
    }
}

fileprivate let peInsertTrampoline: pe_insert_fn = { left, right, frames, ctx in
    guard let left, let ctx else { return }
    let insert = Unmanaged<AnyObject>.fromOpaque(ctx).takeUnretainedValue()
    (insert as? RealtimeInsert)?.process(left: left, right: right ?? left, frames: Int(frames))
}

@MainActor
fileprivate final class WeakDeck {
    weak var deck: Deck?
    init(_ deck: Deck?) { self.deck = deck }
}

@MainActor
fileprivate final class EngineBridge {
    private let handleBits: UInt
    let engineSampleRate: Double
    let deckCount: Int
    var control: pe_control
    private(set) var masterDeckIndex: Int?
    private var trackBPM: [Double]
    private var deckBoxes: [WeakDeck]
    weak var sampler: Sampler?
    weak var mixer: Mixer?

    var deckA: Deck? { deckBoxes[0].deck }
    var deckB: Deck? { deckBoxes[1].deck }

    var handle: OpaquePointer {
        // The C handle is owned and used exclusively on the main/control actor.
        OpaquePointer(bitPattern: handleBits)!
    }

    init(sampleRate: Double, maxFrames: Int, deckCount: Int) {
        let clampedDecks = min(max(deckCount, 2), kPEMaxDecks)
        guard let handle = pe_create(sampleRate, Int32(maxFrames), Int32(clampedDecks)) else {
            fatalError("CParsoEngine could not be created")
        }
        self.handleBits = UInt(bitPattern: handle)
        self.engineSampleRate = sampleRate
        self.deckCount = clampedDecks
        self.trackBPM = Array(repeating: 120, count: kPEMaxDecks)
        self.deckBoxes = (0..<kPEMaxDecks).map { _ in WeakDeck(nil) }
        var control = pe_control()
        control.crossfader = 0
        control.xfade_curve = 0
        control.master_level = 0.8
        control.limiter_ceiling_db = -0.3
        control.cue_master_mix = 0.5
        control.master_cue = 0
        control.headphone_level = 0.7
        control.mic_eq_low = 0
        control.mic_eq_high = 0
        control.mic_talkover_on = 0
        control.mic_talkover_depth_db = -14
        control.mic_talkover_threshold = 0.02
        control.mic_fx_on = 0
        control.cue_pfl = peQuad(0)
        control.xfade_assign = peQuad(2)
        control.fader_start = peQuad(0)
        control.eq_low = peQuad(0)
        control.eq_mid = peQuad(0)
        control.eq_high = peQuad(0)
        control.color_amount = peQuad(0)
        control.color_kind = peQuad(0)
        control.beatfx_kind = 0
        control.beatfx_beats = 0.5
        control.beatfx_depth = 0.5
        control.beatfx_assign = 0
        control.beatfx_on = 0
        control.beatfx_xpad = -1
        control.beatfx_band = 0
        control.color_param = peQuad(0.5)
        control.trim = peQuad(0.5)
        control.fader = peQuad(1)
        control.deck_time_ratio = peQuad(1)
        control.deck_pitch = peQuad(0)
        control.deck_keylock = peQuad(1)  // Deck.keyLock defaults to true
        control.limiter_enabled = 1
        control.cue_mode = 0
        control.master_eq_low = 0
        control.master_eq_mid = 0
        control.master_eq_high = 0
        control.booth_level = 0.8
        control.booth_eq_low = 0
        control.booth_eq_mid = 0
        control.booth_eq_high = 0
        control.master_reverb_send = 0
        control.master_reverb_size = 0.6
        control.master_reverb_decay = 0.6
        control.master_reverb_damp = 0.5
        self.control = control
        pe_set_control(handle, &self.control)
    }

    deinit { pe_destroy(OpaquePointer(bitPattern: handleBits)) }

    func publishControl() { pe_set_control(handle, &control) }

    func register(_ deck: Deck, index: Int) {
        if deckBoxes.indices.contains(index) { deckBoxes[index] = WeakDeck(deck) }
    }

    private func forEachDeck(_ body: (Deck) -> Void) {
        for box in deckBoxes { if let deck = box.deck { body(deck) } }
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
        deckBoxes.indices.contains(index) ? deckBoxes[index].deck : nil
    }

    func setMaster(index: Int) {
        guard (0..<deckCount).contains(index) else { return }
        masterDeckIndex = index
        forEachDeck { $0.refreshSyncFromMasterIfNeeded() }
    }

    private var isRefreshingSync = false

    func setDeckPlayback(index: Int, tempoRatio: Double, pitchSemitones: Double) {
        let ratio = tempoRatio.isFinite && tempoRatio > 0 ? tempoRatio : 1
        let pitch = pitchSemitones.isFinite ? pitchSemitones : 0
        guard (0..<deckCount).contains(index) else { return }
        peSet(&control.deck_time_ratio, index, Float(ratio))
        peSet(&control.deck_pitch, index, Float(pitch))
        publishControl()
        publishSyncState(index: index)
        // Phase 6b item 2: a master-deck rate change drags the synced deck.
        // Finding C4 — this re-derivation used to run only at engage time.
        if !isRefreshingSync, masterDeckIndex == index {
            isRefreshingSync = true
            forEachDeck { $0.refreshSyncFromMasterIfNeeded() }
            isRefreshingSync = false
        }
    }

    func setDeckKeylock(_ on: Bool, index: Int) {
        guard (0..<deckCount).contains(index) else { return }
        peSet(&control.deck_keylock, index, on ? 1 : 0)
        publishControl()
    }

    /// Publishes the render-side master clock + per-deck sync/effective-rate
    /// telemetry inputs (Phase 6b item 2).
    func publishSyncState(index: Int) {
        guard let deck = deck(at: index) else { return }
        pe_set_deck_sync(handle, Int32(index), deck.isSynced ? 1 : 0,
                         deck.effectiveBPM, deck.beatPhase)
        if masterDeckIndex == index {
            pe_set_master_clock(handle, Int32(index), deck.effectiveBPM, deck.beatPhase)
        } else if masterDeckIndex == nil {
            pe_set_master_clock(handle, -1, 0, 0)
        }
    }

    // MARK: Record tap (Phase 6b item 4)

    private var recorder: MixRecorder?
    private var scratchL = [Float](repeating: 0, count: 8192)
    private var scratchR = [Float](repeating: 0, count: 8192)

    var isRecordingActive: Bool { recorder != nil }
    var droppedRecordFrames: Int64 { pe_record_dropped_frames(handle) }

    func startRecording(_ recorder: MixRecorder) {
        self.recorder = recorder
        recorder.start()
        pe_record_reset(handle)
        pe_record_set_active(handle, 1)
    }

    /// Pulls whatever the render tap has buffered into the recorder.
    func drainRecordTap() {
        guard let recorder, recorder.isRecording else { return }
        while true {
            let n = scratchL.withUnsafeMutableBufferPointer { l in
                scratchR.withUnsafeMutableBufferPointer { r in
                    Int(pe_record_drain(handle, l.baseAddress, r.baseAddress, Int32(l.count)))
                }
            }
            if n == 0 { break }
            let buffer = PCMBuffer(format: .init(sampleRate: engineSampleRate, channelCount: 2), capacity: n)
            for i in 0..<n {
                buffer.channel(0)[i] = scratchL[i]
                buffer.channel(1)[i] = scratchR[i]
            }
            recorder.append(buffer)
            if n < scratchL.count { break }
        }
    }

    @discardableResult
    func interruptRecording(to url: URL) throws -> URL? {
        drainRecordTap()
        return try recorder?.flushSegment(to: url)
    }

    func stopRecording() throws {
        drainRecordTap()
        pe_record_set_active(handle, 0)
        recorder?.droppedFrames = droppedRecordFrames
        try recorder?.stop()
        recorder = nil
    }

    func engineStats() -> EngineStats {
        var s = pe_stats()
        pe_get_stats(handle, &s)
        let n = deckCount
        let bpmAll = withUnsafeBytes(of: s.deck_effective_bpm) { raw -> [Double] in
            let p = raw.bindMemory(to: Double.self); return (0..<n).map { p[$0] }
        }
        let phaseAll = withUnsafeBytes(of: s.deck_beat_phase) { raw -> [Double] in
            let p = raw.bindMemory(to: Double.self); return (0..<n).map { p[$0] }
        }
        let syncedAll = withUnsafeBytes(of: s.deck_synced) { raw -> [Bool] in
            let p = raw.bindMemory(to: Int32.self); return (0..<n).map { p[$0] != 0 }
        }
        return EngineStats(
            masterSample: s.master_frame,
            masterBPM: s.master_bpm,
            downbeatPhase: s.downbeat_phase,
            deckEffectiveBPM: (s.deck_effective_bpm.0, s.deck_effective_bpm.1),
            deckBeatPhase: (s.deck_beat_phase.0, s.deck_beat_phase.1),
            deckSynced: (s.deck_synced.0 != 0, s.deck_synced.1 != 0),
            deckEffectiveBPMAll: bpmAll,
            deckBeatPhaseAll: phaseAll,
            deckSyncedAll: syncedAll,
            renderLoad: s.render_load,
            starvedFrames: s.starved_frames
        )
    }
}

/// Synchronous render harness for tests. Same DSP as `DJEngine`, no audio device.
@MainActor
public final class HeadlessDJEngine {
    /// All decks (2…4). `deckA`/`deckB` alias `decks[0]`/`decks[1]`.
    public let decks: [Deck]
    public var deckA: Deck { decks[0] }
    public var deckB: Deck { decks[1] }
    public var deckC: Deck { decks[2] }
    public var deckD: Deck { decks[3] }
    public let mixer: Mixer
    public let sampler: Sampler
    public let mic: MicInput
    public let monitoring: Monitoring
    private let bridge: EngineBridge

    public init(sampleRate: Double = 48_000, maxFramesPerRender: Int = 512, deckCount: Int = 4) {
        let bridge = EngineBridge(sampleRate: sampleRate, maxFrames: maxFramesPerRender, deckCount: deckCount)
        self.bridge = bridge
        decks = (0..<bridge.deckCount).map { Deck(bridge: bridge, index: $0) }
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
        bridge.drainRecordTap()
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

    /// The booth output for the block most recently produced by `render(frames:)`
    /// — the master through the independent booth level + booth EQ (CDJ3000
    /// parity C3). Call with the same frame count, right after `render`.
    public func renderBooth(frames: Int) -> (left: [Float], right: [Float]) {
        let count = max(0, frames)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                pe_render_booth(bridge.handle, l.baseAddress, r.baseAddress, Int32(count))
            }
        }
        return (left, right)
    }

    /// Snapshot of the render-side telemetry atomics (Phase 6b item 2).
    public func telemetry() -> EngineStats { bridge.engineStats() }

    /// The current tempo-master deck's sounding key, or nil if no master is set
    /// or it has no analysed key (CDJ3000 parity C2 — the DJM/CDJ "master key").
    public var masterKey: KeyResult? {
        guard let idx = bridge.masterDeckIndex, decks.indices.contains(idx) else { return nil }
        return decks[idx].soundingKey
    }

    // MARK: Recording (Phase 6b item 4)
    public func startRecording(_ recorder: MixRecorder) { bridge.startRecording(recorder) }
    @discardableResult
    public func interruptRecording(to url: URL) throws -> URL? { try bridge.interruptRecording(to: url) }
    public func stopRecording() throws { try bridge.stopRecording() }
    public var droppedRecordFrames: Int64 { bridge.droppedRecordFrames }

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
                    let d = Int(event.deck)
                    if decks.indices.contains(d) { decks[d].apply(event) }
                case PE_EVT_PEAK:
                    let d = Int(event.deck)
                    if d == -1 { mixer.master.updatePeak(event.f0) }
                    else if mixer.channels.indices.contains(d) { mixer.channels[d].updatePeak(event.f0) }
                case PE_EVT_END_OF_TRACK:
                    let d = Int(event.deck)
                    if decks.indices.contains(d) { decks[d].applyEndOfTrack(event) }
                default:
                    break
                }
            }
        }
    }
}

// MARK: - Deck (mirror ×2)

/// Grid grain the quantize snap targets (Phase 6b item 7). `.beat` reproduces
/// the prior behaviour (snap to the analyzed beat grid / quarter notes).
public enum QuantizeResolution: Sendable, CaseIterable {
    case eighthBeat, quarterBeat, halfBeat, beat, bar, fourBars

    /// Number of these grains per beat (values < 1 span multiple beats).
    public var beatFraction: Double {
        switch self {
        case .eighthBeat: return 0.125
        case .quarterBeat: return 0.25
        case .halfBeat: return 0.5
        case .beat: return 1
        case .bar: return 4
        case .fourBars: return 16
        }
    }
}

/// The four stem voices of a per-deck stem set (Phase 6b item 1).
public enum StemKind: String, Sendable, CaseIterable {
    case vocals, drums, bass, other
    public var index: Int {
        switch self {
        case .vocals: return 0
        case .drums: return 1
        case .bass: return 2
        case .other: return 3
        }
    }
}

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
        hotCueBankStore = Array(repeating: Array(repeating: nil, count: 8), count: Deck.hotCueBankCount)
        hotCueFadeIn = Array(repeating: 0, count: 8)
        hotCueBank = 0
        cueTime = nil
        nudgeRatio = 1
        isPlaying = false
        reverse = false
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
        if autoCue { applyAutoCue() }
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

    private func post(_ type: pe_cmd_type, i0: Int = 0, i1: Int = 0, i2: Int = 0, f0: Float = 0, f1: Float = 0) {
        var command = pe_command(type: type, deck: Int32(index), i0: Int32(truncatingIfNeeded: i0),
                                 i1: Int32(truncatingIfNeeded: i1), i2: Int32(truncatingIfNeeded: i2),
                                 f0: f0, f1: f1)
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

    // MARK: Integer-sample transport (Phase 6b item 6)

    private var sampleRate: Double { buffer?.format.sampleRate ?? 48_000 }

    /// Sample-exact seek. `quantized` snaps to the analysis grid first.
    /// Precision survives past ~5.8 min where the float-seconds path rounds.
    public func seek(toSample sample: Int64, quantized: Bool) {
        var target = max(0, sample)
        if quantized {
            let seconds = quantizedTime(Double(target) / sampleRate)
            target = Int64((seconds * sampleRate).rounded())
        }
        currentPlayhead = Double(target) / sampleRate
        shadowPlayhead = currentPlayhead
        post(PE_CMD_SEEK, i1: Int(target), i2: 1)
    }

    /// Sets the temporary cue to an exact sample.
    public func setCue(atSample sample: Int64) {
        let target = max(0, sample)
        cueTime = Double(target) / sampleRate
        post(PE_CMD_SET_CUE, i1: Int(target), i2: 1)
    }

    /// Sets a sample-addressed loop, half-open `[start, end)`.
    public func setLoop(startSample start: Int64, endSample end: Int64) {
        let lo = max(0, min(start, end))
        let hi = max(lo, max(start, end))
        setLocalLoop(start: Double(lo) / sampleRate, end: Double(hi) / sampleRate)
        post(PE_CMD_SET_LOOP, i0: 1, i1: Int(lo), i2: Int(hi), f0: -1)
    }

    /// Jumps a hot cue slot to an exact sample.
    public func triggerHotCue(_ slot: Int, atSample sample: Int64) {
        guard hotCueTimes.indices.contains(slot) else { return }
        let target = max(0, sample)
        hotCueTimes[slot] = Double(target) / sampleRate
        post(PE_CMD_HOTCUE_SET, i0: slot, i1: Int(target), i2: 1)
    }

    // MARK: Quantize grain (Phase 6b item 7)

    /// Grid resolution the cue / hot-cue / loop snap targets when `quantize` is on.
    public var quantizeResolution: QuantizeResolution = .beat

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
            bridge.setDeckKeylock(keyLock, index: index)
            updatePlaybackRate()
        }
    }
    /// Independent key change (Key Shift), in semitones.
    public var pitchSemitones: Double = 0 { didSet { updatePlaybackRate() } }

    // MARK: Key Sync / detected key (CDJ3000 parity C2)

    /// The analysed key of the loaded track, if any.
    public var detectedKey: KeyResult? { trackAnalysis?.key }

    /// The key the deck is currently *sounding* in — `detectedKey` transposed by
    /// the current Key Shift. Tempo changes are pitch-neutral under key-lock so
    /// they do not affect this; with key-lock off, varispeed does shift pitch but
    /// the CDJ likewise reports the nominal shifted key here.
    public var soundingKey: KeyResult? {
        detectedKey?.transposed(by: Int(pitchSemitones.rounded()))
    }

    /// Maximum shift Key Sync will apply, in semitones (CDJ default ±6 — a
    /// perfect-fourth/fifth is the farthest musically sensible pull).
    public var keySyncRange: Int = 6

    /// Shifts this deck's key (pitch only) to sit in `reference`'s detected key,
    /// shortest path, clamped to `keySyncRange`. Engages key-lock if it was off
    /// (Key Shift needs the time-pitch path). Returns the shift applied, or nil
    /// if either track has no analysed key. Mirrors the CDJ-3000 Key Sync button.
    @discardableResult
    public func keySync(to reference: Deck) -> Int? {
        guard let mine = detectedKey, let theirs = reference.detectedKey else { return nil }
        let shift = max(-keySyncRange, min(keySyncRange, mine.shortestShift(to: theirs)))
        if !keyLock { keyLock = true }
        pitchSemitones = Double(shift)
        return shift
    }

    /// Returns Key Shift / Key Sync to the track's native key.
    public func keyReset() { pitchSemitones = 0 }

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

    // MARK: Vinyl Speed Adjust (CDJ3000 parity C2)

    /// Seconds for playback to brake to a stop on pause / vinyl-touch (0 = the
    /// classic instant stop). The CDJ-3000 TOUCH/BRAKE knob.
    public var brakeTime: TimeInterval = 0 { didSet { publishVinylSpeed() } }
    /// Seconds for playback to spin back up to speed on play / release (0 =
    /// instant). The CDJ-3000 RELEASE/START knob.
    public var spinUpTime: TimeInterval = 0 { didSet { publishVinylSpeed() } }

    private func publishVinylSpeed() {
        post(PE_CMD_VINYL_SPEED,
             f0: Float(max(0, min(10, brakeTime))),
             f1: Float(max(0, min(10, spinUpTime))))
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

    // Hot cues (8 per bank)

    /// Number of hot-cue banks (rekordbox A/B/C/D → 8×4 effective cues).
    public static let hotCueBankCount = 4
    private var hotCueBankStore: [[TimeInterval?]] =
        Array(repeating: Array(repeating: nil, count: 8), count: Deck.hotCueBankCount)
    private var hotCueFadeIn: [TimeInterval] = Array(repeating: 0, count: 8)

    /// Active hot-cue bank (0…3). Switching banks re-points the engine's 8 hot
    /// cue slots (CDJ3000 parity C6).
    public var hotCueBank: Int = 0 {
        didSet {
            guard hotCueBank != oldValue,
                  (0..<Deck.hotCueBankCount).contains(hotCueBank) else {
                if !(0..<Deck.hotCueBankCount).contains(hotCueBank) { hotCueBank = oldValue }
                return
            }
            hotCueBankStore[oldValue] = hotCueTimes
            hotCueTimes = hotCueBankStore[hotCueBank]
            for slot in 0..<8 {
                if let t = hotCueTimes[slot] {
                    post(PE_CMD_HOTCUE_SET, i0: slot, f0: Float(t))
                } else {
                    post(PE_CMD_HOTCUE_DELETE, i0: slot)
                }
            }
        }
    }

    public func setHotCue(_ index: Int) { setHotCue(index, fadeIn: 0) }

    /// Set a hot cue, optionally with a fade-in applied when it is triggered
    /// (rekordbox fade-in cue point).
    public func setHotCue(_ index: Int, fadeIn: TimeInterval) {
        guard hotCueTimes.indices.contains(index) else { return }
        hotCueTimes[index] = quantizedTime(currentPlayhead)
        hotCueFadeIn[index] = max(0, fadeIn)
        post(PE_CMD_HOTCUE_SET, i0: index, f0: Float(hotCueTimes[index] ?? currentPlayhead))
    }
    public func jumpHotCue(_ index: Int) {
        guard hotCueTimes.indices.contains(index), let time = hotCueTimes[index] else { return }
        currentPlayhead = time
        post(PE_CMD_HOTCUE_JUMP, i0: index, f0: Float(hotCueFadeIn[index]))
    }
    public func deleteHotCue(_ index: Int) {
        guard hotCueTimes.indices.contains(index) else { return }
        hotCueTimes[index] = nil
        hotCueFadeIn[index] = 0
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

        let fraction = quantizeResolution.beatFraction
        // Sub-beat / multi-beat grain: derive the step from the analyzed grid
        // spacing (or the BPM) and snap to the nearest multiple of it.
        if fraction != 1 {
            guard trackBPM.isFinite, trackBPM > 0 else { return clamped }
            let beatLength = 60 / trackBPM
            let anchor = beatPositions.first ?? 0
            let step = beatLength * fraction
            guard step.isFinite, step > 0 else { return clamped }
            return max(0, min(duration, anchor + ((clamped - anchor) / step).rounded() * step))
        }

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
    /// Scale the active loop by an arbitrary factor (CDJ3000 parity C6 — LOOP
    /// CUT / ×4 and finer). `0.5` == `loopHalve`, `2` == `loopDouble`.
    public func loopResize(_ factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        resizeLocalLoop(by: factor)
        if let loopStartTime, let loopEndTime {
            publishLoop(start: loopStartTime, end: loopEndTime, active: isLoopActive)
        }
    }
    /// Emergency hold — instantly loop the last `beats` beats (CDJ3000 parity C6;
    /// an app calls this off a stream-underrun signal to avoid silence).
    public func emergencyHold(beats: Double = 4) { autoBeatLoop(beats: beats) }
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

        var target = syncTargetPosition(master: master, masterBPM: masterBPM)
        if barSync, let downbeats = trackAnalysis?.tempo.downbeatPositions, !downbeats.isEmpty {
            if let nearest = downbeats.min(by: { abs($0 - target) < abs($1 - target) }) {
                target = nearest
            }
        }
        post(PE_CMD_SYNC, f0: Float(target))
        bridge.publishSyncState(index: index)
    }

    fileprivate var effectiveBPM: Double { trackBPM * playbackRatio * nudgeRatio }

    /// Effective playback rate as a ratio of nominal (1.0 == nominal), including
    /// the tempo fader and any transient nudge. Phase 6a `deckRate(_:)`.
    public var effectiveRate: Double { playbackRatio * nudgeRatio }

    /// Explicitly disengages tempo-sync for this deck (Phase 6b item 2).
    public func unsync() {
        guard isSynced else { return }
        isSynced = false
        post(PE_CMD_UNSYNC)
        bridge.publishSyncState(index: index)
    }

    /// Engage sync, optionally aligning bars (downbeats) rather than beats.
    public func sync(barSync: Bool) {
        self.barSync = barSync
        sync()
    }
    private var barSync = false

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
                applyAutoCue()
            }
        }
    }
    /// Level (dBFS) the first sample must exceed for Auto Cue to place the first
    /// cue there — the CDJ AUTO CUE LEVEL. Analysis onsets take precedence.
    public var autoCueThresholdDB: Double = -60

    private func applyAutoCue() {
        // Prefer the analysed first onset / beat; fall back to a threshold scan.
        if let first = trackAnalysis?.tempo.beatPositions.first, first > 0 {
            cueTime = first
            post(PE_CMD_SET_CUE, f0: Float(first))
            return
        }
        guard let buffer else { cueTime = 0; post(PE_CMD_SET_CUE); return }
        let threshold = Float(pow(10.0, max(-96, min(0, autoCueThresholdDB)) / 20))
        let channelCount = min(buffer.channelCount, 2)
        var cueSample = 0
        scan: for f in 0..<buffer.frameCount {
            for c in 0..<channelCount where abs(buffer.channel(c)[f]) > threshold {
                cueSample = f
                break scan
            }
        }
        cueTime = Double(cueSample) / buffer.format.sampleRate
        post(PE_CMD_SET_CUE, i1: cueSample, i2: 1)   // integer-sample cue
    }
    public var slip: Bool = false {
        didSet { post(PE_CMD_SET_SLIP, f0: slip ? 1 : 0) }
    }

    // MARK: Reverse / Slip Reverse (CDJ3000 parity C2)

    /// Latching reverse playback (the CDJ-3000 REV button). Varispeed only —
    /// pitch inverts with the direction, as on hardware.
    public var reverse: Bool = false {
        didSet {
            guard reverse != oldValue else { return }
            post(PE_CMD_SET_REVERSE, i0: reverse ? 1 : 0)
        }
    }

    private var slipReverseRestoreSlip = false

    /// Momentary Slip Reverse: play backwards while held with the slip shadow
    /// advancing underneath; `slipReverseRelease()` jumps forward to where the
    /// track would have been.
    public func slipReversePress() {
        slipReverseRestoreSlip = slip
        if !slip { slip = true }
        reverse = true
    }

    public func slipReverseRelease() {
        reverse = false
        if !slipReverseRestoreSlip { slip = false }
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

    // MARK: Per-deck stems (Phase 6b item 1)

    private var stemBuffers: [PCMBuffer?] = Array(repeating: nil, count: 4)
    /// `true` while a 4-voice stem set drives this deck's source signal.
    public private(set) var stemsArmed = false

    /// Arms a per-deck 4-voice stem overlay. The voices share this deck's
    /// playhead and grid; the summed, gain-weighted voices replace the single
    /// full-mix reader until `disarmStems()`. A deck with no stems armed renders
    /// bit-for-bit identically to before.
    public func armStems(_ voices: [StemKind: PCMBuffer]) {
        for kind in StemKind.allCases {
            guard let pcm = voices[kind] else {
                stemBuffers[kind.index] = nil
                pe_deck_set_stem_buffer(bridge.handle, Int32(index), Int32(kind.index), nil, 0, 0)
                continue
            }
            stemBuffers[kind.index] = pcm
            pcm.withUnsafeChannels { channels, frames in
                channels.withMemoryRebound(to: UnsafePointer<Float>?.self, capacity: pcm.channelCount) { pointers in
                    pe_deck_set_stem_buffer(bridge.handle, Int32(index), Int32(kind.index),
                                            UnsafePointer(pointers), Int32(pcm.channelCount), Int64(frames))
                }
            }
        }
        stemsArmed = true
        // pe_deck_set_stem_buffer already armed the overlay synchronously; no
        // deferred PE_CMD_STEM_ARM (it would fight a subsequent disarm still in
        // the command ring).
    }

    public func disarmStems() {
        stemsArmed = false
        for i in stemBuffers.indices { stemBuffers[i] = nil }
        pe_deck_clear_stems(bridge.handle, Int32(index))
    }

    public func setStemGain(_ kind: StemKind, _ gain: Double) {
        post(PE_CMD_STEM_GAIN, i0: kind.index, f0: Float(max(0, min(4, gain))))
    }
    public func setStemMute(_ kind: StemKind, _ muted: Bool) {
        post(PE_CMD_STEM_MUTE, i0: kind.index, i1: muted ? 1 : 0)
    }
    public func setStemSolo(_ kind: StemKind, _ soloed: Bool) {
        post(PE_CMD_STEM_SOLO, i0: kind.index, i1: soloed ? 1 : 0)
    }

    // MARK: Per-deck beat echo (Phase 6b item 3)

    private var echoEnabled = false
    /// Configures / toggles this deck's beat echo. The delay period tracks the
    /// deck's (synced) effective BPM. Disabling with a live tail lets the
    /// repeats decay rather than cutting them.
    public func setEcho(enabled: Bool, beats: Double = 1, depth: Double = 0.5, feedback: Double = 0.4) {
        echoEnabled = enabled
        let fb = Int(max(0, min(0.95, feedback)) * 1000)
        post(PE_CMD_ECHO_SET, i0: enabled ? 1 : 0, i1: fb, i2: 1,
             f0: Float(beats > 0 ? beats : 1), f1: Float(max(0, min(1, depth))))
    }
    public func setEchoEnabled(_ on: Bool) { setEcho(enabled: on) }

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
    /// All mixer channels (2…4). `channelA`/`channelB` alias `channels[0]`/`[1]`.
    public let channels: [Channel]
    public var channelA: Channel { channels[0] }
    public var channelB: Channel { channels[1] }
    /// Third / fourth channels — present when the engine was created with
    /// `deckCount >= 3` / `>= 4` (the default). Accessing them on a 2-deck
    /// engine traps.
    public var channelC: Channel { channels[2] }
    public var channelD: Channel { channels[3] }
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
        channels = (0..<bridge.deckCount).map { Channel(bridge: bridge, index: $0) }
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

    // MARK: Insert / send-return seam (CDJ3000 parity C3)

    private var inserts: [InsertPoint: RealtimeInsert] = [:]

    /// Installs (or, with `nil`, removes) a realtime effect insert at `point`.
    /// The mixer keeps a strong reference while installed. Set inserts before
    /// starting audio; the callback runs on the render thread and must be
    /// realtime-safe (see `RealtimeInsert`).
    public func setInsert(_ insert: RealtimeInsert?, at point: InsertPoint) {
        inserts[point] = insert
        if let insert {
            // `inserts` holds the strong reference; the engine gets an
            // unretained opaque pointer to the same object.
            let ptr = Unmanaged.passUnretained(insert as AnyObject).toOpaque()
            pe_set_insert(bridge.handle, point.raw, peInsertTrampoline, ptr)
        } else {
            pe_set_insert(bridge.handle, point.raw, nil, nil)
        }
    }
}

public enum ColorFX: Sendable, CaseIterable, Equatable { case filter, space, dubEcho, sweep, noise, crush, pitch }

public enum XFAssign: Sendable { case a, b, thru }

/// Channel / crossfader fader-taper shapes (CDJ3000 parity C3 — the DJM
/// CH FADER CURVE and CROSSFADER CURVE switches).
public enum FaderCurve: Sendable, CaseIterable {
    case linear    // gain == position
    case smooth    // gentle S — more travel near the top
    case sharp     // fast onset — near full level early in the throw

    /// Maps a 0…1 fader position to a 0…1 gain.
    public func gain(_ position: Double) -> Double {
        let p = max(0, min(1, position))
        switch self {
        case .linear: return p
        case .smooth: return p * p * (3 - 2 * p)          // smoothstep
        case .sharp:  return p <= 0 ? 0 : pow(p, 0.35)    // steep near the bottom
        }
    }
}

@MainActor
public final class Channel {
    private let bridge: EngineBridge
    private let index: Int
    public var trim: Double = 0.5 { didSet { publishControl() } } // gain
    /// Fader taper (CDJ3000 parity C3). `.linear` is the default and matches
    /// pre-C3 behaviour exactly.
    public var faderCurve: FaderCurve = .linear { didSet { publishControl() } }
    public var eqLow: Double = 0 { didSet { publishControl() } } // dB, -inf(kill)..+6
    public var eqMid: Double = 0 { didSet { publishControl() } }
    public var eqHigh: Double = 0 { didSet { publishControl() } }
    public var colorFX: ColorFX = .filter { didSet { publishControl() } }
    public var colorAmount: Double = 0 { didSet { publishControl() } } // -1..+1 (center = off)
    /// Sound Color FX PARAMETER knob (CDJ3000 C4) — 0…1 depth / resonance.
    /// 0.5 is neutral: a default channel is byte-identical to pre-C4.
    public var colorParameter: Double = 0.5 { didSet { publishControl() } }
    /// DJM-A9 "Center Lock" — once the knob leaves centre it cannot cross to the
    /// other side (no accidental LPF↔HPF flip) until this is turned off.
    public var colorFXCenterLock: Bool = false {
        didSet { if !colorFXCenterLock { colorLockedSide = 0 }; publishControl() }
    }
    private var colorLockedSide: Double = 0   // -1 / 0 / +1
    public var fader: Double = 1 { didSet { publishControl() } } // 0..1
    public var cuePFL: Bool = false { didSet { publishControl() } } // headphone pre-listen
    public var faderStart: Bool = false { didSet { publishControl() } }
    public var crossfaderAssign: XFAssign = .thru { didSet { publishControl() } }
    /// Latest peak meter (0..1), updated from the RT event stream.
    public private(set) var peakMeter: Float = 0
    /// Peak-hold reading (0..1): follows `peakMeter` up instantly, decays slowly
    /// (CDJ3000 parity C5 — the segmented meter's hold dot).
    public private(set) var peakHold: Float = 0
    fileprivate func updatePeak(_ value: Float) {
        let v = value.isFinite ? max(0, min(1, value)) : 0
        peakMeter = v
        peakHold = v >= peakHold ? v : max(v, peakHold * 0.92)
    }
    fileprivate init(bridge: EngineBridge, index: Int) {
        self.bridge = bridge
        self.index = index
    }

    private func publishControl() {
        let gain = Float(max(0, trim))
        let channelFader = Float(faderCurve.gain(max(0, min(1, fader))))
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
        var colorAmt = self.colorAmount.isFinite ? max(-1, min(1, self.colorAmount)) : 0
        if colorFXCenterLock {
            if colorLockedSide == 0, colorAmt != 0 { colorLockedSide = colorAmt < 0 ? -1 : 1 }
            if colorLockedSide > 0 { colorAmt = max(0, colorAmt) }
            if colorLockedSide < 0 { colorAmt = min(0, colorAmt) }
        }
        let colorAmount = Float(colorAmt)
        let colorKind = Float(ColorFX.allCases.firstIndex(of: colorFX) ?? 0)
        let colorParam = Float(colorParameter.isFinite ? max(0, min(1, colorParameter)) : 0.5)
        peSet(&bridge.control.color_param, index, colorParam)
        peSet(&bridge.control.trim, index, gain)
        peSet(&bridge.control.fader, index, channelFader)
        peSet(&bridge.control.cue_pfl, index, pfl)
        peSet(&bridge.control.xfade_assign, index, assignment)
        peSet(&bridge.control.fader_start, index, start)
        peSet(&bridge.control.eq_low, index, low)
        peSet(&bridge.control.eq_mid, index, mid)
        peSet(&bridge.control.eq_high, index, high)
        peSet(&bridge.control.color_amount, index, colorAmount)
        peSet(&bridge.control.color_kind, index, colorKind)
        bridge.publishControl()
    }
}

@MainActor
public final class BeatFXUnit {
    public enum Kind: Sendable, CaseIterable, Equatable {
        case echo, echoOut, reverb, delay, multiTapDelay, flanger, phaser,
             trans, roll, spiral, pitch, lowCutEcho, vinylBrake, helix,
             // CDJ3000 parity C4 — DJM-A9 / 900NXS2 additions
             pingPong, mobius, tripletFilter, tripletRoll, enigma, shimmer
    }
    /// FX-input band limit (CDJ3000 C4 — the DJM FX FREQUENCY switch).
    public enum Band: Sendable, CaseIterable { case all, low, mid, high }
    public enum Assign: Sendable { case chA, chB, both, master }
    private let bridge: EngineBridge
    public var kind: Kind = .echo { didSet { publishControl() } }
    public var beats: Double = 0.5 { didSet { publishControl() } } // time division
    public var depth: Double = 0.5 { didSet { publishControl() } } // wet/level
    public var assign: Assign = .chA { didSet { publishControl() } }
    public var isOn: Bool = false { didSet { publishControl() } }
    /// X-Pad sweep of the primary parameter (0…1). `nil` = not touched, `beats`
    /// governs. Touching it overrides `beats` with an exponential 1/16…4 sweep.
    public var xPad: Double? = nil { didSet { publishControl() } }
    /// Band-limit the FX send (dry path untouched).
    public var band: Band = .all { didSet { publishControl() } }

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
        bridge.control.beatfx_xpad = xPad.map { Float(max(0, min(1, $0))) } ?? -1
        bridge.control.beatfx_band = switch band {
        case .all: 0
        case .low: 1
        case .mid: 2
        case .high: 3
        }
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
    /// `false` bypasses the master brickwall limiter entirely (Phase 6b item 8),
    /// so `WorkspaceEngine.limiterCeiling` can be represented as `nil`.
    public var limiterEnabled: Bool = true { didSet { publishControl() } }

    // MARK: Master isolator (CDJ3000 parity C3 — the DJM MASTER ISOLATOR)
    /// 3-band EQ/kill on the master bus, post-fader / pre-limiter. dB;
    /// `-.infinity` kills the band; `0` (the default) is bit-transparent.
    public var isolatorLow: Double = 0 { didSet { publishControl() } }
    public var isolatorMid: Double = 0 { didSet { publishControl() } }
    public var isolatorHigh: Double = 0 { didSet { publishControl() } }

    // MARK: Booth output (CDJ3000 parity C3 — the DJM BOOTH bus)
    /// Independent booth-output level (0…1). Fed from the final master; render
    /// it with `HeadlessDJEngine.renderBooth` / `pe_render_booth`.
    public var boothLevel: Double = 0.8 { didSet { publishControl() } }
    /// Booth 3-band EQ (dB; the A9 booth is 2-band — leave `boothEqMid` at 0).
    public var boothEqLow: Double = 0 { didSet { publishControl() } }
    public var boothEqMid: Double = 0 { didSet { publishControl() } }
    public var boothEqHigh: Double = 0 { didSet { publishControl() } }

    // MARK: Master reverb send (CDJ3000 parity C7 — 8-line FDN reverb)
    /// Wet amount of the master-bus reverb (0…1). 0 (default) is fully dry and
    /// bit-transparent. Feed the DJM Reverb / SHIMMER Beat FX into this.
    public var reverbSend: Double = 0 { didSet { publishControl() } }
    /// Room size (0…1), tail length (0…1), high-frequency damping (0…1).
    public var reverbSize: Double = 0.6 { didSet { publishControl() } }
    public var reverbDecay: Double = 0.6 { didSet { publishControl() } }
    public var reverbDamp: Double = 0.5 { didSet { publishControl() } }

    /// Latest master peak (0..1).
    public private(set) var peakMeter: Float = 0
    /// Peak-hold reading (0..1) — instant attack, slow decay (CDJ3000 C5).
    public private(set) var peakHold: Float = 0
    fileprivate func updatePeak(_ value: Float) {
        let v = value.isFinite ? max(0, min(1, value)) : 0
        peakMeter = v
        peakHold = v >= peakHold ? v : max(v, peakHold * 0.92)
    }
    fileprivate init(bridge: EngineBridge) { self.bridge = bridge }

    private func publishControl() {
        bridge.control.master_level = Float(max(0, min(1, level)))
        bridge.control.limiter_ceiling_db = Float(limiterCeilingDB.isFinite ? limiterCeilingDB : -0.3)
        bridge.control.limiter_enabled = limiterEnabled ? 1 : 0
        bridge.control.master_eq_low = Float(isolatorLow.isNaN ? 0 : isolatorLow)
        bridge.control.master_eq_mid = Float(isolatorMid.isNaN ? 0 : isolatorMid)
        bridge.control.master_eq_high = Float(isolatorHigh.isNaN ? 0 : isolatorHigh)
        bridge.control.booth_level = Float(boothLevel.isFinite ? max(0, min(1, boothLevel)) : 0.8)
        bridge.control.booth_eq_low = Float(boothEqLow.isNaN ? 0 : boothEqLow)
        bridge.control.booth_eq_mid = Float(boothEqMid.isNaN ? 0 : boothEqMid)
        bridge.control.booth_eq_high = Float(boothEqHigh.isNaN ? 0 : boothEqHigh)
        bridge.control.master_reverb_send = Float(reverbSend.isFinite ? max(0, min(1, reverbSend)) : 0)
        bridge.control.master_reverb_size = Float(reverbSize.isFinite ? max(0, min(1, reverbSize)) : 0.6)
        bridge.control.master_reverb_decay = Float(reverbDecay.isFinite ? max(0, min(1, reverbDecay)) : 0.6)
        bridge.control.master_reverb_damp = Float(reverbDamp.isFinite ? max(0, min(1, reverbDamp)) : 0.5)
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

    // MARK: Mic strip (CDJ3000 parity C5 — the DJM mic section)
    /// 2-band mic EQ (dB; 0 = flat).
    public var eqLow: Double = 0 { didSet { publishLevel() } }
    public var eqHigh: Double = 0 { didSet { publishLevel() } }
    /// Auto-duck the music while the mic is live (DJM TALKOVER).
    public var talkover: Bool = false { didSet { publishLevel() } }
    /// Attenuation applied to the music under talkover (dB, negative).
    public var talkoverDepthDB: Double = -14 { didSet { publishLevel() } }
    /// Mic block-RMS above which talkover engages.
    public var talkoverThreshold: Double = 0.02 { didSet { publishLevel() } }
    /// Route the mic through the Beat FX (takes effect for the "all channels" /
    /// "master" FX assigns).
    public var routeToFX: Bool = false { didSet { publishLevel() } }

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
        bridge.control.mic_eq_low = Float(eqLow.isNaN ? 0 : eqLow)
        bridge.control.mic_eq_high = Float(eqHigh.isNaN ? 0 : eqHigh)
        bridge.control.mic_talkover_on = talkover ? 1 : 0
        bridge.control.mic_talkover_depth_db = Float(talkoverDepthDB.isFinite ? min(0, talkoverDepthDB) : -14)
        bridge.control.mic_talkover_threshold = Float(talkoverThreshold.isFinite && talkoverThreshold >= 0 ? talkoverThreshold : 0.02)
        bridge.control.mic_fx_on = routeToFX ? 1 : 0
        bridge.publishControl()
    }
}

/// Headphone cue routing model (Phase 6b item 5, SPEC §44.2a).
public enum CueMode: String, Sendable, CaseIterable {
    case off, splitOutput, cueInPlace, multichannel
    fileprivate var raw: Float {
        switch self {
        case .off: return 0
        case .splitOutput: return 1
        case .cueInPlace: return 2
        case .multichannel: return 3
        }
    }
}

@MainActor
public final class Monitoring {
    private let bridge: EngineBridge
    public var masterCue: Bool = false { didSet { publishControl() } }
    public var cueMasterMix: Double = 0.5 { didSet { publishControl() } } // 0 = cue only, 1 = master only
    public var headphoneLevel: Double = 0.7 { didSet { publishControl() } }
    /// `.splitOutput` sums master→mono-left, cue→mono-right in the monitor bus.
    /// `.off` keeps the monitor render path bit-exact (offline harness relies on it).
    public var cueMode: CueMode = .off { didSet { publishControl() } }
    /// Split Cue (CDJ3000 parity C5): cue and master to separate ears. Convenience
    /// over `cueMode` — setting it toggles `.splitOutput` / `.off`.
    public var splitCue: Bool {
        get { cueMode == .splitOutput }
        set { cueMode = newValue ? .splitOutput : .off }
    }
    fileprivate init(bridge: EngineBridge) { self.bridge = bridge }

    private func publishControl() {
        bridge.control.master_cue = masterCue ? 1 : 0
        bridge.control.cue_master_mix = Float(max(0, min(1, cueMasterMix)))
        bridge.control.headphone_level = Float(max(0, min(1, headphoneLevel)))
        bridge.control.cue_mode = cueMode.raw
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

    /// Frames the render tap had to drop because the encoder fell behind
    /// (Phase 6b item 4). Set by the engine on `stopRecording` / interruption.
    public internal(set) var droppedFrames: Int64 = 0

    public func start() {
        chunks.removeAll(keepingCapacity: true)
        captureFormat = nil
        droppedFrames = 0
        isRecording = true
    }

    /// Finalizes everything captured so far into `url` as a complete, playable
    /// file and keeps recording into a fresh segment (Phase 6b item 4 —
    /// interruption flush, NFR-REL-2). Returns nil if nothing was captured.
    @discardableResult
    public func flushSegment(to url: URL) throws -> URL? {
        guard isRecording, !chunks.isEmpty else { return nil }
        try encode(chunks, to: url)
        chunks.removeAll(keepingCapacity: true)
        return url
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
        try encode(chunks, to: url)
    }

    private func encode(_ blocks: [PCMBuffer], to destination: URL) throws {
        let format = captureFormat ?? blocks.first?.format ?? AudioFormat(sampleRate: 48_000, channelCount: 2)
        let frameCount = blocks.reduce(0) { $0 + $1.frameCount }
        let output = PCMBuffer(format: format, capacity: frameCount)
        var offset = 0
        for chunk in blocks {
            for channel in 0..<format.channelCount {
                for frame in 0..<chunk.frameCount {
                    output.channel(channel)[offset + frame] = chunk.channel(channel)[frame]
                }
            }
            offset += chunk.frameCount
        }
        let writer = try AudioFileWriter(url: destination, format: format, codec: codec)
        try writer.write(output)
        try writer.finish()
    }
}
