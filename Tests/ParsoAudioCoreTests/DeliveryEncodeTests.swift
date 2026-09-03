//
//  DeliveryEncodeTests.swift
//  Delivery-grade encoders: standard 16/24-bit FLAC with Vorbis comments (no
//  PFLT float block), and CBR MP3 whose every frame header carries the same
//  bitrate / sample rate / channel mode (the LibriVox / ACX contract).
//

import Testing
import Foundation
import ParsoAudioCore
import ParsoTestSupport

@Suite("Delivery encode")
struct DeliveryEncodeTests {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    @Test func deliveryFLACRoundTripsBitExactAt16() throws {
        let src = SignalGenerators.sine(frequency: 440, seconds: 1.5, amplitude: 0.7, channels: 1)
        let url = tempURL("flac")
        defer { try? FileManager.default.removeItem(at: url) }

        let tags = [
            FLACVorbisComment(key: "TITLE", value: "Delivery Test"),
            FLACVorbisComment(key: "ARTIST", value: "PAE"),
        ]
        let w = try AudioFileWriter(
            url: url, format: src.format,
            codec: .flacDelivery(bitDepth: 16, compression: 5, tags: tags)
        )
        try w.write(src); try w.finish()

        let back = try AudioFileReader(url: url, container: .flac).readAll()
        #expect(back.frameCount == src.frameCount)
        // Both sides quantised to 16-bit integer PCM must agree exactly.
        func q16(_ x: Float) -> Int { Int(max(-32_768, min(32_767, Double(x) * 32_768))) }
        var mismatches = 0
        for i in 0..<src.frameCount where q16(src.channel(0)[i]) != q16(back.channel(0)[i]) {
            mismatches += 1
        }
        #expect(mismatches == 0)
    }

    @Test func deliveryFLACWritesVorbisCommentsAndNoPFLT() throws {
        let src = SignalGenerators.sine(frequency: 220, seconds: 0.4)
        let delivery = tempURL("flac")
        let internalFLAC = tempURL("flac")
        defer { try? FileManager.default.removeItem(at: delivery); try? FileManager.default.removeItem(at: internalFLAC) }

        try AudioFileWriter(
            url: delivery, format: src.format,
            codec: .flacDelivery(bitDepth: 16, compression: 5, tags: [FLACVorbisComment(key: "TITLE", value: "Zaphod")])
        ).write(src)
        try AudioFileWriter(url: internalFLAC, format: src.format, codec: .flac(compression: 5)).write(src)

        let deliveryBytes = try Data(contentsOf: delivery)
        let internalBytes = try Data(contentsOf: internalFLAC)

        // The Vorbis comment block stores keys/values as plain UTF-8.
        #expect(deliveryBytes.range(of: Data("TITLE=Zaphod".utf8)) != nil)
        // "PFLT" is PAE's private float-preserving APPLICATION id — present in the
        // internal path, absent from a delivery file.
        #expect(internalBytes.range(of: Data("PFLT".utf8)) != nil)
        #expect(deliveryBytes.range(of: Data("PFLT".utf8)) == nil)
    }

    /// Level / spectral-centroid guard for the Glint CBR MP3 path (it replaced
    /// LAME in the audio-engine unification). Encodes a voice-band multi-tone,
    /// decodes it back, and checks loudness and the three source tones survive.
    /// A full perceptual A-B against LAME on real narration is an author task
    /// (needs the LAME reference + narration fixtures) — see current_status.md.
    @Test func mp3EncodePreservesLevelAndTones() throws {
        let sampleRate = 44_100.0
        let frames = Int(sampleRate * 4)
        let toneHz = [320.0, 1_100.0, 2_700.0]
        let src = PCMBuffer(format: .init(sampleRate: sampleRate, channelCount: 1), capacity: frames)
        let ch = src.channel(0)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let s = 0.6 * sin(2 * .pi * toneHz[0] * t)
                + 0.3 * sin(2 * .pi * toneHz[1] * t)
                + 0.15 * sin(2 * .pi * toneHz[2] * t)
            ch[i] = Float(s * 0.4)
        }

        let data = try AudioFileWriter.encodeMP3(src, bitrateKbps: 192, quality: .best)
        let url = tempURL("mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let back = try AudioFileReader(url: url, container: .mp3).readAll()

        func goertzel(_ buffer: PCMBuffer, _ freq: Double) -> Double {
            let start = min(8_192, max(0, buffer.frameCount - 1))
            let n = min(buffer.frameCount - start, 1 << 15)
            let coeff = 2 * cos(2 * .pi * freq / buffer.format.sampleRate)
            var s1 = 0.0, s2 = 0.0
            let c = buffer.channel(0)
            for i in start..<(start + n) { let s0 = Double(c[i]) + coeff * s1 - s2; s2 = s1; s1 = s0 }
            return ((s1 * s1 + s2 * s2 - coeff * s1 * s2).squareRoot()) / Double(n)
        }

        // Each source tone must dominate a nearby off-tone bin in the decode.
        for f in toneHz {
            #expect(goertzel(back, f) > 8 * goertzel(back, f + 90), "tone \(f) Hz not preserved")
        }
        let srcRMS = (0..<src.frameCount).reduce(0.0) { $0 + Double(src.channel(0)[$1] * src.channel(0)[$1]) }
        let backRMS = (0..<back.frameCount).reduce(0.0) { $0 + Double(back.channel(0)[$1] * back.channel(0)[$1]) }
        let rmsRatio = (backRMS / Double(back.frameCount)) / (srcRMS / Double(src.frameCount))
        #expect(rmsRatio > 0.6 && rmsRatio < 1.5, "RMS ratio \(rmsRatio) — MP3 level error")
    }

    @Test func mp3EncodeIsConstantBitrate() throws {
        let src = SignalGenerators.sine(frequency: 440, seconds: 6.0, amplitude: 0.6, channels: 1)
        let data = try AudioFileWriter.encodeMP3(src, bitrateKbps: 128, quality: .best)

        let frames = MP3Frames.parse(data)
        #expect(frames.count > 100)
        #expect(frames.allSatisfy { $0.bitrateKbps == 128 })
        #expect(frames.allSatisfy { $0.sampleRateHz == 44_100 })
        #expect(frames.allSatisfy { $0.channelMode == 3 }) // 3 = single channel (mono)
        // 6 s @ 128 kbps ≈ 96 KB; allow generous slack for the tag/padding.
        #expect(data.count < 120_000)
    }
}

/// Minimal MPEG-1 Audio Layer III frame-header walker — enough to prove CBR.
private enum MP3Frames {
    struct Frame { var bitrateKbps: Int; var sampleRateHz: Int; var channelMode: Int }

    private static let bitrateV1L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, -1]
    private static let sampleRateV1 = [44_100, 48_000, 32_000, -1]

    static func parse(_ data: Data) -> [Frame] {
        var frames: [Frame] = []
        let bytes = [UInt8](data)
        var i = 0
        // Skip an ID3v2 tag if present.
        if bytes.count > 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            let size = (Int(bytes[6]) << 21) | (Int(bytes[7]) << 14) | (Int(bytes[8]) << 7) | Int(bytes[9])
            i = 10 + size
        }
        while i + 4 <= bytes.count {
            guard bytes[i] == 0xFF, (bytes[i + 1] & 0xE0) == 0xE0 else { i += 1; continue }
            let versionBits = (bytes[i + 1] >> 3) & 0x03   // 3 = MPEG-1
            let layerBits = (bytes[i + 1] >> 1) & 0x03      // 1 = Layer III
            let bitrateIdx = Int((bytes[i + 2] >> 4) & 0x0F)
            let rateIdx = Int((bytes[i + 2] >> 2) & 0x03)
            let padding = Int((bytes[i + 2] >> 1) & 0x01)
            let mode = Int((bytes[i + 3] >> 6) & 0x03)
            guard versionBits == 3, layerBits == 1, bitrateIdx > 0, bitrateIdx < 15, rateIdx < 3 else {
                i += 1; continue
            }
            let kbps = bitrateV1L3[bitrateIdx]
            let rate = sampleRateV1[rateIdx]
            frames.append(Frame(bitrateKbps: kbps, sampleRateHz: rate, channelMode: mode))
            let frameLen = (144 * kbps * 1000) / rate + padding
            i += max(frameLen, 1)
        }
        return frames
    }
}
