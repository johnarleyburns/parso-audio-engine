//
//  SignalGenerators.swift
//  Deterministic synthetic signals for tests. Real, dependency-free code — these
//  build actual PCMBuffers so tests can run before the DSP/analysis layers exist.
//

import Foundation
import ParsoAudioCore

public enum SignalGenerators {

    /// A sine tone. `channels` copies the same signal to each channel.
    public static func sine(
        frequency: Double, seconds: Double, sampleRate: Double = 44_100,
        amplitude: Float = 0.5, channels: Int = 1
    ) -> PCMBuffer {
        let frames = Int(seconds * sampleRate)
        let buf = PCMBuffer(format: .init(sampleRate: sampleRate, channelCount: channels), capacity: frames)
        let w = 2.0 * Double.pi * frequency / sampleRate
        for c in 0..<channels {
            let ch = buf.channel(c)
            for i in 0..<frames { ch[i] = amplitude * Float(sin(w * Double(i))) }
        }
        return buf
    }

    /// Silence of a given duration.
    public static func silence(seconds: Double, sampleRate: Double = 44_100, channels: Int = 1) -> PCMBuffer {
        PCMBuffer(format: .init(sampleRate: sampleRate, channelCount: channels),
                  capacity: Int(seconds * sampleRate))
    }

    /// Deterministic pseudo-random white noise (fixed seed).
    public static func whiteNoise(
        seconds: Double, sampleRate: Double = 44_100, amplitude: Float = 0.25,
        channels: Int = 1, seed: UInt64 = 0x9E3779B97F4A7C15
    ) -> PCMBuffer {
        let frames = Int(seconds * sampleRate)
        let buf = PCMBuffer(format: .init(sampleRate: sampleRate, channelCount: channels), capacity: frames)
        var state = seed
        func next() -> Float {  // xorshift64* -> [-1, 1)
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            let u = (state &* 0x2545F4914F6CDD1D) >> 11
            return Float(Double(u) / Double(1 << 53)) * 2 - 1
        }
        for i in 0..<frames {
            let v = next() * amplitude
            for c in 0..<channels { buf.channel(c)[i] = v }
        }
        return buf
    }

    /// A metronome click track at a fixed BPM: short decaying impulses on each beat.
    /// Ground truth for tempo detection (the click period is exactly 60/bpm).
    public static func clickTrack(
        bpm: Double, seconds: Double, sampleRate: Double = 44_100,
        amplitude: Float = 0.9, clickMs: Double = 6, channels: Int = 1
    ) -> PCMBuffer {
        let frames = Int(seconds * sampleRate)
        let buf = PCMBuffer(format: .init(sampleRate: sampleRate, channelCount: channels), capacity: frames)
        let period = Int(round(60.0 / bpm * sampleRate))
        let clickLen = max(1, Int(clickMs / 1000.0 * sampleRate))
        var beat = 0
        while beat * period < frames {
            let start = beat * period
            for k in 0..<clickLen where start + k < frames {
                let env = Float(exp(-Double(k) / Double(clickLen) * 5.0))     // fast decay
                let s = amplitude * env
                for c in 0..<channels { buf.channel(c)[start + k] += s }
            }
            beat += 1
        }
        return buf
    }

    /// A sustained triad (root, third, fifth) for a given key/mode — ground truth for key detection.
    /// `tonic` 0=C..11=B. Major uses +4/+7 semitones; minor uses +3/+7.
    public static func triad(
        tonic: Int, major: Bool, seconds: Double, sampleRate: Double = 44_100,
        rootHz: Double = 261.63 /* C4 */, amplitude: Float = 0.3, channels: Int = 1
    ) -> PCMBuffer {
        let third = major ? 4 : 3
        let semis = [0, third, 7]
        let freqs = semis.map { rootHz * pow(2.0, Double(tonic + $0) / 12.0) }
        let frames = Int(seconds * sampleRate)
        let buf = PCMBuffer(format: .init(sampleRate: sampleRate, channelCount: channels), capacity: frames)
        for f in freqs {
            let w = 2 * Double.pi * f / sampleRate
            for i in 0..<frames {
                let s = amplitude / Float(freqs.count) * Float(sin(w * Double(i)))
                for c in 0..<channels { buf.channel(c)[i] += s }
            }
        }
        return buf
    }

    /// Concatenate buffers (same format) into one — for building structured signals.
    public static func concat(_ parts: [PCMBuffer]) -> PCMBuffer {
        precondition(!parts.isEmpty)
        let fmt = parts[0].format
        let total = parts.reduce(0) { $0 + $1.frameCount }
        let out = PCMBuffer(format: fmt, capacity: total)
        var offset = 0
        for p in parts {
            for c in 0..<fmt.channelCount {
                let src = p.channel(min(c, p.channelCount - 1))
                let dst = out.channel(c)
                for i in 0..<p.frameCount { dst[offset + i] = src[i] }
            }
            offset += p.frameCount
        }
        return out
    }
}
