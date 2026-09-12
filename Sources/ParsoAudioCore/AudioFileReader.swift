import Foundation
import CParsoDSP
import CGlint
import Cebur128
import Csrc
import CflacBridge
import CvorbisBridge
import CopusBridge
import AVFoundation
#if canImport(AudioToolbox)
import AudioToolbox
#endif

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
        case .mp3, .aac, .aiff, .caf, .m4a, .m4b:
            return try decodeApple(url: url)
        case .auto:
            throw AudioFileError.unsupportedContainer(container)
        }
    }

    /// Reads common text metadata without decoding the audio payload.
    ///
    /// This reader currently supports ISO-BMFF/M4A `©nam`, `©ART`,
    /// `©alb`, and `aART` items. Unsupported containers and malformed files
    /// are reported instead of being silently treated as audio metadata.
    public static func readMetadata(from url: URL, container: AudioContainer = .auto) throws -> AudioFileMetadata {
        let resolved = container.resolved(for: url)
        guard resolved == .m4a || resolved == .m4b else {
            throw AudioFileError.unsupportedContainer(resolved)
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw AudioFileError.invalidFile(error.localizedDescription) }
        return try MP4ALACCodec.readMetadata(data)
    }

    // MARK: - Bounded range decode

    /// Decode a bounded, contiguous span of a file without reading the rest of
    /// it — the path interactive seek / preview / trim workflows need for
    /// multi-hour sources. `.flac` positions with libFLAC's sample-accurate
    /// seek; the AVFoundation containers use `AVAudioFile.framePosition`.
    ///
    /// If the source cannot be positioned, `RangeDecodeError.notSeekable` is
    /// thrown — never a silent whole-file fallback.
    public static func decodeRange(
        url: URL,
        container: AudioContainer = .auto,
        range: AudioFrameRange
    ) throws -> RangeDecodeResult {
        guard range.startFrame >= 0, range.frameCount >= 0 else {
            throw RangeDecodeError.decodeFailed("negative range")
        }
        switch container.resolved(for: url) {
        case .flac:
            return try decodeFLACRange(url: url, range: range)
        case .wav, .aiff, .caf, .mp3, .aac, .m4a, .m4b:
            return try decodeAppleRange(url: url, range: range)
        case .oggVorbis, .opus:
            throw RangeDecodeError.notSeekable
        case .auto:
            throw RangeDecodeError.decodeFailed("unresolved container")
        }
    }

    private static func decodeFLACRange(url: URL, range: AudioFrameRange) throws -> RangeDecodeResult {
        var samples: UnsafeMutablePointer<Int32>?
        var frames: UInt64 = 0
        var channels: UInt32 = 0
        var sampleRate: UInt32 = 0
        var bitsPerSample: UInt32 = 0
        var seekUnsupported: Int32 = 0
        let status = url.path.withCString { path in
            parso_flac_decode_range(
                path,
                UInt64(range.startFrame),
                UInt64(range.frameCount),
                &samples, &frames, &channels, &sampleRate, &bitsPerSample, &seekUnsupported
            )
        }
        if seekUnsupported != 0 {
            if let samples { parso_flac_free(samples) }
            throw RangeDecodeError.notSeekable
        }
        guard status == 0, let samples, channels > 0, bitsPerSample > 0,
              frames <= UInt64(Int.max), frames <= UInt64(Int.max) / UInt64(channels) else {
            if let samples { parso_flac_free(samples) }
            throw RangeDecodeError.decodeFailed("libFLAC range decode failed")
        }
        defer { parso_flac_free(samples) }
        let frameCount = Int(frames)
        let channelCount = Int(channels)
        let scale = Float(1.0 / Double(Int64(1) << (bitsPerSample - 1)))
        let output = PCMBuffer(
            format: AudioFormat(sampleRate: Double(sampleRate), channelCount: channelCount),
            capacity: frameCount
        )
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                output.channel(channel)[frame] = Float(samples[frame * channelCount + channel]) * scale
            }
        }
        return RangeDecodeResult(buffer: output, decodedSourceFrames: frameCount)
    }

    private static func decodeAppleRange(url: URL, range: AudioFrameRange) throws -> RangeDecodeResult {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw RangeDecodeError.decodeFailed(error.localizedDescription) }
        let sourceFormat = file.processingFormat
        let total = file.length
        let start = max(0, min(range.startFrame, total))
        let count = max(0, min(Int64(range.frameCount), total - start))
        file.framePosition = start
        guard count > 0 else {
            return RangeDecodeResult(
                buffer: PCMBuffer(
                    format: AudioFormat(sampleRate: sourceFormat.sampleRate, channelCount: Int(sourceFormat.channelCount)),
                    capacity: 0
                ),
                decodedSourceFrames: 0
            )
        }
        guard let audioBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(count)
        ) else { throw RangeDecodeError.decodeFailed("could not allocate decode buffer") }
        do { try file.read(into: audioBuffer) }
        catch { throw RangeDecodeError.decodeFailed(error.localizedDescription) }
        guard let channels = audioBuffer.floatChannelData else {
            throw RangeDecodeError.decodeFailed("decoded audio is not float PCM")
        }
        let decoded = Int(audioBuffer.frameLength)
        let output = PCMBuffer(
            format: AudioFormat(sampleRate: sourceFormat.sampleRate, channelCount: Int(sourceFormat.channelCount)),
            capacity: decoded
        )
        for channel in 0..<output.channelCount {
            for frame in 0..<decoded { output.channel(channel)[frame] = channels[channel][frame] }
        }
        return RangeDecodeResult(buffer: output, decodedSourceFrames: decoded)
    }

    private static func decodeFLAC(url: URL) throws -> PCMBuffer {
        var samples: UnsafeMutablePointer<Int32>?
        var exactFloatBits: UnsafeMutablePointer<UInt32>?
        var frames: UInt64 = 0
        var channels: UInt32 = 0
        var sampleRate: UInt32 = 0
        var bitsPerSample: UInt32 = 0
        let result = url.path.withCString { path in
            parso_flac_decode_file(path, &samples, &exactFloatBits, &frames, &channels, &sampleRate, &bitsPerSample)
        }
        guard result == 0, let samples, channels > 0, bitsPerSample > 0, bitsPerSample <= 32,
              frames <= UInt64(Int.max), frames <= UInt64(Int.max) / UInt64(channels) else {
            if let samples { parso_flac_free(samples) }
            if let exactFloatBits { parso_flac_free(exactFloatBits) }
            throw AudioFileError.invalidFile("libFLAC decode failed")
        }
        defer { parso_flac_free(samples) }
        defer { if let exactFloatBits { parso_flac_free(exactFloatBits) } }
        let frameCount = Int(frames)
        let channelCount = Int(channels)
        // libFLAC delivers samples right-aligned in `bits_per_sample` bits, so the
        // integer path must scale by 2^(bits-1). The PFLT float block, when
        // present, carries the exact original float and overrides the scale.
        let scale = Float(1.0 / Double(Int64(1) << (bitsPerSample - 1)))
        let output = PCMBuffer(
            format: AudioFormat(sampleRate: Double(sampleRate), channelCount: channelCount),
            capacity: frameCount
        )
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let index = frame * channelCount + channel
                output.channel(channel)[frame] = exactFloatBits.map {
                    Float(bitPattern: $0[index])
                } ?? (Float(samples[index]) * scale)
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
            throw AudioFileError.invalidFile("Xiph Vorbis decode failed")
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
}

/// Export codecs. AAC and ALAC go through AVFoundation; Ogg Vorbis goes through
/// the permissively licensed Xiph encoder; MP3 goes through the vendored Glint
/// encoder, which is the only MP3 encoder available — AudioToolbox cannot encode MP3.
/// One Vorbis comment (FLAC metadata tag), e.g. `key: "TITLE"`, `value: "…"`.

