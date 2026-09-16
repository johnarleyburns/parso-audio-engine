//
//  ScratchPatterns.swift
//  Reusable turntablism patterns for control-side pad and gesture interfaces.
//

import Foundation

/// The named turntablism technique represented by a scratch pattern.
public enum ScratchTechnique: String, CaseIterable, Hashable, Sendable {
    case baby
    case scribble
    case drag
    case forward
    case backward
    case chirp
    case flare
    case transform
    case crab
    case tear
    case twiddle
    case boomerang
}

/// One timestamped control event in a reusable scratch routine.
///
/// `deltaSamples` is a source-deck movement, suitable for passing to
/// `Deck.jogMoved(deltaSamples:)`. `faderOpen` is the desired channel-fader
/// state at that event. A zero-delta event is intentionally allowed so a
/// routine can express a fader click without moving the record. The host owns
/// the clock and applies events on the main actor; no event scheduling or
/// allocation is performed by the real-time renderer.
public struct ScratchPatternEvent: Equatable, Sendable {
    /// Elapsed time from the start of the routine, in seconds.
    public let offset: TimeInterval
    /// Signed source-deck movement in sample frames.
    public let deltaSamples: Double
    /// Whether the channel fader should be open at this event.
    public let faderOpen: Bool
    /// Optional UI-facing description for a pad editor or guided review.
    public let label: String

    public init(
        offset: TimeInterval,
        deltaSamples: Double,
        faderOpen: Bool = true,
        label: String = ""
    ) {
        precondition(offset.isFinite && offset >= 0, "Scratch event offset must be finite and non-negative")
        precondition(deltaSamples.isFinite, "Scratch event delta must be finite")
        self.offset = offset
        self.deltaSamples = deltaSamples
        self.faderOpen = faderOpen
        self.label = label
    }
}

/// A finite, editable timeline of record and fader movements.
public struct ScratchPattern: Equatable, Sendable {
    public let name: String
    public let technique: ScratchTechnique
    public let events: [ScratchPatternEvent]

    public init(
        name: String,
        technique: ScratchTechnique,
        events: [ScratchPatternEvent]
    ) {
        precondition(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                     "Scratch pattern name cannot be empty")
        for pair in zip(events, events.dropFirst()) {
            precondition(pair.0.offset <= pair.1.offset,
                         "Scratch pattern events must be in offset order")
        }
        self.name = name
        self.technique = technique
        self.events = events
    }

    /// The time at which the final event is applied, or zero for an empty pattern.
    public var duration: TimeInterval { events.last?.offset ?? 0 }

    /// The complete built-in catalog, suitable for a new Scratch Bank editor.
    public static let catalog: [ScratchPattern] = [
        .baby,
        .scribble,
        .drag,
        .forward,
        .backward,
        .chirp,
        .flare,
        .transform,
        .crab,
        .tear,
        .twiddle,
        .boomerang
    ]

    public static let baby = ScratchPattern(
        name: "Baby Scratch", technique: .baby,
        events: [
            event(0.00, 1_600, "forward"), event(0.14, -1_600, "backward"),
            event(0.28, 1_600, "forward"), event(0.42, -1_600, "backward")
        ])

    public static let scribble = ScratchPattern(
        name: "Scribble", technique: .scribble,
        events: [
            event(0.00, 420, "tight forward"), event(0.035, -420, "tight backward"),
            event(0.070, 420, "tight forward"), event(0.105, -420, "tight backward"),
            event(0.140, 420, "tight forward"), event(0.175, -420, "tight backward"),
            event(0.210, 420, "tight forward"), event(0.245, -420, "tight backward")
        ])

    public static let drag = ScratchPattern(
        name: "Drag", technique: .drag,
        events: [event(0.00, 2_400, "slow forward drag"), event(0.60, -900, "release")])

    public static let forward = ScratchPattern(
        name: "Forward", technique: .forward,
        events: [event(0.00, 2_000, "forward stroke"), event(0.16, 0, "cut")])

    public static let backward = ScratchPattern(
        name: "Backward", technique: .backward,
        events: [event(0.00, -2_000, "backward stroke"), event(0.16, 0, "cut")])

    public static let chirp = ScratchPattern(
        name: "Chirp", technique: .chirp,
        events: [
            event(0.00, 2_000, "forward"), event(0.12, 0, "close fader", open: false),
            event(0.20, -1_650, "backward"), event(0.32, 0, "open fader")
        ])

    public static let flare = ScratchPattern(
        name: "Flare", technique: .flare,
        events: [
            event(0.00, 1_200, "stroke"), event(0.07, 0, "click 1", open: false),
            event(0.10, 500, "stroke"), event(0.17, 0, "click 2", open: false),
            event(0.20, 500, "finish")
        ])

    public static let transform = ScratchPattern(
        name: "Transform", technique: .transform,
        events: [
            event(0.00, 2_600, "slow stroke"), event(0.06, 0, "tap", open: false),
            event(0.12, 0, "release"), event(0.18, 0, "tap", open: false),
            event(0.24, 0, "release"), event(0.30, 0, "tap", open: false),
            event(0.36, 0, "release")
        ])

    public static let crab = ScratchPattern(
        name: "Crab", technique: .crab,
        events: [
            event(0.00, 1_800, "stroke"), event(0.035, 0, "finger 1", open: false),
            event(0.070, 0, "finger 2"), event(0.105, 0, "finger 3", open: false),
            event(0.140, 0, "finger 4")
        ])

    public static let tear = ScratchPattern(
        name: "Tear", technique: .tear,
        events: [
            event(0.00, 1_100, "first half"), event(0.13, 700, "pause / second half"),
            event(0.28, -1_100, "return first half"), event(0.41, -700, "return second half")
        ])

    public static let twiddle = ScratchPattern(
        name: "Twiddle", technique: .twiddle,
        events: [
            event(0.00, 1_500, "stroke"), event(0.06, 0, "index click", open: false),
            event(0.10, 0, "middle click"), event(0.16, -1_500, "return")
        ])

    public static let boomerang = ScratchPattern(
        name: "Boomerang", technique: .boomerang,
        events: [
            event(0.00, 1_000, "forward 1"), event(0.08, 0, "click", open: false),
            event(0.13, 850, "forward 2"), event(0.21, 0, "click", open: false),
            event(0.26, -850, "backward 1"), event(0.34, 0, "click", open: false),
            event(0.39, -1_000, "backward 2")
        ])

    private static func event(
        _ offset: TimeInterval,
        _ deltaSamples: Double,
        _ label: String,
        open: Bool = true
    ) -> ScratchPatternEvent {
        ScratchPatternEvent(
            offset: offset,
            deltaSamples: deltaSamples,
            faderOpen: open,
            label: label
        )
    }
}

/// Main-actor-owned eight-pad Scratch Bank.
///
/// The bank stores patterns but does not run a timer. A UI/display-link layer
/// obtains a cursor with `cursor(for:)`, advances it using elapsed time, and
/// applies the returned events to a deck and its channel fader. Keeping the
/// clock in the host makes pad triggering deterministic and avoids putting
/// Swift scheduling or allocations anywhere near the audio callback.
@MainActor
public final class ScratchBank {
    public static let slotCount = 8

    public private(set) var slots: [ScratchPattern?]
    private var players: [ObjectIdentifier: ScratchPatternPlayer] = [:]

    public init() {
        slots = Array(repeating: nil, count: Self.slotCount)
    }

    /// Assigns a pattern to a pad. Slots use the same zero-based indexing as
    /// `Deck.padPress(_:)`, so valid values are 0…7.
    @discardableResult
    public func assign(_ pattern: ScratchPattern, to slot: Int) -> Bool {
        guard slots.indices.contains(slot) else { return false }
        slots[slot] = pattern
        return true
    }

    public func pattern(at slot: Int) -> ScratchPattern? {
        guard slots.indices.contains(slot) else { return nil }
        return slots[slot]
    }

    @discardableResult
    public func clear(slot: Int) -> Bool {
        guard slots.indices.contains(slot) else { return false }
        slots[slot] = nil
        return true
    }

    public func cursor(for slot: Int) -> ScratchPatternCursor? {
        guard let pattern = pattern(at: slot) else { return nil }
        return ScratchPatternCursor(pattern: pattern)
    }

    /// Starts a stored pattern on a deck and its corresponding channel.
    ///
    /// The first event is applied immediately. Subsequent events are advanced
    /// by `DJEngine.tickAutomation(elapsed:)` or by `HeadlessDJEngine.render`.
    /// Triggering an occupied deck cancels its previous routine first.
    @discardableResult
    public func trigger(
        _ slot: Int,
        on deck: Deck,
        channel: Channel,
        looping: Bool = false
    ) -> Bool {
        guard let pattern = pattern(at: slot), !pattern.events.isEmpty else { return false }
        stop(on: deck)
        let player = ScratchPatternPlayer(deck: deck, channel: channel)
        players[ObjectIdentifier(deck)] = player
        player.start(pattern: pattern, looping: looping)
        if !player.isActive { players[ObjectIdentifier(deck)] = nil }
        return player.isActive
    }

    /// Stops the active routine on a deck and restores its pre-pattern fader.
    public func stop(on deck: Deck) {
        let id = ObjectIdentifier(deck)
        players.removeValue(forKey: id)?.stop()
    }

    /// Stops every active routine and restores all affected channel faders.
    public func stopAll() {
        let activePlayers = Array(players.values)
        players.removeAll(keepingCapacity: true)
        activePlayers.forEach { $0.stop() }
    }

    public func isPlaying(on deck: Deck) -> Bool {
        players[ObjectIdentifier(deck)]?.isActive == true
    }

    /// Advances all active routines from the host/control clock.
    internal func advance(elapsed: TimeInterval) {
        guard elapsed.isFinite, elapsed >= 0 else { return }
        var finishedIDs: [ObjectIdentifier] = []
        for (id, player) in players {
            player.advance(elapsed: elapsed)
            if !player.isActive { finishedIDs.append(id) }
        }
        for id in finishedIDs { players[id] = nil }
    }
}

/// Control-side Scratch Bank playback for one deck/channel pair.
///
/// This object only posts the same `Deck` jog commands and `Channel` fader
/// controls used by a human gesture. It never renders audio, sleeps, or owns
/// a timer. That keeps pattern playback deterministic in tests and lets a
/// phone/iPad display link provide the clock without affecting the audio
/// callback.
@MainActor
public final class ScratchPatternPlayer {
    public private(set) var isActive = false
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var pattern: ScratchPattern?
    public private(set) var looping = false

    private let deck: Deck
    private let channel: Channel
    private var cursor: ScratchPatternCursor?
    private var originalFader: Double = 1
    private var ownsJogTouch = false

    fileprivate init(deck: Deck, channel: Channel) {
        self.deck = deck
        self.channel = channel
    }

    fileprivate func start(pattern: ScratchPattern, looping: Bool) {
        stop()
        guard !pattern.events.isEmpty else { return }
        self.pattern = pattern
        self.cursor = ScratchPatternCursor(pattern: pattern)
        self.looping = looping
        self.elapsed = 0
        self.originalFader = channel.fader
        deck.jogTouchBegan()
        ownsJogTouch = true
        isActive = true
        advance(elapsed: 0)
    }

    /// Applies every event that became due during `elapsed` seconds.
    fileprivate func advance(elapsed delta: TimeInterval) {
        guard isActive, delta.isFinite, delta >= 0, var cursor, let pattern else { return }
        let duration = max(pattern.duration, 0.001)
        self.elapsed += delta

        while isActive {
            for event in cursor.advance(to: self.elapsed) {
                channel.fader = event.faderOpen ? 1 : 0
                deck.jogMoved(deltaSamples: event.deltaSamples)
            }
            if !cursor.isFinished { break }
            guard looping else {
                self.cursor = cursor
                finish()
                return
            }
            self.elapsed -= duration
            cursor.reset()
        }
        self.cursor = cursor
    }

    fileprivate func stop() {
        guard isActive else { return }
        finish()
    }

    private func finish() {
        if ownsJogTouch {
            deck.jogTouchEnded()
            ownsJogTouch = false
        }
        channel.fader = originalFader
        isActive = false
        looping = false
    }
}

/// Deterministic host-side cursor for driving a pattern timeline.
public struct ScratchPatternCursor: Sendable {
    public let pattern: ScratchPattern
    public private(set) var nextEventIndex: Int = 0

    public init(pattern: ScratchPattern) {
        self.pattern = pattern
    }

    public var isFinished: Bool { nextEventIndex >= pattern.events.count }

    /// Returns each event whose offset is at or before `elapsed` exactly once.
    /// Calling with an earlier time leaves the cursor unchanged.
    public mutating func advance(to elapsed: TimeInterval) -> [ScratchPatternEvent] {
        guard elapsed.isFinite, elapsed >= 0 else { return [] }
        var end = nextEventIndex
        while end < pattern.events.count, pattern.events[end].offset <= elapsed {
            end += 1
        }
        guard end > nextEventIndex else { return [] }
        let result = Array(pattern.events[nextEventIndex..<end])
        nextEventIndex = end
        return result
    }

    public mutating func reset() {
        nextEventIndex = 0
    }
}
