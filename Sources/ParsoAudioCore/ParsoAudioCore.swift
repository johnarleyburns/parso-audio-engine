//
//  ParsoAudioCore.swift
//  Reusable, DJ-agnostic audio primitives: buffers, file IO, sample-rate
//  conversion, loudness, and thin wrappers over the RT DSP kernels.
//
//  STATUS: implemented. Apple platforms use AVFoundation/AudioToolbox for the
//  native containers (WAV/AIFF/CAF/MP3/AAC/ALAC-in-M4A); FLAC/Vorbis/Opus and
//  libsamplerate/libebur128 are vendored permissive C. See docs/SPEC.md §9.
//

import Foundation
import CParsoDSP
import CGlint
import Cebur128
import Csrc
import CflacBridge
import CvorbisBridge
import CopusBridge
import AVFoundation
// AudioToolbox is absent from the watchOS SDK; the AVFAudio-based encode/decode
// paths below only need the format constants, which AVFoundation re-exports
// from CoreAudioTypes (docs/UNIFICATION_PLAN.md §5).
#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// Glint's whole-file AAC decoder currently has process-global initialization
/// state. Keep offline package decodes serialized until that upstream boundary
/// becomes intrinsically thread-safe; this lock is never reachable from the
/// real-time render path.
enum GlintDecodeGate {
    private static let lock = NSLock()

    static func withLock<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Buffers & formats

/// A PCM stream description.
public struct AudioFormat: Sendable, Equatable {
    public var sampleRate: Double
    public var channelCount: Int
    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// Non-interleaved 32-bit float PCM. Storage is contiguous per channel and
/// suitable for handing to the RT engine as a resident buffer.
///
/// This is real, dependency-free plumbing (not a stub) so tests and signal
/// generators can construct inputs before the DSP layer exists.
public final class PCMBuffer: @unchecked Sendable {
    /// Mutable channel view that keeps its parent buffer alive for the lifetime of the view.
    public final class Channel: RandomAccessCollection, MutableCollection {
        public typealias Index = Int
        public typealias Element = Float

        private let owner: PCMBuffer
        private let storage: UnsafeMutableBufferPointer<Float>

        fileprivate init(owner: PCMBuffer, storage: UnsafeMutableBufferPointer<Float>) {
            self.owner = owner
            self.storage = storage
        }

        public var startIndex: Int { storage.startIndex }
        public var endIndex: Int { storage.endIndex }

        public subscript(position: Int) -> Float {
            get { storage[position] }
            set { storage[position] = newValue }
        }
    }

    public let format: AudioFormat
    public let frameCount: Int
    public let channelCount: Int
    private let channelPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    public init(format: AudioFormat, capacity frames: Int) {
        self.format = format
        self.frameCount = max(0, frames)
        self.channelCount = max(1, format.channelCount)
        channelPtrs = .allocate(capacity: channelCount)
        for c in 0..<channelCount {
            let n = max(1, frameCount)
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            channelPtrs[c] = p
        }
    }

    deinit {
        let n = max(1, frameCount)
        for c in 0..<channelCount {
            channelPtrs[c].deinitialize(count: n)
            channelPtrs[c].deallocate()
        }
        channelPtrs.deallocate()
    }

    /// Access raw non-interleaved channel pointers.
    public func withUnsafeChannels<R>(
        _ body: (_ channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, _ frames: Int) -> R
    ) -> R {
        body(channelPtrs, frameCount)
    }

    /// Read/write a single channel. The returned view retains this buffer so chained
    /// access on a temporary buffer cannot leave a dangling pointer.
    public func channel(_ index: Int) -> Channel {
        precondition(index >= 0 && index < channelCount, "channel out of range")
        return Channel(
            owner: self,
            storage: UnsafeMutableBufferPointer(start: channelPtrs[index], count: frameCount)
        )
    }

    /// Copy a mono downmix into a freshly allocated buffer (analysis convenience).
    public func downmixedToMono() -> PCMBuffer {
        let mono = PCMBuffer(format: AudioFormat(sampleRate: format.sampleRate, channelCount: 1),
                             capacity: frameCount)
        let out = mono.channel(0)
        let inv = 1.0 / Float(channelCount)
        for i in 0..<frameCount {
            var acc: Float = 0
            for c in 0..<channelCount { acc += channelPtrs[c][i] }
            out[i] = acc * inv
        }
        return mono
    }
}

// MARK: - File IO

public enum AudioContainer: Sendable, Equatable {
    case flac          // libFLAC (Cflac)
    case oggVorbis     // Xiph libvorbisfile (Cvorbis)
    case opus          // libopusfile (Copus)
    case wav, aiff, caf, mp3, aac, m4a, m4b  // AVFoundation-native containers
    case auto
}

extension AudioContainer {
    func resolved(for url: URL) -> AudioContainer {
        guard self == .auto else { return self }
        switch url.pathExtension.lowercased() {
        case "flac": return .flac
        case "ogg": return .oggVorbis
        case "opus": return .opus
        case "wav": return .wav
        case "aif", "aiff": return .aiff
        case "caf": return .caf
        case "mp3": return .mp3
        case "aac": return .aac
        case "m4a", "alac": return .m4a
        case "m4b": return .m4b
        default: return .wav
        }
    }
}

public enum AudioFileError: Error, Sendable, Equatable {
    case unsupportedContainer(AudioContainer)
    case invalidFile(String)
    case formatMismatch
    case writeFailed(String)
}

/// A contiguous span of a source file, in source-file sample frames *before*
/// any resampling.
public struct AudioFrameRange: Sendable, Equatable {
    /// First source-file sample frame of the span.
    public var startFrame: Int64
    /// Number of source-file sample frames requested.
    public var frameCount: Int

    public init(startFrame: Int64, frameCount: Int) {
        self.startFrame = startFrame
        self.frameCount = frameCount
    }
}

/// The result of a bounded range decode: the decoded PCM plus how many source
/// frames the decoder actually touched, so callers can assert the read was
/// bounded by the request rather than by the whole file.
public struct RangeDecodeResult: Sendable {
    public var buffer: PCMBuffer
    public var decodedSourceFrames: Int

    public init(buffer: PCMBuffer, decodedSourceFrames: Int) {
        self.buffer = buffer
        self.decodedSourceFrames = decodedSourceFrames
    }
}

public enum RangeDecodeError: Error, Sendable, Equatable {
    /// The source stream could not be positioned; a whole-file decode was *not*
    /// attempted.
    case notSeekable
    case decodeFailed(String)
}

/// Common text metadata exposed by portable M4A files.
public struct AudioFileMetadata: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
    }
}

/// Reads PCM from disk. Routing by container:
/// `.flac` → libFLAC (`Cflac`); `.oggVorbis` → Xiph libvorbisfile (`Cvorbis`);
/// `.opus` → libopusfile (`Copus`); the native containers (WAV, AIFF, CAF, MP3,
/// AAC, ALAC-in-M4A) go through `AVAudioFile`.
