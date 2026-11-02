//
//  DropDetector.swift
//  Kick-band drop/bass-exit detection, ported from parso-tonearm's
//  tools/blend-lab/structure.py (2026-10-08 "Blend lab: groove-placed,
//  drop-aligned DJ blends"). That tool brick-wall-filters the kick band via
//  FFT bin zeroing; this port uses an equivalent cascaded bandpass biquad
//  (RBJ cookbook) for the same 35-160 Hz isolation without a full-buffer FFT,
//  verified against the reference tool's own event-detection behavior (a
//  genuine +dropThresholdDB step is still the sharpest nearby one either way).
//

import Foundation

/// One cascaded second-order bandpass stage (RBJ cookbook, constant-skirt-gain
/// peak response), run twice in series for a steeper ~35-160 Hz passband.
private struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(centerHz: Double, qualityQ: Double, sampleRate: Double) {
        let omega = 2 * Double.pi * centerHz / sampleRate
        let alpha = sin(omega) / (2 * qualityQ)
        let cosOmega = cos(omega)
        let a0 = 1 + alpha
        b0 = alpha / a0
        b1 = 0
        b2 = -alpha / a0
        a1 = -2 * cosOmega / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ x0: Double) -> Double {
        let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x0
        y2 = y1; y1 = y0
        return y0
    }
}

/// Isolates the kick band and reports its level per beat, then finds the drop/bass-exit events
/// a DJ-style blend needs: a drop is the beat where the bass comes back (the mean kick-band level
/// over the next `spanBeats` beats is `thresholdDB` above the previous `spanBeats`, and it is the
/// sharpest such step nearby); a bass exit is the reverse (a breakdown or the outro starting).
public enum DropDetector {
    public static let defaultThresholdDB = 6.0
    public static let defaultSpanBeats = 8
    public static let kickBandLowHz = 35.0
    public static let kickBandHighHz = 160.0

    /// Kick-band (35-160 Hz) RMS level per inter-beat interval, in dB (`beatSamples.count - 1`
    /// entries; empty for fewer than 2 beats). `-120` for a silent/empty interval, never `-infinity`.
    public static func bassLevelsDB(_ pcm: AnalysisAudio, beatSamples: [Int64]) -> [Double] {
        guard beatSamples.count > 1, pcm.frameCount > 0 else { return [] }
        let centerHz = (kickBandLowHz * kickBandHighHz).squareRoot()
        let bandwidthOctaves = log2(kickBandHighHz / kickBandLowHz)
        // Q for a given bandwidth in octaves (RBJ cookbook): Q = sqrt(2^bw) / (2^bw - 1).
        let twoPowBW = pow(2, bandwidthOctaves)
        let q = twoPowBW.squareRoot() / (twoPowBW - 1)
        var stage1 = Biquad(centerHz: centerHz, qualityQ: q, sampleRate: pcm.sampleRate)
        var stage2 = Biquad(centerHz: centerHz, qualityQ: q, sampleRate: pcm.sampleRate)
        var filtered = [Double](repeating: 0, count: pcm.frameCount)
        let mono = pcm.mono
        for i in 0..<pcm.frameCount {
            filtered[i] = stage2.process(stage1.process(Double(mono[i])))
        }
        var levels: [Double] = []
        levels.reserveCapacity(beatSamples.count - 1)
        for i in 0..<(beatSamples.count - 1) {
            let a = max(0, Int(beatSamples[i])), b = min(filtered.count, Int(beatSamples[i + 1]))
            guard b > a else { levels.append(-120); continue }
            var sumSquares = 0.0
            for s in a..<b { sumSquares += filtered[s] * filtered[s] }
            let meanSquare = sumSquares / Double(b - a)
            levels.append(10 * log10(meanSquare + 1e-12))
        }
        return levels
    }

    /// Beat indices (into `bassLevelsDB`, offset by `spanBeats` from either end) where the signed
    /// `spanBeats`-beat step is >= `thresholdDB` and is the local maximum within `±spanBeats`.
    /// `sign: +1` finds drops (bass returning); `sign: -1` finds bass exits (bass leaving).
    public static func events(
        bassLevelsDB db: [Double], sign: Double,
        spanBeats: Int = defaultSpanBeats, thresholdDB: Double = defaultThresholdDB
    ) -> [Int] {
        let n = db.count
        guard n > 2 * spanBeats else { return [] }
        var step = [Double](repeating: 0, count: n)
        for i in spanBeats..<(n - spanBeats) {
            let after = db[i..<(i + spanBeats)].reduce(0, +) / Double(spanBeats)
            let before = db[(i - spanBeats)..<i].reduce(0, +) / Double(spanBeats)
            step[i] = sign * (after - before)
        }
        var out: [Int] = []
        for i in spanBeats..<(n - spanBeats) {
            let lo = max(0, i - spanBeats), hi = min(n, i + spanBeats)
            let localMax = step[lo..<hi].max() ?? -Double.infinity
            if step[i] >= thresholdDB && step[i] == localMax { out.append(i) }
        }
        return out
    }

    /// Both drop and bass-exit beat indices for `pcm` against `beatSamples` in one call.
    public static func dropsAndExits(
        _ pcm: AnalysisAudio, beatSamples: [Int64],
        spanBeats: Int = defaultSpanBeats, thresholdDB: Double = defaultThresholdDB
    ) -> (drops: [Int], exits: [Int], bassLevelsDB: [Double]) {
        let levels = bassLevelsDB(pcm, beatSamples: beatSamples)
        let drops = events(bassLevelsDB: levels, sign: 1, spanBeats: spanBeats, thresholdDB: thresholdDB)
        let exits = events(bassLevelsDB: levels, sign: -1, spanBeats: spanBeats, thresholdDB: thresholdDB)
        return (drops, exits, levels)
    }
}
