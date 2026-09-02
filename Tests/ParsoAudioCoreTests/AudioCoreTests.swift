//
//  AudioCoreTests.swift
//  Enabled suites exercise the real PCMBuffer + generators. Suites that need the
//  DSP/IO layer are fully specified but `.disabled` until implemented (docs/SPEC.md §9, §13).
//

import Testing
import Foundation
import ParsoAudioCore
import ParsoTestSupport
import Calac

// MARK: - Real now

@Suite("PCMBuffer")
struct PCMBufferTests {
    @Test func allocatesZeroedChannels() {
        let b = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 2), capacity: 128)
        #expect(b.frameCount == 128)
        #expect(b.channelCount == 2)
        #expect(Measure.rms(b, channel: 0) == 0)
        #expect(Measure.rms(b, channel: 1) == 0)
    }

    @Test func channelReadWrite() {
        let b = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 1), capacity: 4)
        let ch = b.channel(0)
        ch[0] = 1; ch[1] = -1; ch[2] = 0.5; ch[3] = -0.5
        #expect(Measure.peak(b) == 1)
    }

    @Test func downmixCancellation() {
        let b = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 2), capacity: 8)
        for i in 0..<8 { b.channel(0)[i] = 1; b.channel(1)[i] = -1 }
        let mono = b.downmixedToMono()
        #expect(mono.channelCount == 1)
        #expect(Measure.peak(mono) == 0)
    }

    @Test func downmixAverage() {
        let b = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 2), capacity: 8)
        for i in 0..<8 { b.channel(0)[i] = 0.5; b.channel(1)[i] = 0.5 }
        #expect(abs(Double(b.downmixedToMono().channel(0)[0]) - 0.5) < 1e-6)
    }
}

@Suite("Signal generators")
struct SignalGeneratorTests {
    @Test func sineHasExpectedDominantFrequency() {
        let s = SignalGenerators.sine(frequency: 440, seconds: 0.5)
        let f = Measure.dominantFrequency(s, searchRange: 300...600, stepHz: 1)
        #expect(abs(f - 440) <= 2)
    }

    @Test func silenceIsSilent() {
        #expect(Measure.rms(SignalGenerators.silence(seconds: 0.1)) == 0)
    }

    @Test(arguments: [90.0, 120.0, 128.0])
    func clickTrackHasApproxCorrectBeatCount(bpm: Double) {
        let seconds = 4.0
        let t = SignalGenerators.clickTrack(bpm: bpm, seconds: seconds)
        // Count leading edges above a threshold (coarse).
        let ch = t.channel(0)
        var beats = 0
        var prevBelow = true
        for v in ch {
            let above = abs(v) > 0.5
            if above && prevBelow { beats += 1 }
            prevBelow = !above
        }
        let expected = Int(seconds * bpm / 60.0)
        #expect(abs(beats - expected) <= 1)
    }

    @Test func majorTriadEnergyLandsOnChordTones() {
        let c = SignalGenerators.triad(tonic: 0, major: true, seconds: 0.5)  // C major
        let root = Measure.goertzelMagnitude(c, frequency: 261.63)
        let third = Measure.goertzelMagnitude(c, frequency: 329.63)
        let fifth = Measure.goertzelMagnitude(c, frequency: 392.00)
        let nonChord = Measure.goertzelMagnitude(c, frequency: 277.18) // C#
        #expect(root > nonChord * 4)
        #expect(third > nonChord * 4)
        #expect(fifth > nonChord * 4)
    }

    @Test func concatLengthAndContent() {
        let a = SignalGenerators.sine(frequency: 100, seconds: 0.1)
        let b = SignalGenerators.silence(seconds: 0.1)
        let cat = SignalGenerators.concat([a, b])
        #expect(cat.frameCount == a.frameCount + b.frameCount)
        #expect(Measure.rms(a) > 0)
    }
}

// MARK: - Pending implementation (docs/SPEC.md §9, §13)

@Suite("Codec roundtrip")
struct CodecRoundtripTests {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    @Test func flacIsLossless() throws {
        let src = SignalGenerators.sine(frequency: 1000, seconds: 1.0, channels: 2)
        let url = tempURL("flac")
        let w = try AudioFileWriter(url: url, format: src.format, codec: .flac(compression: 5))
        try w.write(src); try w.finish()
        let back = try AudioFileReader(url: url, container: .flac).readAll()
        #expect(back.frameCount == src.frameCount)
        for c in 0..<src.channelCount {
            for i in 0..<src.frameCount { #expect(src.channel(c)[i] == back.channel(c)[i]) }
        }
    }

    @Test func wavIsExact() throws {
        let src = SignalGenerators.sine(frequency: 440, seconds: 0.5)
        let url = tempURL("wav")
        let w = try AudioFileWriter(url: url, format: src.format, codec: .wavPCM(bitDepth: 24))
        try w.write(src); try w.finish()
        let back = try AudioFileReader(url: url, container: .wav).readAll()
        #expect(back.frameCount == src.frameCount)
    }

#if canImport(AVFoundation)
    @Test func aacRoundtripIsBounded() throws {
        let src = SignalGenerators.sine(frequency: 440, seconds: 1.0, channels: 2)
        let url = tempURL("m4a")
        let w = try AudioFileWriter(url: url, format: src.format, codec: .aac(bitrate: 256_000))
        try w.write(src); try w.finish()
        let back = try AudioFileReader(url: url, container: .m4a).readAll()
        // Lossy: allow codec/priming delay; assert the tone survives, not sample-exactness.
        #expect(Measure.dominantFrequency(back, searchRange: 300...600) == 440)
    }
#else
    @Test func portableAacM4aEncodingRemainsUnsupportedOnLinux() throws {
        let src = SignalGenerators.sine(frequency: 440, seconds: 1.0, channels: 2)
        let url = tempURL("m4a")
        let writer = try AudioFileWriter(url: url, format: src.format, codec: .aac(bitrate: 256_000))
        #expect(throws: AudioFileError.self) { try writer.write(src) }
    }
#endif

    @Test func mp3RoundtripPreservesTheDominantTone() throws {
        let src = SignalGenerators.sine(frequency: 440, seconds: 1.0, channels: 2)
        let url = tempURL("mp3")
        let writer = try AudioFileWriter(url: url, format: src.format, codec: .mp3(bitrate: 192))
        try writer.write(src)
        try writer.finish()
        let back = try AudioFileReader(url: url, container: .mp3).readAll()
        #expect(back.frameCount > 0)
        #expect(Measure.dominantFrequency(back, searchRange: 300...600) == 440)
    }

#if !canImport(AVFoundation)
    @Test func portableAacAdtsRoundtripPreservesTheDominantTone() throws {
        let src = SignalGenerators.sine(frequency: 440, seconds: 1.0, channels: 2)
        let url = tempURL("aac")
        let writer = try AudioFileWriter(url: url, format: src.format, codec: .aac(bitrate: 192))
        try writer.write(src)
        try writer.finish()
        let back = try AudioFileReader(url: url, container: .aac).readAll()
        #expect(back.frameCount > 0)
        #expect(Measure.dominantFrequency(back, searchRange: 300...600) == 440)
    }

    @Test func portableAlacM4aRoundtripSupportsSeekAndDuration() throws {
        let src = SignalGenerators.sine(frequency: 440, seconds: 1.25, channels: 2)
        let url = tempURL("m4a")
        let writer = try AudioFileWriter(url: url, format: src.format, codec: .alac)
        try writer.write(src)
        try writer.finish()

        let reader = try AudioFileReader(url: url, container: .m4a)
        #expect(reader.frameCount == src.frameCount)
        #expect(reader.format == src.format)

        let window = PCMBuffer(format: src.format, capacity: 2_048)
        let read = try reader.read(into: window, frameOffset: 10_000)
        #expect(read == 2_048)
        #expect(abs(Double(window.channel(0)[0] - src.channel(0)[10_000])) < 1e-6)
        #expect(Measure.dominantFrequency(window, searchRange: 300...600) == 440)
    }

    @Test func portableAlacM4aRejectsMalformedContainer() throws {
        let url = tempURL("m4a")
        try Data([0, 0, 0, 8, 0x66, 0x74, 0x79, 0x70]).write(to: url)
        #expect(throws: AudioFileError.self) { _ = try AudioFileReader(url: url, container: .m4a) }
    }

    @Test func portableM4aMetadataReadsStandardTextItems() throws {
        let url = tempURL("m4a")
        try makeMetadataFixture().write(to: url)

        let metadata = try AudioFileReader.readMetadata(from: url, container: .m4a)
        #expect(metadata == AudioFileMetadata(title: "Café Session", artist: "Primary Artist", album: "Portable Tests"))
    }

    @Test func portableM4aMetadataRejectsMalformedAtoms() throws {
        let url = tempURL("m4a")
        try Data([0, 0, 0, 8, 0x6D, 0x6F, 0x6F, 0x76, 0, 0, 0, 4]).write(to: url)
        #expect(throws: AudioFileError.self) { _ = try AudioFileReader.readMetadata(from: url, container: .m4a) }
    }

    @Test func portableM4aMetadataReadsExternallyAuthoredFixture() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/m4a_external_metadata.m4a.b64")
        let encoded = try String(contentsOf: fixtureURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fixture = Data(base64Encoded: encoded) else {
            throw AudioFileError.invalidFile("external M4A fixture is not valid base64")
        }
        let url = tempURL("m4a")
        try fixture.write(to: url)

        let metadata = try AudioFileReader.readMetadata(from: url)
        #expect(metadata == AudioFileMetadata(title: "External Café", artist: "Fixture Artist", album: "Compatibility Album"))
    }

    @Test func portableM4aDecodesExternallyAuthoredAACProfile() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/m4a_external_aac.m4a.b64")
        let encoded = try String(contentsOf: fixtureURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fixture = Data(base64Encoded: encoded) else {
            throw AudioFileError.invalidFile("external AAC M4A fixture is not valid base64")
        }
        let url = tempURL("m4a")
        try fixture.write(to: url)

        let reader = try AudioFileReader(url: url, container: .m4a)
        #expect(reader.format == AudioFormat(sampleRate: 44_100, channelCount: 1))
        #expect(reader.frameCount == 11_025)
        #expect(Measure.rms(try reader.readAll()) > 0.001)
    }

    @Test func portableM4aDecodesExternallyAuthoredAACStereo48kProfile() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/m4a_external_aac_stereo_48k.m4a.b64")
        let encoded = try String(contentsOf: fixtureURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fixture = Data(base64Encoded: encoded) else {
            throw AudioFileError.invalidFile("external stereo AAC M4A fixture is not valid base64")
        }
        let url = tempURL("m4a")
        try fixture.write(to: url)

        let reader = try AudioFileReader(url: url, container: .m4a)
        #expect(reader.format == AudioFormat(sampleRate: 48_000, channelCount: 2))
        #expect(reader.frameCount == 24_000)
        let decoded = try reader.readAll()
        #expect(Measure.rms(decoded) > 0.001)
        #expect(abs(Measure.dominantFrequency(decoded, searchRange: 300...600) - 440) <= 2)
    }

    @Test func portableM4aRejectsSampleToChunkTableThatDoesNotCoverSamples() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/m4a_external_aac_stereo_48k.m4a.b64")
        let encoded = try String(contentsOf: fixtureURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard var fixture = Data(base64Encoded: encoded) else {
            throw AudioFileError.invalidFile("external stereo AAC M4A fixture is not valid base64")
        }
        let stsc = Data([0, 0, 0, 28, 0x73, 0x74, 0x73, 0x63])
        guard let stscOffset = fixture.firstRange(of: stsc)?.lowerBound else {
            throw AudioFileError.invalidFile("AAC fixture has no sample-to-chunk atom")
        }
        fixture[stscOffset + 20] = 1 // one sample in the only chunk; 25 are declared
        let url = tempURL("m4a")
        try fixture.write(to: url)

        #expect(throws: AudioFileError.self) { _ = try AudioFileReader(url: url, container: .m4a) }
    }

    @Test func portableM4aRejectsUnsupportedAACProfile() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/m4a_external_aac.m4a.b64")
        let encoded = try String(contentsOf: fixtureURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard var fixture = Data(base64Encoded: encoded) else {
            throw AudioFileError.invalidFile("external AAC fixture is not valid base64")
        }
        guard let configOffset = fixture.firstRange(of: Data([0x12, 0x08, 0x56, 0xE5]))?.lowerBound else {
            throw AudioFileError.invalidFile("AAC fixture has no expected decoder configuration")
        }
        fixture[configOffset] = 0x0A // object type 1: unsupported by the AAC-LC path
        let url = tempURL("m4a")
        try fixture.write(to: url)

        #expect(throws: AudioFileError.self) { _ = try AudioFileReader(url: url, container: .m4a) }
    }

    private func makeMetadataFixture() -> Data {
        func atom(_ type: [UInt8], _ payload: Data) -> Data {
            var result = Data()
            var size = UInt32(8 + payload.count).bigEndian
            withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
            result.append(contentsOf: type)
            result.append(payload)
            return result
        }
        func item(_ type: [UInt8], _ value: String) -> Data {
            var payload = Data(repeating: 0, count: 12)
            var typeIndicator = UInt32(1).bigEndian
            withUnsafeBytes(of: &typeIndicator) { payload.replaceSubrange(4..<8, with: $0) }
            payload.append(contentsOf: value.utf8)
            return atom(type, atom(Array("data".utf8), payload))
        }
        let ilst = atom(Array("ilst".utf8),
                        item([0xA9, 0x6E, 0x61, 0x6D], "Café Session") +
                        item(Array("aART".utf8), "Primary Artist") +
                        item([0xA9, 0x61, 0x6C, 0x62], "Portable Tests") +
                        item(Array("covr".utf8), "ignored artwork marker"))
        let meta = atom(Array("meta".utf8), Data(repeating: 0, count: 4) + ilst)
        return atom(Array("ftyp".utf8), Data([0x4D, 0x34, 0x41, 0x20])) +
            atom(Array("moov".utf8), atom(Array("udta".utf8), meta))
    }
#endif
}

@Suite("ALAC bridge")
struct ALACBridgeTests {
    private func packedPCM(bitDepth: Int, channels: Int, frames: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(frames * channels * ((bitDepth + 7) / 8))
        for frame in 0..<frames {
            for channel in 0..<channels {
                let base = Int32((frame * 37 + channel * 911) % 131_071) - 65_535
                let sample: Int32
                switch bitDepth {
                case 16:
                    sample = base % 30_000
                case 20:
                    sample = (base % 900_000) - 450_000
                case 24:
                    sample = (base * 31) % 8_000_000
                default:
                    sample = base * 32_001
                }
                let stored = bitDepth == 20 ? sample << 4 : sample
                if bitDepth == 24 || bitDepth == 20 {
                    let raw = UInt32(bitPattern: stored)
                    bytes.append(UInt8(truncatingIfNeeded: raw))
                    bytes.append(UInt8(truncatingIfNeeded: raw >> 8))
                    bytes.append(UInt8(truncatingIfNeeded: raw >> 16))
                } else if bitDepth == 16 {
                    var raw = UInt16(truncatingIfNeeded: stored).littleEndian
                    withUnsafeBytes(of: &raw) { bytes.append(contentsOf: $0) }
                } else {
                    var raw = UInt32(bitPattern: stored).littleEndian
                    withUnsafeBytes(of: &raw) { bytes.append(contentsOf: $0) }
                }
            }
        }
        return bytes
    }

    @Test(arguments: [16, 20, 24, 32])
    func integerPCMIsBitExact(bitDepth: Int) throws {
        let channels = 2
        let frames = 513
        let source = packedPCM(bitDepth: bitDepth, channels: channels, frames: frames)
        var encoder: OpaquePointer?
        #expect(parso_alac_encoder_create(44_100, UInt32(channels), UInt32(bitDepth), 4096, 0, &encoder) == PARSO_ALAC_OK)
        guard let encoder else { return }
        defer { parso_alac_encoder_destroy(encoder) }

        var cookie = [UInt8](repeating: 0, count: 48)
        var cookieSize = UInt32(cookie.count)
        let cookieResult = cookie.withUnsafeMutableBufferPointer {
            parso_alac_encoder_copy_magic_cookie(encoder, $0.baseAddress, UInt32($0.count), &cookieSize)
        }
        #expect(cookieResult == PARSO_ALAC_OK)
        #expect(cookieSize == 24)

        var packet: UnsafeMutablePointer<UInt8>?
        var packetBytes: UInt32 = 0
        let encodeResult = source.withUnsafeBufferPointer {
            parso_alac_encoder_encode(encoder, $0.baseAddress, UInt32(frames), &packet, &packetBytes)
        }
        #expect(encodeResult == PARSO_ALAC_OK)
        #expect(packetBytes > 0)
        guard let packet else { return }
        defer { parso_alac_free(packet) }

        var decoder: OpaquePointer?
        let decoderResult = cookie.withUnsafeBufferPointer {
            parso_alac_decoder_create($0.baseAddress, cookieSize, &decoder)
        }
        #expect(decoderResult == PARSO_ALAC_OK)
        guard let decoder else { return }
        defer { parso_alac_decoder_destroy(decoder) }

        let maximumDecodedBytes = 4096 * channels * ((bitDepth + 7) / 8)
        var decoded = [UInt8](repeating: 0, count: maximumDecodedBytes)
        var decodedFrames: UInt32 = 0
        let decodeResult = decoded.withUnsafeMutableBufferPointer {
            parso_alac_decoder_decode(decoder, packet, packetBytes, $0.baseAddress, UInt32($0.count), &decodedFrames)
        }
        #expect(decodeResult == PARSO_ALAC_OK)
        #expect(decodedFrames == UInt32(frames))
        #expect(Array(decoded.prefix(source.count)) == source)
        #expect(decoded.dropFirst(source.count).allSatisfy { $0 == 0 })
    }

    @Test func malformedCookieIsRejected() {
        var decoder: OpaquePointer?
        let cookie = [UInt8](repeating: 0, count: 24)
        let result = cookie.withUnsafeBufferPointer {
            parso_alac_decoder_create($0.baseAddress, UInt32($0.count), &decoder)
        }
        #expect(result == PARSO_ALAC_INVALID_ARGUMENT)
        #expect(decoder == nil)
    }
}

@Suite("Sample-rate conversion")
struct SampleRateTests {
    @Test func lengthRatioAndToneSurvive() throws {
        let src = SignalGenerators.sine(frequency: 1000, seconds: 1.0, sampleRate: 44_100)
        let conv = SampleRateConverter(from: 44_100, to: 48_000, channels: 1)
        let out = try conv.convert(src)
        let ratio = Double(out.frameCount) / Double(src.frameCount)
        #expect(abs(ratio - 48_000.0 / 44_100.0) < 0.01)
        #expect(abs(Measure.dominantFrequency(out, searchRange: 900...1100) - 1000) <= 3)
    }
}

@Suite("Isolator EQ")
struct IsolatorEQTests {
    @Test func lowKillRemovesBass() {
        let bass = SignalGenerators.sine(frequency: 60, seconds: 0.5)
        let eq = Isolator3Band(sampleRate: 44_100)
        eq.set(lowDB: -.infinity, midDB: 0, highDB: 0)   // kill lows
        eq.processInPlace(bass)
        #expect(Measure.dB(Measure.rms(bass)) < -60)
    }

    @Test func highKillRemovesTreble() {
        let treble = SignalGenerators.sine(frequency: 8000, seconds: 0.5)
        let eq = Isolator3Band(sampleRate: 44_100)
        eq.set(lowDB: 0, midDB: 0, highDB: -.infinity)
        eq.processInPlace(treble)
        #expect(Measure.dB(Measure.rms(treble)) < -60)
    }
}

@Suite("Sweep filter")
struct SweepFilterTests {
    @Test func lowPassSuppressesHighFrequency() {
        let input = SignalGenerators.sine(frequency: 8_000, seconds: 1.0)
        let filter = SweepFilter(sampleRate: 44_100)
        filter.set(knob: -1, resonance: 0)
        filter.processInPlace(input)
        #expect(Measure.dB(Measure.rms(input)) < -20)
    }

    @Test func highPassSuppressesLowFrequency() {
        let input = SignalGenerators.sine(frequency: 10, seconds: 1.0)
        let filter = SweepFilter(sampleRate: 44_100)
        filter.set(knob: 1, resonance: 0)
        filter.processInPlace(input)
        #expect(Measure.dB(Measure.rms(input)) < -20)
    }
}

@Suite("Delay")
struct DelayTests {
    @Test func impulseArrivesAtRequestedDelay() {
        let input = PCMBuffer(format: .init(sampleRate: 1_000, channelCount: 1), capacity: 64)
        input.channel(0)[0] = 1
        let delay = Delay(sampleRate: 1_000, maxSeconds: 0.1)
        delay.set(timeSeconds: 0.01, feedback: 0, mix: 1)
        delay.processInPlace(input)
        #expect(abs(input.channel(0)[10] - 1) < 0.01)
        #expect(Measure.peak(input) > 0.99)
    }

    @Test func feedbackProducesBoundedDecay() {
        let input = PCMBuffer(format: .init(sampleRate: 1_000, channelCount: 1), capacity: 64)
        input.channel(0)[0] = 1
        let delay = Delay(sampleRate: 1_000, maxSeconds: 0.1)
        delay.set(timeSeconds: 0.01, feedback: 0.5, mix: 1)
        delay.processInPlace(input)
        #expect(input.channel(0)[10] > 0.4)
        #expect(input.channel(0)[20] > 0.15)
        #expect(input.channel(0)[20] < input.channel(0)[10])
    }
}

@Suite("Reverb")
struct ReverbTests {
    @Test func impulseProducesStereoTail() {
        let input = PCMBuffer(format: .init(sampleRate: 44_100, channelCount: 2), capacity: 8_000)
        input.channel(0)[0] = 1
        input.channel(1)[0] = 1
        let reverb = Reverb(sampleRate: 44_100)
        reverb.set(room: 0.8, damp: 0.2, width: 1, mix: 1)
        reverb.processInPlace(input)

        #expect(input.channel(0).allSatisfy { $0.isFinite })
        #expect(input.channel(1).allSatisfy { $0.isFinite })
        #expect(Measure.rms(input, channel: 0) > 0.00001)
        #expect(Measure.rms(input, channel: 1) > 0.00001)
    }

    @Test func zeroMixPreservesDryStereo() {
        let input = PCMBuffer(format: .init(sampleRate: 48_000, channelCount: 2), capacity: 256)
        for frame in 0..<input.frameCount {
            input.channel(0)[frame] = 0.25
            input.channel(1)[frame] = -0.5
        }
        let reverb = Reverb(sampleRate: 48_000)
        reverb.set(room: 1, damp: 0, width: 1, mix: 0)
        reverb.processInPlace(input)

        #expect(abs(input.channel(0)[128] - 0.25) < 1e-6)
        #expect(abs(input.channel(1)[128] + 0.5) < 1e-6)
    }
}

@Suite("Time / pitch")
struct TimePitchTests {
    @Test func keyLockStretchesTimeNotPitch() {
        let src = SignalGenerators.sine(frequency: 440, seconds: 1.0)
        let tp = TimePitch(sampleRate: 44_100, channels: 1, maxBlock: 1024)
        tp.mode = .keyLock; tp.tempoRatio = 0.5     // half speed, same pitch
        let out = tp.process(src)
        #expect(Double(out.frameCount) / Double(src.frameCount) > 1.8)
        #expect(abs(Measure.dominantFrequency(out, searchRange: 380...500) - 440) <= 4)
    }

    @Test func pitchShiftMovesFundamental() {
        let src = SignalGenerators.sine(frequency: 440, seconds: 1.0)
        let tp = TimePitch(sampleRate: 44_100, channels: 1, maxBlock: 1024)
        tp.mode = .keyLock; tp.pitchSemitones = 12   // +1 octave
        let out = tp.process(src)
        #expect(abs(Measure.dominantFrequency(out, searchRange: 700...1000) - 880) <= 8)
    }

    @Test func varispeedCouplesPitchAndTime() {
        let src = SignalGenerators.sine(frequency: 440, seconds: 1.0)
        let tp = TimePitch(sampleRate: 44_100, channels: 1, maxBlock: 1024)
        tp.mode = .varispeed; tp.tempoRatio = 2.0    // double speed => +octave, half length
        let out = tp.process(src)
        #expect(Double(out.frameCount) / Double(src.frameCount) < 0.6)
        #expect(abs(Measure.dominantFrequency(out, searchRange: 700...1000) - 880) <= 8)
    }

    @Test func repeatedKeyLockProcessingStaysFinite() {
        let src = SignalGenerators.sine(frequency: 440, seconds: 0.25)
        let tp = TimePitch(sampleRate: 44_100, channels: 1, maxBlock: 1024)
        tp.mode = .keyLock; tp.tempoRatio = 0.8

        for _ in 0..<8 {
            let out = tp.process(src)
            #expect(out.frameCount > 0)
            #expect(out.channel(0).allSatisfy { $0.isFinite })
        }
    }
}

@Suite("Loudness")
struct LoudnessTests {
    @Test func computesGainTowardTarget() {
        let quiet = SignalGenerators.sine(frequency: 1000, seconds: 3.0, amplitude: 0.05)
        let r = LoudnessAnalyzer(targetLUFS: -14).measure(quiet)
        #expect(r.gainToTargetDB > 0)               // quiet source needs boosting
        #expect(r.integratedLUFS < -14)
    }
}
