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

public struct FLACVorbisComment: Sendable, Equatable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public enum ExportCodec: Sendable, Equatable {
    /// The default AAC-LC delivery bitrate used by convenience APIs.
    public static let defaultAACBitrate = 320_000
    /// The default CBR MP3 delivery bitrate used by convenience APIs.
    public static let defaultMP3Bitrate = 320
    /// The default Ogg Vorbis nominal bitrate used by convenience APIs.
    public static let defaultVorbisBitrate = 192

    case wavPCM(bitDepth: Int)   // via AVAudioFile / ExtAudioFile
    case flac(compression: Int)  // via libFLAC (Cflac) — PFLT float-preserving, 32-bit
    case aac(bitrate: Int)       // via AudioToolbox
    case alac                    // via AudioToolbox (lossless)
    case m4b(bitrate: Int)       // AAC-LC audiobook container via AudioToolbox
    case oggVorbis(bitrate: Int) // via Xiph libvorbisenc/libogg
    case mp3(bitrate: Int)       // via Glint (AudioToolbox has no MP3 encoder)
    /// Standard delivery FLAC: caller bit depth (16/24), Vorbis-comment tags,
    /// no PFLT block — the file other tools expect. `bitDepth` clamps to 16/24.
    case flacDelivery(bitDepth: Int, compression: Int, tags: [FLACVorbisComment])

    /// AAC-LC at 320 kbps, suitable for delivery and mix recording.
    public static let aacDefault: ExportCodec = .aac(bitrate: defaultAACBitrate)
    /// CBR MP3 at 320 kbps, suitable for delivery and mix recording.
    public static let mp3Default: ExportCodec = .mp3(bitrate: defaultMP3Bitrate)
    /// Ogg Vorbis at 192 kbps, suitable for portable delivery.
    public static let vorbisDefault: ExportCodec = .oggVorbis(bitrate: defaultVorbisBitrate)
}

/// Calls `body` with a C array of NUL-terminated pointers into `strings`,
/// each valid only for the duration of the call.
private func withArrayOfCStrings<R>(
    _ strings: [String],
    _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) -> R
) -> R {
    func recurse(_ index: Int, _ acc: [UnsafePointer<CChar>?]) -> R {
        if index == strings.count {
            return acc.withUnsafeBufferPointer { body($0) }
        }
        return strings[index].withCString { recurse(index + 1, acc + [$0]) }
    }
    return recurse(0, [])
}

/// The seam a host app uses to supply its own MP3 encoder — see
/// `docs/BYO-CODEC.md` for the full pattern and a worked LAME example.
///
/// PAE ships Glint as the zero-setup default (`.mp3` with no `mp3Encoder`
/// given) precisely so it never has to vendor a GPL/LGPL codec itself: an
/// app that wants a different encoder (LAME, or any other) implements this
/// protocol *in its own source* and passes an instance in, the same way
/// `StemModelProviding`/`NeuralModelProviding` let an app supply its own
/// model without PAE ever importing it (`Sources/ParsoAudioNeural/`).
public protocol MP3Encoding: Sendable {
    /// Encode `buffer` to a complete MP3 stream (including any headers/ID3
    /// the encoder writes) at `bitrateKbps`. Conformances own their own
    /// quality/VBR-vs-CBR choices; PAE only asks for a bitrate and bytes back.
    func encode(_ buffer: PCMBuffer, bitrateKbps: Int) throws -> Data
}

public struct AudioFileWriter {
    private let url: URL
    private let format: AudioFormat
    private let codec: ExportCodec
    private let mp3Encoder: (any MP3Encoding)?

    /// - Parameter mp3Encoder: overrides Glint for `.mp3` codecs with a
    ///   caller-supplied `MP3Encoding` conformance (e.g. an app-side LAME
    ///   wrapper). `nil` (the default) keeps the built-in Glint encoder —
    ///   PAE's own MP3 support never depends on this parameter being set.
    /// Creates a writer using AAC-LC at 320 kbps when no codec is supplied.
    /// Pass `.aac(bitrate:)`, `.oggVorbis(bitrate:)`, or `.mp3(bitrate:)` to select
    /// an explicit bitrate.
    public init(url: URL, format: AudioFormat, codec: ExportCodec = .aacDefault,
                mp3Encoder: (any MP3Encoding)? = nil) throws {
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioFileError.formatMismatch
        }
        self.url = url
        self.format = format
        self.codec = codec
        self.mp3Encoder = mp3Encoder
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
            try writeApple(buffer, formatID: kAudioFormatMPEG4AAC, bitrate: bitrate)
        case .alac:
            try writeApple(buffer, formatID: kAudioFormatAppleLossless, bitrate: 0)
        case .m4b(let bitrate):
            try writeApple(buffer, formatID: kAudioFormatMPEG4AAC, bitrate: bitrate)
        case .oggVorbis(let bitrate):
            try writeVorbis(buffer, bitrate: bitrate)
        case .mp3(let bitrate):
            if let mp3Encoder {
                let data = try mp3Encoder.encode(buffer, bitrateKbps: bitrate)
                do { try data.write(to: url) }
                catch { throw AudioFileError.writeFailed(error.localizedDescription) }
            } else {
                try writeGlint(buffer, bitrate: bitrate)
            }
        case .flacDelivery(let bitDepth, let compression, let tags):
            try writeFLACDelivery(buffer, bitDepth: bitDepth, compression: compression, tags: tags)
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

    private func writeFLACDelivery(
        _ buffer: PCMBuffer, bitDepth requestedDepth: Int, compression: Int, tags: [FLACVorbisComment]
    ) throws {
        let bitDepth = requestedDepth <= 16 ? 16 : 24
        let peak = Double(Int64(1) << (bitDepth - 1))
        // Truncate toward zero (not round) so the codes match a plain
        // `Int(sample * 2^(bits-1))` conversion bit for bit.
        let maxCode = peak - 1
        let minCode = -peak
        var interleaved = [Int32](repeating: 0, count: buffer.frameCount * buffer.channelCount)
        for frame in 0..<buffer.frameCount {
            for channel in 0..<buffer.channelCount {
                let scaled = Double(buffer.channel(channel)[frame]) * peak
                interleaved[frame * buffer.channelCount + channel] =
                    Int32(max(minCode, min(maxCode, scaled)))
            }
        }

        let keys = tags.map { $0.key }
        let values = tags.map { $0.value }
        let result = url.path.withCString { path in
            interleaved.withUnsafeBufferPointer { samples in
                withArrayOfCStrings(keys) { keyPtrs in
                    withArrayOfCStrings(values) { valuePtrs in
                        parso_flac_encode_file_tagged(
                            path,
                            samples.baseAddress,
                            UInt64(buffer.frameCount),
                            UInt32(buffer.channelCount),
                            UInt32(bitDepth),
                            UInt32(buffer.format.sampleRate.rounded()),
                            UInt32(max(0, compression)),
                            keyPtrs.baseAddress,
                            valuePtrs.baseAddress,
                            Int32(tags.count)
                        )
                    }
                }
            }
        }
        guard result == 0 else { throw AudioFileError.writeFailed("libFLAC delivery encode failed (\(result))") }
    }

    private func writeGlint(_ buffer: PCMBuffer, bitrate: Int) throws {
        let data = try AudioFileWriter.encodeMP3(buffer, bitrateKbps: bitrate)
        do { try data.write(to: url) }
        catch { throw AudioFileError.writeFailed(error.localizedDescription) }
    }

    private func writeVorbis(_ buffer: PCMBuffer, bitrate: Int) throws {
        guard bitrate >= 16, bitrate <= 512,
              buffer.frameCount > 0,
              buffer.channelCount >= 1, buffer.channelCount <= 2,
              buffer.frameCount <= Int.max / buffer.channelCount,
              buffer.format.sampleRate >= 8_000, buffer.format.sampleRate <= 48_000 else {
            throw AudioFileError.formatMismatch
        }
        var interleaved = [Float](repeating: 0,
                                  count: buffer.frameCount * buffer.channelCount)
        for frame in 0..<buffer.frameCount {
            for channel in 0..<buffer.channelCount {
                interleaved[frame * buffer.channelCount + channel] = buffer.channel(channel)[frame]
            }
        }
        var encoded: UnsafeMutablePointer<UInt8>?
        var encodedSize: UInt64 = 0
        let result = interleaved.withUnsafeBufferPointer { samples in
            parso_vorbis_encode_memory(
                samples.baseAddress,
                UInt64(buffer.frameCount),
                UInt32(buffer.channelCount),
                UInt32(buffer.format.sampleRate.rounded()),
                UInt32(bitrate),
                &encoded,
                &encodedSize
            )
        }
        guard result == 0, let encoded, encodedSize > 0,
              encodedSize <= UInt64(Int.max) else {
            if let encoded { parso_vorbis_free(encoded) }
            throw AudioFileError.writeFailed("Xiph Vorbis encode failed")
        }
        defer { parso_vorbis_free(encoded) }
        do { try Data(bytes: encoded, count: Int(encodedSize)).write(to: url) }
        catch { throw AudioFileError.writeFailed(error.localizedDescription) }
    }

    /// Codec-internal effort setting for `encodeMP3`. `.normal` matches the
    /// historical `AudioFileWriter` behaviour; `.best` is the closest analogue
    /// to LAME `-q2` for delivery encodes.
    public enum GlintQuality: Sendable {
        case speed, normal, best
        fileprivate var raw: Int32 {
            switch self {
            case .speed: return Int32(GLINT_QUALITY_SPEED.rawValue)
            case .normal: return Int32(GLINT_QUALITY_NORMAL.rawValue)
            case .best: return Int32(GLINT_QUALITY_BEST.rawValue)
            }
        }
    }

    /// Encode `buffer` to a complete CBR MP3 stream in memory (Glint — the only
    /// MP3 encoder available, AudioToolbox cannot encode MP3). `bitrateKbps` is
    /// the constant bitrate; `vbr_quality` is fixed at -1 (CBR). The caller may
    /// prepend an ID3v2 tag before writing the bytes to disk.
    public static func encodeMP3(
        _ buffer: PCMBuffer, bitrateKbps: Int, quality: GlintQuality = .normal
    ) throws -> Data {
        guard bitrateKbps > 0, buffer.frameCount > 0, buffer.frameCount <= Int(Int32.max),
              buffer.channelCount >= 1, buffer.channelCount <= 2,
              buffer.format.sampleRate > 0, buffer.format.sampleRate <= Double(Int32.max) else {
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
                Int32(GLINT_ENC_MP3.rawValue),
                Int32(bitrateKbps),
                -1,
                quality.raw,
                &outputSize
            )
        }
        guard let encoded, outputSize > 0 else {
            if let encoded { glint_free(encoded) }
            throw AudioFileError.writeFailed("Glint encode failed")
        }
        defer { glint_free(encoded) }
        return Data(bytes: encoded, count: Int(outputSize))
    }

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
}


