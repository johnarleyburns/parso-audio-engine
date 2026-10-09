//
//  MixEngine.swift
//  Swift control surface over CParsoMix: a stereo two-deck player whose
//  blends (bass swap on a downbeat, or a phrase cut) are evaluated per sample
//  on the render thread. See Sources/CParsoMix/include/parso_mix.h.
//

import Foundation
import ParsoAudioCore
import CParsoMix

public enum MixDeck: Int, Sendable, CaseIterable {
    case a = 0
    case b = 1

    public var other: MixDeck { self == .a ? .b : .a }
}

public enum MixDeckState: Int32, Sendable {
    case idle = 0, armed = 1, playing = 2, finished = 3
}

public enum MixEngineError: Error, Sendable, Equatable {
    case creationFailed
    case sampleRateMismatch(expected: Double, actual: Double)
    case deckBusy(MixDeck)
    case invalidArgument
}

/// The C engine handle. Invariant: control calls come from the owning
/// `MixEngine`'s actor; the render thread only calls `pm_render`, which the C
/// core makes safe against concurrent control calls (atomics, deck hand-off).
public struct MixRenderHandle: @unchecked Sendable {
    fileprivate let raw: OpaquePointer

    /// Real-time safe: no allocation, locks or Swift runtime beyond the call.
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        pm_render(raw, left, right, Int32(frames))
    }
}

public extension MixEngine {
    /// The whole buffer at `tempo`, exactly as a deck plays it (keylocked
    /// stretch, no crossover): the incoming track as it will sound, for analysis.
    nonisolated static func renderTempo(_ buffer: PCMBuffer, tempo: Double) -> PCMBuffer? {
        let outFrames = Int((Double(buffer.frameCount) / tempo).rounded(.down))
        guard outFrames > 0 else { return nil }
        let out = PCMBuffer(format: AudioFormat(sampleRate: buffer.format.sampleRate, channelCount: 2), capacity: outFrames)
        let ok: Int32 = buffer.withUnsafeChannels { inCh, frames in
            out.withUnsafeChannels { outCh, _ in
                pm_render_tempo(buffer.format.sampleRate, inCh[0], inCh[buffer.channelCount > 1 ? 1 : 0], Int64(frames),
                                tempo, outCh[0], outCh[1], Int64(outFrames))
            }
        }
        return ok == 0 ? out : nil
    }
}

@MainActor
public final class MixEngine {
    public let sampleRate: Double
    public let maxFramesPerRender: Int
    public let handle: MixRenderHandle
    /// PCM each deck plays; kept alive here because the C core borrows it.
    private var loaded: [MixDeck: PCMBuffer] = [:]

    public init(sampleRate: Double, maxFramesPerRender: Int = 512) throws {
        guard let raw = pm_create(sampleRate, Int32(maxFramesPerRender)) else {
            throw MixEngineError.creationFailed
        }
        self.sampleRate = sampleRate
        self.maxFramesPerRender = maxFramesPerRender
        self.handle = MixRenderHandle(raw: raw)
    }

    deinit {
        // Not reachable from the render thread once the owner tears down its graph.
        pm_destroy(handle.raw)
    }

    /// Loads `buffer` (at the engine's sample rate) so that source frame
    /// `sourcePosition` is heard at the deck's start frame, at `tempo` source
    /// frames per output frame (keylocked time-stretch beyond ±0.2 %).
    public func prepare(_ deck: MixDeck, buffer: PCMBuffer, sourcePosition: Double,
                        tempo: Double, gain: Float = 1) throws {
        guard abs(buffer.format.sampleRate - sampleRate) < 0.5 else {
            throw MixEngineError.sampleRateMismatch(expected: sampleRate, actual: buffer.format.sampleRate)
        }
        let result: Int32 = buffer.withUnsafeChannels { channels, frames in
            let left = UnsafePointer(channels[0])
            let right = UnsafePointer(channels[buffer.channelCount > 1 ? 1 : 0])
            return pm_deck_prepare(handle.raw, Int32(deck.rawValue), left, right,
                                   Int64(frames), sourcePosition, tempo, gain)
        }
        guard result == 0 else {
            let state = self.state(of: deck)
            throw state == .armed || state == .playing ? MixEngineError.deckBusy(deck) : MixEngineError.invalidArgument
        }
        loaded[deck] = buffer
    }

    /// Arms a prepared deck to start at master frame `frame`.
    public func start(_ deck: MixDeck, atFrame frame: Int64) throws {
        guard pm_deck_start(handle.raw, Int32(deck.rawValue), frame) == 0 else {
            throw MixEngineError.deckBusy(deck)
        }
    }

    public func stop(_ deck: MixDeck) { pm_deck_stop(handle.raw, Int32(deck.rawValue)) }

    /// A finished deck back to idle; drops its PCM.
    @discardableResult
    public func reset(_ deck: MixDeck) -> Bool {
        let ok = pm_deck_reset(handle.raw, Int32(deck.rawValue)) == 0
        if ok { loaded[deck] = nil }
        return ok
    }

    public func state(of deck: MixDeck) -> MixDeckState {
        MixDeckState(rawValue: pm_deck_state_of(handle.raw, Int32(deck.rawValue))) ?? .idle
    }

    /// Source frame at the last rendered frame, nil when not playing.
    public func position(of deck: MixDeck) -> Double? {
        let value = pm_deck_position(handle.raw, Int32(deck.rawValue))
        return value.isNaN ? nil : value
    }

    public func isKeylocked(_ deck: MixDeck) -> Bool {
        pm_deck_keylocked(handle.raw, Int32(deck.rawValue)) != 0
    }

    public var masterFrame: Int64 { pm_master_frame(handle.raw) }

    public func scheduleBassSwap(from outgoing: MixDeck, to incoming: MixDeck, startFrame: Double,
                                 framesPerBeat: Double, overlapBeats: Int = 64) {
        pm_schedule_bass_swap(handle.raw, Int32(outgoing.rawValue), Int32(incoming.rawValue),
                              startFrame, framesPerBeat, Int32(overlapBeats))
    }

    public func scheduleCut(from outgoing: MixDeck, to incoming: MixDeck, cutFrame: Double, fadeFrames: Double) {
        pm_schedule_cut(handle.raw, Int32(outgoing.rawValue), Int32(incoming.rawValue), cutFrame, fadeFrames)
    }

    public func clearRecipe() { pm_clear_recipe(handle.raw) }

    /// Offline rendering (tests, previews, the blend lab): `frames` frames in
    /// render-sized blocks, exactly as the device render callback would.
    public func render(frames: Int) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var done = 0
                while done < frames {
                    let n = min(maxFramesPerRender, frames - done)
                    handle.render(left: l.baseAddress! + done, right: r.baseAddress! + done, frames: n)
                    done += n
                }
            }
        }
        return (left, right)
    }
}
