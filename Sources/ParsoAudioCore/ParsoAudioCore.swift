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
import Calac
#if canImport(AVFoundation)
import AVFoundation
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
    case oggVorbis     // stb_vorbis (Cvorbis)
    case opus          // libopusfile (Copus)
    case wav, aiff, caf, mp3, aac, m4a  // Apple; Linux has portable MP3/AAC and narrow M4A profiles
    case auto
}

private extension AudioContainer {
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
/// `.flac` → libFLAC (`Cflac`); `.oggVorbis` → stb_vorbis (`Cvorbis`);
/// `.opus` → libopusfile (`Copus`); Apple uses AVAudioFile for native formats,
/// while Linux uses Glint for MP3/ADTS AAC and the portable narrow M4A AAC
/// profile. Portable ALAC is unavailable pending an independently authored
/// implementation.
public struct AudioFileReader: Sendable {
    public let format: AudioFormat
    public let frameCount: Int
    private let decoded: PCMBuffer

    public init(url: URL, container: AudioContainer = .auto) throws {
        let resolved = container.resolved(for: url)
        let buffer = try AudioFileReader.decode(url: url, container: resolved)
        self.format = buffer.format
        self.frameCount = buffer.frameCount
        self.decoded = buffer
    }

    public func readAll() throws -> PCMBuffer { decoded }

    public func read(into buffer: PCMBuffer, frameOffset: Int) throws -> Int {
        guard frameOffset >= 0, frameOffset < frameCount || (frameOffset == 0 && frameCount == 0) else {
            return 0
        }
        guard buffer.channelCount == format.channelCount else { throw AudioFileError.formatMismatch }
        let count = min(buffer.frameCount, frameCount - frameOffset)
        for channel in 0..<format.channelCount {
            let source = decoded.channel(channel)
            let destination = buffer.channel(channel)
            for frame in 0..<count { destination[frame] = source[frameOffset + frame] }
        }
        return count
    }

    private static func decode(url: URL, container: AudioContainer) throws -> PCMBuffer {
        switch container {
        case .flac:
            return try decodeFLAC(url: url)
        case .oggVorbis:
            do { return try decodeVorbis(url: url) }
            catch { return try decodeOpus(url: url) }
        case .opus:
            return try decodeOpus(url: url)
        case .wav:
            return try decodeWAV(url: url)
        case .mp3:
#if canImport(AVFoundation)
            return try decodeApple(url: url)
#else
            return try decodeGlint(url: url)
#endif
        case .aac:
#if canImport(AVFoundation)
            return try decodeApple(url: url)
#else
            return try decodeGlint(url: url)
#endif
        case .aiff, .caf, .m4a:
#if canImport(AVFoundation)
            return try decodeApple(url: url)
#else
            if container == .m4a {
                let data: Data
                do { data = try Data(contentsOf: url) }
                catch { throw AudioFileError.invalidFile(error.localizedDescription) }
                return try MP4AACCodec.decode(data)
            }
            throw AudioFileError.unsupportedContainer(container)
#endif
        case .auto:
            throw AudioFileError.unsupportedContainer(container)
        }
    }

    /// Reads common text metadata without decoding the audio payload.
    ///
    /// This portable reader currently supports ISO-BMFF/M4A `©nam`, `©ART`,
    /// `©alb`, and `aART` items. Unsupported containers and malformed files
    /// are reported instead of being silently treated as audio metadata.
    public static func readMetadata(from url: URL, container: AudioContainer = .auto) throws -> AudioFileMetadata {
        let resolved = container.resolved(for: url)
        guard resolved == .m4a else { throw AudioFileError.unsupportedContainer(resolved) }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw AudioFileError.invalidFile(error.localizedDescription) }
        return try MP4ALACCodec.readMetadata(data)
    }

    private static func decodeFLAC(url: URL) throws -> PCMBuffer {
        var samples: UnsafeMutablePointer<Int32>?
        var exactFloatBits: UnsafeMutablePointer<UInt32>?
        var frames: UInt64 = 0
        var channels: UInt32 = 0
        var sampleRate: UInt32 = 0
        let result = url.path.withCString { path in
            parso_flac_decode_file(path, &samples, &exactFloatBits, &frames, &channels, &sampleRate)
        }
        guard result == 0, let samples, channels > 0,
              frames <= UInt64(Int.max), frames <= UInt64(Int.max) / UInt64(channels) else {
            if let samples { parso_flac_free(samples) }
            if let exactFloatBits { parso_flac_free(exactFloatBits) }
            throw AudioFileError.invalidFile("libFLAC decode failed")
        }
        defer { parso_flac_free(samples) }
        defer { if let exactFloatBits { parso_flac_free(exactFloatBits) } }
        let frameCount = Int(frames)
        let channelCount = Int(channels)
        let output = PCMBuffer(
            format: AudioFormat(sampleRate: Double(sampleRate), channelCount: channelCount),
            capacity: frameCount
        )
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let index = frame * channelCount + channel
                output.channel(channel)[frame] = exactFloatBits.map {
                    Float(bitPattern: $0[index])
                } ?? (Float(samples[index]) * (1.0 / 2_147_483_648))
            }
        }
        return output
    }

    private static func decodeWAV(url: URL) throws -> PCMBuffer {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw AudioFileError.invalidFile(error.localizedDescription) }
        return try WAVCodec.decode(data)
    }

    private static func decodeGlint(url: URL) throws -> PCMBuffer {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw AudioFileError.invalidFile(error.localizedDescription) }
        guard !data.isEmpty, data.count <= Int(Int32.max) else {
            throw AudioFileError.invalidFile("Glint input is empty or too large")
        }

        var sampleRate: Int32 = 0
        var channels: Int32 = 0
        var frames: Int32 = 0
        let decoded: UnsafeMutablePointer<Float>? = GlintDecodeGate.withLock {
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return nil }
                return glint_decode_audio(
                    baseAddress.assumingMemoryBound(to: UInt8.self),
                    Int32(data.count),
                    &sampleRate,
                    &channels,
                    &frames
                )
            }
        }
        guard let decoded, sampleRate > 0, channels > 0, frames > 0 else {
            if let decoded { glint_free(decoded) }
            throw AudioFileError.invalidFile("Glint decode failed")
        }
        defer { glint_free(decoded) }

        let output = PCMBuffer(
            format: AudioFormat(sampleRate: Double(sampleRate), channelCount: Int(channels)),
            capacity: Int(frames)
        )
        for frame in 0..<Int(frames) {
            for channel in 0..<Int(channels) {
                output.channel(channel)[frame] = decoded[frame * Int(channels) + channel]
            }
        }
        return output
    }

    private static func decodeVorbis(url: URL) throws -> PCMBuffer {
        var samples: UnsafeMutablePointer<Int16>?
        var frames: UInt64 = 0
        var channels: UInt32 = 0
        var sampleRate: UInt32 = 0
        let result = url.path.withCString { path in
            parso_vorbis_decode_file(path, &samples, &frames, &channels, &sampleRate)
        }
        guard result == 0, let samples, channels > 0,
              frames <= UInt64(Int.max), frames <= UInt64(Int.max) / UInt64(channels) else {
            if let samples { parso_vorbis_free(samples) }
            throw AudioFileError.invalidFile("stb_vorbis decode failed")
        }
        defer { parso_vorbis_free(samples) }
        let frameCount = Int(frames)
        let channelCount = Int(channels)
        let output = PCMBuffer(
            format: AudioFormat(sampleRate: Double(sampleRate), channelCount: channelCount),
            capacity: frameCount
        )
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                output.channel(channel)[frame] = Float(samples[frame * channelCount + channel]) * (1.0 / 32_768.0)
            }
        }
        return output
    }

    private static func decodeOpus(url: URL) throws -> PCMBuffer {
        var samples: UnsafeMutablePointer<Float>?
        var frames: UInt64 = 0
        var channels: UInt32 = 0
        var sampleRate: UInt32 = 0
        let result = url.path.withCString { path in
            parso_opus_decode_file(path, &samples, &frames, &channels, &sampleRate)
        }
        guard result == 0, let samples, channels > 0,
              frames <= UInt64(Int.max), frames <= UInt64(Int.max) / UInt64(channels) else {
            if let samples { parso_opus_free(samples) }
            throw AudioFileError.invalidFile("libopusfile decode failed")
        }
        defer { parso_opus_free(samples) }
        let frameCount = Int(frames)
        let channelCount = Int(channels)
        let output = PCMBuffer(
            format: AudioFormat(sampleRate: Double(sampleRate), channelCount: channelCount),
            capacity: frameCount
        )
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                output.channel(channel)[frame] = samples[frame * channelCount + channel]
            }
        }
        return output
    }

#if canImport(AVFoundation)
    private static func decodeApple(url: URL) throws -> PCMBuffer {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw AudioFileError.invalidFile(error.localizedDescription) }
        let sourceFormat = file.processingFormat
        let frameCount = Int(file.length)
        guard let audioBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { throw AudioFileError.invalidFile("could not allocate decoded PCM buffer") }
        do { try file.read(into: audioBuffer) }
        catch { throw AudioFileError.invalidFile(error.localizedDescription) }
        guard let channels = audioBuffer.floatChannelData else {
            throw AudioFileError.invalidFile("decoded audio is not float PCM")
        }
        let output = PCMBuffer(
            format: AudioFormat(sampleRate: sourceFormat.sampleRate, channelCount: Int(sourceFormat.channelCount)),
            capacity: Int(audioBuffer.frameLength)
        )
        for channel in 0..<output.channelCount {
            for frame in 0..<output.frameCount { output.channel(channel)[frame] = channels[channel][frame] }
        }
        return output
    }
#endif
}

/// Export codecs. MP3 uses the portable Glint encoder; AAC/ALAC use AudioToolbox on Apple.
/// Portable ALAC remains unavailable until an independently authored implementation is added.
public enum ExportCodec: Sendable, Equatable {
    case wavPCM(bitDepth: Int)   // via AVAudioFile / ExtAudioFile
    case flac(compression: Int)  // via libFLAC (Cflac)
    case aac(bitrate: Int)       // via AudioToolbox
    case alac                    // via AudioToolbox (lossless)
    case mp3(bitrate: Int)       // via portable Glint encoder
}

public struct AudioFileWriter {
    private let url: URL
    private let format: AudioFormat
    private let codec: ExportCodec

    public init(url: URL, format: AudioFormat, codec: ExportCodec) throws {
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioFileError.formatMismatch
        }
        self.url = url
        self.format = format
        self.codec = codec
    }

    public func write(_ buffer: PCMBuffer) throws {
        guard buffer.format == format else { throw AudioFileError.formatMismatch }
        switch codec {
        case .flac(let compression):
            try writeFLAC(buffer, compression: compression)
        case .wavPCM(let bitDepth):
            do { try WAVCodec.write(buffer, bitDepth: bitDepth, to: url) }
            catch { throw AudioFileError.writeFailed(error.localizedDescription) }
        case .aac(let bitrate):
#if canImport(AVFoundation)
            try writeApple(buffer, formatID: kAudioFormatMPEG4AAC, bitrate: bitrate)
#else
            if url.pathExtension.lowercased() == "aac" {
                try writeGlint(buffer, format: Int32(GLINT_ENC_AAC.rawValue), bitrate: bitrate)
            } else {
                throw AudioFileError.writeFailed(
                    "portable AAC currently emits ADTS only; M4A requires the planned minimp4 container layer"
                )
            }
#endif
        case .alac:
#if canImport(AVFoundation)
            try writeApple(buffer, formatID: kAudioFormatAppleLossless, bitrate: 0)
#else
            throw AudioFileError.writeFailed("portable ALAC is unavailable; use Apple AudioToolbox on Apple platforms")
#endif
        case .mp3(let bitrate):
            try writeGlint(buffer, format: Int32(GLINT_ENC_MP3.rawValue), bitrate: bitrate)
        }
    }

    public func finish() throws {}

    private func writeFLAC(_ buffer: PCMBuffer, compression: Int) throws {
        var interleaved = [Int32](repeating: 0, count: buffer.frameCount * buffer.channelCount)
        var exactFloatBits = [UInt32](repeating: 0, count: interleaved.count)
        for frame in 0..<buffer.frameCount {
            for channel in 0..<buffer.channelCount {
                let sample = buffer.channel(channel)[frame]
                let index = frame * buffer.channelCount + channel
                exactFloatBits[index] = sample.bitPattern
                let value = max(-1.0, min(0.9999999995343387, Double(sample)))
                let scaled = (value * 2_147_483_648.0).rounded()
                interleaved[index] = Int32(max(-2_147_483_648.0, min(2_147_483_647.0, scaled)))
            }
        }
        let result = url.path.withCString { path in
            interleaved.withUnsafeBufferPointer { samples in
                exactFloatBits.withUnsafeBufferPointer { exactBits in
                    parso_flac_encode_file(
                        path,
                        samples.baseAddress,
                        exactBits.baseAddress,
                        UInt64(buffer.frameCount),
                        UInt32(buffer.channelCount),
                        UInt32(buffer.format.sampleRate.rounded()),
                        UInt32(max(0, compression))
                    )
                }
            }
        }
        guard result == 0 else { throw AudioFileError.writeFailed("libFLAC encode failed") }
    }

    private func writeGlint(_ buffer: PCMBuffer, format: Int32, bitrate: Int) throws {
        guard bitrate > 0, buffer.frameCount <= Int(Int32.max),
              buffer.channelCount <= Int(Int32.max),
              buffer.format.sampleRate <= Double(Int32.max) else {
            throw AudioFileError.formatMismatch
        }
        var interleaved = [Float](repeating: 0, count: buffer.frameCount * buffer.channelCount)
        for frame in 0..<buffer.frameCount {
            for channel in 0..<buffer.channelCount {
                interleaved[frame * buffer.channelCount + channel] = buffer.channel(channel)[frame]
            }
        }
        var outputSize: Int32 = 0
        let encoded: UnsafeMutablePointer<UInt8>? = interleaved.withUnsafeBufferPointer { samples in
            glint_encode_audio(
                samples.baseAddress,
                Int32(buffer.frameCount),
                Int32(buffer.channelCount),
                Int32(buffer.format.sampleRate.rounded()),
                format,
                Int32(bitrate),
                -1,
                Int32(GLINT_QUALITY_NORMAL.rawValue),
                &outputSize
            )
        }
        guard let encoded, outputSize > 0 else {
            if let encoded { glint_free(encoded) }
            throw AudioFileError.writeFailed("Glint encode failed")
        }
        defer { glint_free(encoded) }
        do {
            try Data(bytes: encoded, count: Int(outputSize)).write(to: url)
        } catch {
            throw AudioFileError.writeFailed(error.localizedDescription)
        }
    }

#if canImport(AVFoundation)
    private func writeApple(_ buffer: PCMBuffer, formatID: AudioFormatID, bitrate: Int) throws {
        var settings: [String: Any] = [
            AVFormatIDKey: formatID,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]
        if bitrate > 0 { settings[AVEncoderBitRateKey] = bitrate }
        let file: AVAudioFile
        do { file = try AVAudioFile(forWriting: url, settings: settings) }
        catch { throw AudioFileError.writeFailed(error.localizedDescription) }
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channelCount),
            interleaved: false
        ), let audioBuffer = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: AVAudioFrameCount(buffer.frameCount)
        ), let channels = audioBuffer.floatChannelData else {
            throw AudioFileError.writeFailed("could not allocate encode buffer")
        }
        audioBuffer.frameLength = AVAudioFrameCount(buffer.frameCount)
        for channel in 0..<buffer.channelCount {
            for frame in 0..<buffer.frameCount { channels[channel][frame] = buffer.channel(channel)[frame] }
        }
        do { try file.write(from: audioBuffer) }
        catch { throw AudioFileError.writeFailed(error.localizedDescription) }
    }
#endif
}

private enum WAVCodec {
    static func decode(_ data: Data) throws -> PCMBuffer {
        guard data.count >= 12, bytes(data, equalTo: [0x52, 0x49, 0x46, 0x46], at: 0),
              bytes(data, equalTo: [0x57, 0x41, 0x56, 0x45], at: 8) else {
            throw AudioFileError.invalidFile("not a RIFF/WAVE file")
        }
        var formatCode = 0
        var channels = 0
        var sampleRate = 0
        var bitsPerSample = 0
        var blockAlign = 0
        var audioRange: Range<Int>?
        var offset = 12
        while offset + 8 <= data.count {
            let size = Int(readUInt32(data, at: offset + 4))
            let payload = offset + 8
            guard size >= 0, payload <= data.count, size <= data.count - payload else {
                throw AudioFileError.invalidFile("truncated WAVE chunk")
            }
            if bytes(data, equalTo: [0x66, 0x6D, 0x74, 0x20], at: offset) {
                guard size >= 16 else { throw AudioFileError.invalidFile("invalid WAVE format chunk") }
                formatCode = Int(readUInt16(data, at: payload))
                channels = Int(readUInt16(data, at: payload + 2))
                sampleRate = Int(readUInt32(data, at: payload + 4))
                blockAlign = Int(readUInt16(data, at: payload + 12))
                bitsPerSample = Int(readUInt16(data, at: payload + 14))
            } else if bytes(data, equalTo: [0x64, 0x61, 0x74, 0x61], at: offset) {
                audioRange = payload..<(payload + size)
            }
            let next = payload + size + (size & 1)
            guard next > offset else { throw AudioFileError.invalidFile("invalid WAVE chunk size") }
            offset = next
        }
        guard (formatCode == 1 || formatCode == 3), channels > 0, channels <= 32,
              sampleRate > 0, (bitsPerSample == 8 || bitsPerSample == 16 || bitsPerSample == 24 || bitsPerSample == 32),
              let audioRange, blockAlign >= channels * (bitsPerSample / 8),
              audioRange.count % blockAlign == 0 else {
            throw AudioFileError.invalidFile("unsupported WAVE format")
        }
        if formatCode == 3 && bitsPerSample != 32 {
            throw AudioFileError.invalidFile("only 32-bit float WAVE is supported")
        }
        let frames = audioRange.count / blockAlign
        let output = PCMBuffer(
            format: AudioFormat(sampleRate: Double(sampleRate), channelCount: channels),
            capacity: frames
        )
        for frame in 0..<frames {
            let frameOffset = audioRange.lowerBound + frame * blockAlign
            for channel in 0..<channels {
                let sampleOffset = frameOffset + channel * (bitsPerSample / 8)
                output.channel(channel)[frame] = decodeSample(
                    data, at: sampleOffset, formatCode: formatCode, bitsPerSample: bitsPerSample
                )
            }
        }
        return output
    }

    static func write(_ buffer: PCMBuffer, bitDepth: Int, to url: URL) throws {
        guard bitDepth == 8 || bitDepth == 16 || bitDepth == 24 || bitDepth == 32 else {
            throw AudioFileError.invalidFile("WAVE bit depth must be 8, 16, 24, or 32")
        }
        let bytesPerSample = bitDepth / 8
        let blockAlign = buffer.channelCount * bytesPerSample
        let dataSize = buffer.frameCount * blockAlign
        guard dataSize <= Int(UInt32.max), dataSize <= Int.max - 44 else {
            throw AudioFileError.writeFailed("WAVE file is too large")
        }
        var data = Data()
        data.reserveCapacity(44 + dataSize)
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        appendUInt32(&data, UInt32(36 + dataSize))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        appendUInt32(&data, 16)
        appendUInt16(&data, 1)
        appendUInt16(&data, UInt16(buffer.channelCount))
        appendUInt32(&data, UInt32(buffer.format.sampleRate.rounded()))
        appendUInt32(&data, UInt32(buffer.format.sampleRate.rounded()) * UInt32(blockAlign))
        appendUInt16(&data, UInt16(blockAlign))
        appendUInt16(&data, UInt16(bitDepth))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        appendUInt32(&data, UInt32(dataSize))
        for frame in 0..<buffer.frameCount {
            for channel in 0..<buffer.channelCount {
                let value = Double(buffer.channel(channel)[frame])
                switch bitDepth {
                case 8:
                    data.append(UInt8(max(0, min(255, Int((value * 127.5 + 128).rounded())))))
                case 16:
                    appendUInt16(&data, UInt16(bitPattern: Int16(quantize(value, scale: 32_768, min: -32_768, max: 32_767))))
                case 24:
                    let sample = quantize(value, scale: 8_388_608, min: -8_388_608, max: 8_388_607)
                    let raw = UInt32(bitPattern: Int32(sample))
                    data.append(UInt8(truncatingIfNeeded: raw))
                    data.append(UInt8(truncatingIfNeeded: raw >> 8))
                    data.append(UInt8(truncatingIfNeeded: raw >> 16))
                case 32:
                    appendUInt32(&data, UInt32(bitPattern: Int32(quantize(value, scale: 2_147_483_648, min: -2_147_483_648, max: 2_147_483_647))))
                default: break
                }
            }
        }
        try data.write(to: url, options: .atomic)
    }

    private static func decodeSample(_ data: Data, at offset: Int, formatCode: Int, bitsPerSample: Int) -> Float {
        if formatCode == 3 {
            return Float(bitPattern: readUInt32(data, at: offset))
        }
        switch bitsPerSample {
        case 8:
            return (Float(data[offset]) - 128) * (1.0 / 128.0)
        case 16:
            return Float(Int16(bitPattern: readUInt16(data, at: offset))) * (1.0 / 32_768.0)
        case 24:
            let raw = Int32(data[offset]) |
                (Int32(data[offset + 1]) << 8) |
                (Int32(data[offset + 2]) << 16)
            let signed = (raw & 0x0080_0000) != 0 ? raw | ~0x00FF_FFFF : raw
            return Float(signed) * (1.0 / 8_388_608.0)
        case 32:
            return Float(Int32(bitPattern: readUInt32(data, at: offset))) * (1.0 / 2_147_483_648.0)
        default:
            return 0
        }
    }

    private static func bytes(_ data: Data, equalTo expected: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset <= data.count, expected.count <= data.count - offset else { return false }
        return expected.indices.allSatisfy { data[offset + $0] == expected[$0] }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func quantize(_ value: Double, scale: Double, min lowerBound: Double, max upperBound: Double) -> Int64 {
        Int64(Swift.max(lowerBound, Swift.min(upperBound, (Swift.max(-1, Swift.min(0.9999999995343387, value)) * scale).rounded())))
    }
}

// MARK: - Sample-rate conversion (offline, libsamplerate)

public struct SampleRateConverter: Sendable {
    public enum Quality: Sendable { case best, medium, fastest }
    private let sourceRate: Double
    private let destinationRate: Double
    private let channels: Int
    private let quality: Quality

    public init(from: Double, to: Double, channels: Int, quality: Quality = .best) {
        precondition(from.isFinite && from > 0, "source sample rate must be positive")
        precondition(to.isFinite && to > 0, "destination sample rate must be positive")
        precondition(channels > 0, "channel count must be positive")
        precondition(src_is_valid_ratio(to / from) != 0, "sample-rate ratio is outside libsamplerate limits")
        self.sourceRate = from
        self.destinationRate = to
        self.channels = channels
        self.quality = quality
    }

    public func convert(_ input: PCMBuffer) throws -> PCMBuffer {
        guard input.channelCount == channels else {
            throw SampleRateConverterError.channelCountMismatch(expected: channels, actual: input.channelCount)
        }
        guard abs(input.format.sampleRate - sourceRate) < 0.5 else {
            throw SampleRateConverterError.sampleRateMismatch(expected: sourceRate, actual: input.format.sampleRate)
        }
        guard input.frameCount > 0 else {
            return PCMBuffer(
                format: AudioFormat(sampleRate: destinationRate, channelCount: channels),
                capacity: 0
            )
        }

        let ratio = destinationRate / sourceRate
        let estimatedFrames = max(1, Int(ceil(Double(input.frameCount) * ratio)) + 256)
        var interleavedInput = [Float](repeating: 0, count: input.frameCount * channels)
        for frame in 0..<input.frameCount {
            for channel in 0..<channels {
                interleavedInput[frame * channels + channel] = input.channel(channel)[frame]
            }
        }
        var interleavedOutput = [Float](repeating: 0, count: estimatedFrames * channels)

        let converter: Int32
        switch quality {
        case .best: converter = Int32(SRC_SINC_BEST_QUALITY)
        case .medium: converter = Int32(SRC_SINC_MEDIUM_QUALITY)
        case .fastest: converter = Int32(SRC_SINC_FASTEST)
        }
        let result: (error: Int32, outputFrames: Int) = interleavedInput.withUnsafeBufferPointer { inputPointer in
            interleavedOutput.withUnsafeMutableBufferPointer { outputPointer in
                var data = SRC_DATA(
                    data_in: inputPointer.baseAddress,
                    data_out: outputPointer.baseAddress,
                    input_frames: input.frameCount,
                    output_frames: estimatedFrames,
                    input_frames_used: 0,
                    output_frames_gen: 0,
                    end_of_input: 1,
                    src_ratio: ratio
                )
                let error = src_simple(&data, converter, Int32(channels))
                return (error: error, outputFrames: Int(data.output_frames_gen))
            }
        }
        guard result.error == 0 else {
            throw SampleRateConverterError.conversionFailed(String(cString: src_strerror(result.error)))
        }

        let outputFrames = result.outputFrames
        let output = PCMBuffer(
            format: AudioFormat(sampleRate: destinationRate, channelCount: channels),
            capacity: outputFrames
        )
        for frame in 0..<outputFrames {
            for channel in 0..<channels {
                output.channel(channel)[frame] = interleavedOutput[frame * channels + channel]
            }
        }
        return output
    }
}

public enum SampleRateConverterError: Error, Sendable, Equatable {
    case channelCountMismatch(expected: Int, actual: Int)
    case sampleRateMismatch(expected: Double, actual: Double)
    case conversionFailed(String)
}

// MARK: - Loudness / auto-gain (libebur128)

public struct LoudnessResult: Sendable, Equatable {
    public var integratedLUFS: Double
    public var truePeakDBTP: Double
    /// Gain (dB) to reach the analyzer's target loudness.
    public var gainToTargetDB: Double

    public init(integratedLUFS: Double, truePeakDBTP: Double, gainToTargetDB: Double) {
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
        self.gainToTargetDB = gainToTargetDB
    }
}

public struct LoudnessAnalyzer: Sendable {
    public var targetLUFS: Double
    public init(targetLUFS: Double = -14.0) { self.targetLUFS = targetLUFS }
    public func measure(_ buffer: PCMBuffer) -> LoudnessResult {
        let channels = buffer.channelCount
        let mode = EBUR128_MODE_I.rawValue | EBUR128_MODE_TRUE_PEAK.rawValue
        var optionalState = ebur128_init(
            UInt32(channels),
            UInt(buffer.format.sampleRate.rounded()),
            Int32(mode)
        )
        guard let state = optionalState else {
            return LoudnessResult(
                integratedLUFS: -.infinity,
                truePeakDBTP: -.infinity,
                gainToTargetDB: .infinity
            )
        }
        defer { ebur128_destroy(&optionalState) }

        var interleaved = [Float](repeating: 0, count: buffer.frameCount * channels)
        for frame in 0..<buffer.frameCount {
            for channel in 0..<channels {
                interleaved[frame * channels + channel] = buffer.channel(channel)[frame]
            }
        }
        interleaved.withUnsafeBufferPointer {
            _ = ebur128_add_frames_float(state, $0.baseAddress, buffer.frameCount)
        }

        var integratedLUFS = -Double.infinity
        _ = ebur128_loudness_global(state, &integratedLUFS)

        var truePeak = 0.0
        for channel in 0..<channels {
            var channelPeak = 0.0
            if ebur128_true_peak(state, UInt32(channel), &channelPeak) == EBUR128_SUCCESS.rawValue {
                truePeak = max(truePeak, channelPeak)
            }
        }
        let truePeakDBTP = truePeak > 0 ? 20 * log10(truePeak) : -Double.infinity

        return LoudnessResult(
            integratedLUFS: integratedLUFS,
            truePeakDBTP: truePeakDBTP,
            gainToTargetDB: targetLUFS - integratedLUFS
        )
    }
}

// MARK: - RT DSP wrappers (thin Swift over CParsoDSP; also usable offline for tests/reuse)

/// Independent or coupled time/pitch. `.varispeed` couples pitch to tempo
/// (scratch/pitch-bend); `.keyLock` is the Signalsmith phase vocoder.
public final class TimePitch: @unchecked Sendable {
    public enum Mode: Sendable { case varispeed, keyLock }
    // Created and destroyed on the control side; the C kernel owns all mutable
    // DSP state and receives only POD values and PCM pointers while rendering.
    private let handle: OpaquePointer
    private let channels: Int

    public var mode: Mode = .varispeed {
        didSet {
            pd_tp_set_mode(handle, mode == .keyLock ? PD_TP_KEYLOCK : PD_TP_VARISPEED)
        }
    }
    public var tempoRatio: Double = 1.0 { didSet { pd_tp_set_time_ratio(handle, tempoRatio) } }
    public var pitchSemitones: Double = 0.0 {
        didSet { pd_tp_set_pitch_semitones(handle, pitchSemitones) }
    }

    public init(sampleRate: Double, channels: Int, maxBlock: Int) {
        precondition(sampleRate.isFinite && sampleRate > 0, "sample rate must be positive")
        precondition(channels > 0, "channel count must be positive")
        precondition(maxBlock > 0, "max block must be positive")
        guard let handle = pd_tp_create(sampleRate, Int32(channels), Int32(maxBlock)) else {
            preconditionFailure("could not create time/pitch processor")
        }
        self.handle = handle
        self.channels = channels
    }

    deinit { pd_tp_destroy(handle) }

    public func reset() { pd_tp_reset(handle) }

    /// Offline convenience: process a whole buffer at the current settings.
    public func process(_ input: PCMBuffer) -> PCMBuffer {
        precondition(input.channelCount == channels, "channel count mismatch")
        precondition(input.frameCount <= Int(Int32.max), "input is too large")

        let ratio: Double
        switch mode {
        case .varispeed:
            ratio = min(2.0, max(0.06, tempoRatio)) * pow(2.0, pitchSemitones / 12.0)
        case .keyLock:
            ratio = min(2.0, max(0.06, tempoRatio))
        }
        let outputFrames = input.frameCount == 0
            ? 0
            : min(Int(Int32.max), max(1, Int(ceil(Double(input.frameCount) / ratio))))
        let output = PCMBuffer(format: input.format, capacity: outputFrames)
        guard outputFrames > 0 else { return output }

        var written: Int32 = 0
        input.withUnsafeChannels { inputChannels, frames in
            output.withUnsafeChannels { outputChannels, destinationFrames in
                inputChannels.withMemoryRebound(to: UnsafePointer<Float>?.self, capacity: channels) {
                    inputPointers in
                    outputChannels.withMemoryRebound(
                        to: UnsafeMutablePointer<Float>?.self, capacity: channels
                    ) { outputPointers in
                        written = pd_tp_process(
                            handle, UnsafePointer(inputPointers), Int32(frames),
                            UnsafePointer(outputPointers), Int32(destinationFrames)
                        )
                    }
                }
            }
        }

        // The offline API sizes its output from the requested ratio, but a C
        // kernel may return fewer frames for a partial/streaming call.
        if Int(written) == outputFrames { return output }
        let trimmed = PCMBuffer(format: input.format, capacity: max(0, Int(written)))
        for channel in 0..<channels {
            let source = output.channel(channel)
            let destination = trimmed.channel(channel)
            for frame in 0..<trimmed.frameCount { destination[frame] = source[frame] }
        }
        return trimmed
    }
}

/// 3-band full-kill isolator EQ (Pioneer-style). `-Float.infinity` == kill.
public final class Isolator3Band: @unchecked Sendable {
    // The handle is created/destroyed by the control-side object. Processing only
    // exchanges PCM pointers with the allocation-free C kernel.
    private let handle: OpaquePointer

    public init(sampleRate: Double, crossoverLow: Double = 200, crossoverHigh: Double = 2000) {
        guard let handle = pd_eq3_create(sampleRate, crossoverLow, crossoverHigh) else {
            preconditionFailure("invalid isolator EQ configuration")
        }
        self.handle = handle
    }

    deinit { pd_eq3_destroy(handle) }

    public func set(lowDB: Float, midDB: Float, highDB: Float) {
        pd_eq3_set(handle, lowDB, midDB, highDB)
    }

    public func processInPlace(_ buffer: PCMBuffer) {
        buffer.withUnsafeChannels { channels, frames in
            guard frames > 0, frames <= Int(Int32.max) else { return }
            for channel in 0..<buffer.channelCount {
                pd_eq3_process(handle, channels[channel], channels[channel], Int32(frames))
            }
        }
    }
}

/// Sweepable resonant filter (Color-FX default). `knob` -1..0 = LPF, 0..+1 = HPF.
public final class SweepFilter: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(sampleRate: Double) {
        guard let handle = pd_filter_create(sampleRate) else {
            preconditionFailure("invalid sweep filter sample rate")
        }
        self.handle = handle
    }

    deinit { pd_filter_destroy(handle) }

    public func set(knob: Float, resonance: Float = 0.3) {
        pd_filter_set(handle, knob, resonance)
    }

    public func processInPlace(_ buffer: PCMBuffer) {
        buffer.withUnsafeChannels { channels, frames in
            guard frames > 0, frames <= Int(Int32.max) else { return }
            for channel in 0..<buffer.channelCount {
                pd_filter_process(handle, channels[channel], channels[channel], Int32(frames))
            }
        }
    }
}

/// Fractional feedback delay/echo. Processing is allocation-free after initialization.
public final class Delay: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(sampleRate: Double, maxSeconds: Double = 2.0) {
        guard let handle = pd_delay_create(sampleRate, maxSeconds) else {
            preconditionFailure("invalid delay configuration")
        }
        self.handle = handle
    }

    deinit { pd_delay_destroy(handle) }

    public func set(timeSeconds: Double, feedback: Float, mix: Float) {
        pd_delay_set(handle, timeSeconds, feedback, mix)
    }

    public func processInPlace(_ buffer: PCMBuffer) {
        buffer.withUnsafeChannels { channels, frames in
            guard frames > 0, frames <= Int(Int32.max) else { return }
            for channel in 0..<buffer.channelCount {
                pd_delay_process(handle, channels[channel], channels[channel], Int32(frames))
            }
        }
    }
}

/// Freeverb-topology reverb. Delay-line storage is allocated during init;
/// processing is allocation-free and suitable for the real-time graph.
public final class Reverb: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(sampleRate: Double) {
        guard let handle = pd_reverb_create(sampleRate) else {
            preconditionFailure("invalid reverb sample rate")
        }
        self.handle = handle
    }

    deinit { pd_reverb_destroy(handle) }

    public func set(room: Float, damp: Float, width: Float, mix: Float) {
        pd_reverb_set(handle, room, damp, width, mix)
    }

    public func processInPlace(_ buffer: PCMBuffer) {
        buffer.withUnsafeChannels { channels, frames in
            guard frames > 0, frames <= Int(Int32.max) else { return }
            if buffer.channelCount == 1 {
                pd_reverb_process(handle, channels[0], channels[0], channels[0], channels[0], Int32(frames))
            } else {
                pd_reverb_process(handle, channels[0], channels[1], channels[0], channels[1], Int32(frames))
            }
        }
    }
}

/// Stereo look-ahead brick-wall limiter with a 75 ms release.
public final class Limiter: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(sampleRate: Double, ceilingDB: Float = -0.3) {
        guard let handle = pd_limiter_create(sampleRate, ceilingDB) else {
            preconditionFailure("invalid limiter configuration")
        }
        self.handle = handle
    }

    deinit { pd_limiter_destroy(handle) }

    public func processInPlace(_ buffer: PCMBuffer) {
        buffer.withUnsafeChannels { channels, frames in
            guard frames > 0, frames <= Int(Int32.max) else { return }
            if buffer.channelCount == 1 {
                pd_limiter_process(handle, channels[0], channels[0], Int32(frames))
            } else {
                pd_limiter_process(handle, channels[0], channels[1], Int32(frames))
            }
        }
    }
}
