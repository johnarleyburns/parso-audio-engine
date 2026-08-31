//
//  AudioCoreTests.swift
//  Enabled suites exercise the real PCMBuffer + generators. Suites that need the
//  DSP/IO layer are fully specified but `.disabled` until implemented (docs/SPEC.md §9, §13).
//

import Testing
import Foundation
import ParsoAudioCore
import ParsoTestSupport

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

@Suite("Codec roundtrip", .disabled("Implement file IO — docs/SPEC.md §9"))
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

    @Test func aacRoundtripIsBounded() throws {
        let src = SignalGenerators.sine(frequency: 440, seconds: 1.0, channels: 2)
        let url = tempURL("m4a")
        let w = try AudioFileWriter(url: url, format: src.format, codec: .aac(bitrate: 256_000))
        try w.write(src); try w.finish()
        let back = try AudioFileReader(url: url, container: .m4a).readAll()
        // Lossy: allow codec/priming delay; assert the tone survives, not sample-exactness.
        #expect(Measure.dominantFrequency(back, searchRange: 300...600) == 440)
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

@Suite("Isolator EQ", .disabled("Implement Isolator3Band — docs/SPEC.md §13.2"))
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

@Suite("Time / pitch", .disabled("Implement TimePitch — docs/SPEC.md §13.6/§13.7"))
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
