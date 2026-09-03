//
//  RangeDecodeTests.swift
//  Bounded range decode (AudioFileReader.decodeRange) — the interactive
//  seek/preview path. FLAC positions with libFLAC's sample-accurate seek; the
//  AVFoundation containers use AVAudioFile.framePosition. Neither ever falls
//  back to a silent whole-file decode.
//

import Testing
import Foundation
import ParsoAudioCore
import ParsoTestSupport

@Suite("Range decode")
struct RangeDecodeTests {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    /// A long single-channel FLAC. Two detuned tones give every short window a
    /// distinct shape, so a range slice can be checked against the whole-file
    /// decode positionally.
    private func makeToneFLAC(frames: Int, sampleRate: Double = 44_100) throws -> URL {
        let buf = PCMBuffer(format: .init(sampleRate: sampleRate, channelCount: 1), capacity: frames)
        let ch = buf.channel(0)
        let w0 = 2.0 * Double.pi * 220.0 / sampleRate
        let w1 = 2.0 * Double.pi * 277.183 / sampleRate
        for i in 0..<frames {
            ch[i] = 0.4 * Float(sin(w0 * Double(i))) + 0.3 * Float(sin(w1 * Double(i)))
        }
        let url = tempURL("flac")
        let writer = try AudioFileWriter(url: url, format: buf.format, codec: .flac(compression: 4))
        try writer.write(buf); try writer.finish()
        return url
    }

    @Test func flacRangeNearEndMatchesWholeDecodeSlice() throws {
        let total = 300_000
        let url = try makeToneFLAC(frames: total)
        defer { try? FileManager.default.removeItem(at: url) }

        let whole = try AudioFileReader(url: url, container: .flac).readAll()
        #expect(whole.frameCount == total)

        let start = total - 40_000
        let want = 25_000
        let result = try AudioFileReader.decodeRange(
            url: url, container: .flac,
            range: AudioFrameRange(startFrame: Int64(start), frameCount: want)
        )
        #expect(result.buffer.frameCount == want)
        // The whole-file path reconstructs exact float bits from the PFLT block;
        // the range path rebuilds from 32-bit integer PCM, so they agree only to
        // int32 quantization (~1e-7), not bit-for-bit.
        for i in 0..<want {
            #expect(abs(result.buffer.channel(0)[i] - whole.channel(0)[start + i]) < 1e-5)
        }
    }

    @Test func flacRangeDecodeIsBoundedNotWholeFile() throws {
        let total = 400_000
        let url = try makeToneFLAC(frames: total)
        defer { try? FileManager.default.removeItem(at: url) }

        let want = 20_000
        let result = try AudioFileReader.decodeRange(
            url: url, container: .flac,
            range: AudioFrameRange(startFrame: 350_000, frameCount: want)
        )
        // The decoder should touch roughly the requested span (plus at most a
        // block of frame-alignment slack), never a quarter of the whole file.
        #expect(result.decodedSourceFrames >= want)
        #expect(result.decodedSourceFrames < want + 8_192)
        #expect(result.decodedSourceFrames < total / 4)
    }

    @Test func flacRangeClampsPastEndOfStream() throws {
        let total = 50_000
        let url = try makeToneFLAC(frames: total)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try AudioFileReader.decodeRange(
            url: url, container: .flac,
            range: AudioFrameRange(startFrame: 45_000, frameCount: 20_000)
        )
        #expect(result.buffer.frameCount == total - 45_000)
    }

    @Test func appleContainerRangeMatchesWholeDecodeSlice() throws {
        let src = SignalGenerators.sine(frequency: 440, seconds: 4.0)
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try AudioFileWriter(url: url, format: src.format, codec: .wavPCM(bitDepth: 16))
        try w.write(src); try w.finish()

        let whole = try AudioFileReader(url: url, container: .wav).readAll()
        let start = 100_000
        let want = 30_000
        let result = try AudioFileReader.decodeRange(
            url: url, container: .wav,
            range: AudioFrameRange(startFrame: Int64(start), frameCount: want)
        )
        #expect(result.buffer.frameCount == want)
        for i in stride(from: 0, to: want, by: 617) {
            #expect(abs(result.buffer.channel(0)[i] - whole.channel(0)[start + i]) < 1e-4)
        }
    }

    @Test func oggAndOpusReportNotSeekable() throws {
        let src = SignalGenerators.sine(frequency: 440, seconds: 0.5)
        let url = tempURL("opus")
        // No opus writer; the container resolves by extension and the range API
        // rejects it before touching the (absent) file.
        _ = src
        #expect(throws: RangeDecodeError.notSeekable) {
            _ = try AudioFileReader.decodeRange(
                url: url, container: .opus,
                range: AudioFrameRange(startFrame: 0, frameCount: 1_000)
            )
        }
    }
}
