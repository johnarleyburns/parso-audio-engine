//
//  EQTapInstaller.swift
//  Shared MTAudioProcessingTap plumbing for the listening path: one tap per
//  AVPlayerItem, with the one-tap-per-item bookkeeping that is the fix for the
//  EQ (or any tap effect) silently dying on every gapless auto-advance — the
//  preloaded item gets its own tap while the current item keeps playing through
//  its own, so AVQueuePlayer advancing no longer drops the audioMix
//  (docs/UNIFICATION_PLAN.md §3).
//
//  Deliberately minimal (author decision, 2026-09-02): this installs a tap that
//  hands each source buffer list to a caller-supplied realtime processor. The
//  actual DSP — Tonearm's Pro-Audio kernel (parametric EQ / convolution /
//  crossfeed / ReplayGain), Voxglass's graphic EQ + RMS normalizer + silence
//  detector — stays in the apps, layered around `GraphicEQ`.
//

import Foundation

/// Tracks which player items currently hold a live tap, keyed by object identity.
/// AVFoundation-free so the "one tap per item" invariant is unit-testable: one
/// processor structurally cannot serve two items through a single tap, so each
/// item gets its own and item-changed evicts the old one. Lifted verbatim from
/// Voxglass's `EQTapRegistry`.
public final class EQTapRegistry {
    public private(set) var identifiers: Set<ObjectIdentifier> = []

    public init() {}

    public var count: Int { identifiers.count }
    public var isEmpty: Bool { identifiers.isEmpty }

    public func isAttached(_ object: AnyObject) -> Bool {
        identifiers.contains(ObjectIdentifier(object))
    }

    @discardableResult
    public func attach(_ object: AnyObject) -> Bool {
        identifiers.insert(ObjectIdentifier(object)).inserted
    }

    @discardableResult
    public func evict(_ object: AnyObject) -> Bool {
        identifiers.remove(ObjectIdentifier(object)) != nil
    }

    public func evict(identifier: ObjectIdentifier) {
        identifiers.remove(identifier)
    }

    public func evictAll() {
        identifiers.removeAll()
    }
}

#if !os(watchOS)
@preconcurrency import AVFoundation

/// A realtime audio processor driven by an `EQTapInstaller` tap. All three
/// callbacks run on the realtime audio thread: do NO allocation, NO locking that
/// can block, and NO Swift runtime work that can. Live parameter changes must be
/// published lock-free from another thread (see Tonearm's `EQAudioTap` kernel
/// swap for the pattern).
public protocol RealtimeAudioProcessor: AnyObject {
    /// Called on `prepare` — reset filter history for a fresh stream.
    func prepareRealtime()
    /// Called per render cycle with the source audio already fetched into `bufferList`.
    /// `channelCount` is per-buffer; a non-interleaved float mix delivers one
    /// buffer per channel.
    func processRealtime(_ bufferList: UnsafeMutableAudioBufferListPointer, frameCount: Int)
}

/// Installs `MTAudioProcessingTap`s on `AVPlayerItem`s, one per item, and keeps
/// the registry of live taps.
public final class EQTapInstaller: @unchecked Sendable {
    public enum Placement {
        /// Tapped before AVPlayer's own effects (Voxglass). Sees the raw decoded signal.
        case preEffects
        /// Tapped after AVPlayer's effects (Tonearm). Always non-interleaved float.
        case postEffects
        var flag: MTAudioProcessingTapCreationFlags {
            self == .preEffects
                ? kMTAudioProcessingTapCreationFlag_PreEffects
                : kMTAudioProcessingTapCreationFlag_PostEffects
        }
    }

    private let placement: Placement
    public let registry = EQTapRegistry()

    /// Retains the processor + tap for one item. Ownership note (from a Voxglass
    /// field crash, FigPlayer_RemoteXPC): the stored tap MUST carry its own +1
    /// (`passRetained`) because `remove`/`removeAll` release it; storing it
    /// unretained over-releases a retain owned by MediaToolbox and crashes in
    /// its own CFRelease.
    private final class Entry {
        let processor: RealtimeAudioProcessor
        var tap: Unmanaged<MTAudioProcessingTap>?
        init(processor: RealtimeAudioProcessor) { self.processor = processor }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    private final class TapHandle: @unchecked Sendable {
        let value: MTAudioProcessingTap
        init(_ value: MTAudioProcessingTap) { self.value = value }
    }

    public init(placement: Placement) {
        self.placement = placement
    }

    public var activeTapCount: Int { registry.count }

    public func isInstalled(on item: AVPlayerItem) -> Bool {
        entries[ObjectIdentifier(item)] != nil
    }

    /// Installs a tap on `item` driving `processor`. No-op if the item is already
    /// tapped. The tap's `audioMix` is set once the asset's audio track resolves
    /// (remote assets rarely have tracks loaded synchronously).
    @discardableResult
    public func install(on item: AVPlayerItem, processor: RealtimeAudioProcessor) -> Bool {
        let key = ObjectIdentifier(item)
        guard entries[key] == nil else { return false }

        let entry = Entry(processor: processor)
        guard let tap = makeTap(for: entry) else { return false }
        entry.tap = Unmanaged.passRetained(tap)
        entries[key] = entry
        registry.attach(item)
        applyMix(tap: tap, to: item)
        return true
    }

    public func remove(from item: AVPlayerItem) {
        let key = ObjectIdentifier(item)
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.tap?.release()
        registry.evict(item)
    }

    public func removeAll() {
        for entry in entries.values { entry.tap?.release() }
        entries.removeAll()
        registry.evictAll()
    }

    /// Evicts taps for items no longer in `items` — call after a gapless
    /// auto-advance leaves the previous chapter's item behind.
    public func prune(keeping items: [AVPlayerItem]) {
        let live = Set(items.map(ObjectIdentifier.init))
        for (key, entry) in entries where !live.contains(key) {
            entry.tap?.release()
            entries[key] = nil
            registry.evict(identifier: key)
        }
    }

    private func makeTap(for entry: Entry) -> MTAudioProcessingTap? {
        let clientInfo = Unmanaged.passUnretained(entry).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: { _, clientInfo, tapStorageOut in
                let e = Unmanaged<Entry>.fromOpaque(clientInfo!).takeUnretainedValue()
                tapStorageOut.pointee = Unmanaged.passRetained(e).toOpaque()
            },
            finalize: { tap in
                Unmanaged<Entry>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, _ in
                let e = Unmanaged<Entry>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                e.processor.prepareRealtime()
            },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                               flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }
                let e = Unmanaged<Entry>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                e.processor.processRealtime(abl, frameCount: Int(numberFrames))
            })

        // SDKs before Xcode 16.3 (Swift 6.1) type the out-parameter as
        // `Unmanaged<MTAudioProcessingTap>?` on both iOS and macOS; newer SDKs
        // use the bridged `MTAudioProcessingTap?`.
        #if compiler(<6.1)
        var tapOut: Unmanaged<MTAudioProcessingTap>?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, placement.flag, &tapOut)
        guard err == noErr, let tap = tapOut?.takeRetainedValue() else { return nil }
        return tap
        #else
        var tap: MTAudioProcessingTap?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, placement.flag, &tap)
        guard err == noErr, let tap else { return nil }
        return tap
        #endif
    }

    private func applyMix(tap: MTAudioProcessingTap, to item: AVPlayerItem) {
        let handle = TapHandle(tap)
        Task { @MainActor [weak self, weak item, handle] in
            guard let self, let item, self.isInstalled(on: item) else { return }
            let tracks = try? await item.asset.load(.tracks)
            let audio = tracks?.first { $0.mediaType == .audio }
            let params = AVMutableAudioMixInputParameters(track: audio)
            params.audioTapProcessor = handle.value
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
    }
}
#endif
