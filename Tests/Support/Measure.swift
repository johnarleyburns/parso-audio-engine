//
//  Measure.swift
//  Real, platform-independent measurement helpers used by assertions.
//  (Deliberately avoids Accelerate so tests measure independently of the impl.)
//

import Foundation
import ParsoAudioCore

public enum Measure {

    /// RMS level of a channel.
    public static func rms(_ buffer: PCMBuffer, channel: Int = 0) -> Double {
        let ch = buffer.channel(channel)
        guard buffer.frameCount > 0 else { return 0 }
        var acc = 0.0
        for v in ch { acc += Double(v) * Double(v) }
        return (acc / Double(buffer.frameCount)).squareRoot()
    }

    /// Peak absolute sample of a channel.
    public static func peak(_ buffer: PCMBuffer, channel: Int = 0) -> Float {
        var m: Float = 0
        for v in buffer.channel(channel) { m = max(m, abs(v)) }
        return m
    }

    /// Goertzel magnitude at a target frequency — cheap single-bin DFT for tone tests.
    public static func goertzelMagnitude(
        _ buffer: PCMBuffer, frequency: Double, channel: Int = 0
    ) -> Double {
        let ch = buffer.channel(channel)
        let n = buffer.frameCount
        guard n > 0 else { return 0 }
        let k = 2.0 * cos(2.0 * Double.pi * frequency / buffer.format.sampleRate)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for i in 0..<n { s0 = Double(ch[i]) + k * s1 - s2; s2 = s1; s1 = s0 }
        let power = s1 * s1 + s2 * s2 - k * s1 * s2
        return (power.magnitude).squareRoot() / Double(n)
    }

    /// Estimate the dominant frequency by scanning candidate bins with Goertzel.
    /// Coarse — for verifying pitch-shift/tone tests, not for production analysis.
    public static func dominantFrequency(
        _ buffer: PCMBuffer, searchRange: ClosedRange<Double> = 40...4000, stepHz: Double = 1
    ) -> Double {
        var bestF = searchRange.lowerBound
        var bestMag = -1.0
        var f = searchRange.lowerBound
        while f <= searchRange.upperBound {
            let m = goertzelMagnitude(buffer, frequency: f)
            if m > bestMag { bestMag = m; bestF = f }
            f += stepHz
        }
        return bestF
    }

    /// Convert a linear ratio to decibels.
    public static func dB(_ linear: Double) -> Double { 20.0 * log10(max(linear, 1e-12)) }
}
