//
//  WaveformPyramid.swift
//  Ported from parso-tonearm/Sources/DJ/Analysis/Waveform.swift (audio-engine
//  unification, docs/UNIFICATION_PLAN.md §4 Phase 5). File renamed to avoid a
//  clash with the estimator facade's `Waveform` struct.
//
//  The band splitter's `Biquad` / `LinkwitzRiley` live in parso-tonearm's
//  mixer (`Sources/DJ/Engine/Mixer.swift`), not its analysis dir. They are
//  small and self-contained, so a private copy is carried here rather than
//  reaching up to `ParsoAudioPlayback`'s EQ (`ParsoAudioAnalysis` depends only
//  on `ParsoAudioCore`). The 200 Hz / 2 kHz crossovers match the mixer's
//  three-band EQ (§35.2) exactly.
//

import Foundation
import Accelerate

// MARK: - Band-split biquads (private copy of the mixer's LR4 crossover)

/// Direct-form-1 RBJ biquad. Private to the waveform band splitter.
private struct WFBiquad {
    var b0: Float, b1: Float, b2: Float
    var a1: Float, a2: Float
    private var x1: Float = 0, x2: Float = 0
    private var y1: Float = 0, y2: Float = 0

    init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// Linkwitz–Riley 2-stage crossover (LR4, 24 dB/oct); the low+high bands sum to
/// an exact all-pass. Matches `parso-tonearm`'s mixer crossover (§35.2).
private struct WFLinkwitzRiley {
    private var lpStage1: WFBiquad
    private var lpStage2: WFBiquad
    private var hpStage1: WFBiquad
    private var hpStage2: WFBiquad

    init(splitHz: Float, sampleRate: Double) {
        let w0 = 2 * Float.pi * splitHz / Float(sampleRate)
        let alpha = sin(w0) / sqrt(2) // Q = 1/√2 → Butterworth
        let cosw = cos(w0)
        let a0 = 1 + alpha
        let a1 = (-2 * cosw) / a0
        let a2 = (1 - alpha) / a0
        let lpB0 = (1 - cosw) / (2 * a0)
        let lpB1 = (1 - cosw) / a0
        let hpB0 = (1 + cosw) / (2 * a0)
        let hpB1 = -(1 + cosw) / a0
        lpStage1 = WFBiquad(b0: lpB0, b1: lpB1, b2: lpB0, a1: a1, a2: a2)
        lpStage2 = WFBiquad(b0: lpB0, b1: lpB1, b2: lpB0, a1: a1, a2: a2)
        hpStage1 = WFBiquad(b0: hpB0, b1: hpB1, b2: hpB0, a1: a1, a2: a2)
        hpStage2 = WFBiquad(b0: hpB0, b1: hpB1, b2: hpB0, a1: a1, a2: a2)
    }

    @inline(__always)
    mutating func split(_ x: Float) -> (lo: Float, hi: Float) {
        let l1 = lpStage1.process(x)
        let h1 = hpStage1.process(x)
        return (lpStage2.process(l1), hpStage2.process(h1))
    }
}

// MARK: - Config & bins

/// Waveform pyramid configuration (§26.1).
public struct WaveformConfig: Sendable, Equatable {
    /// Samples per bin at the finest level.
    public var baseSamplesPerBin: Int = 256
    /// Number of pyramid levels; each level is a ×2 reduction of the previous.
    public var levels: Int = 8
    /// Band-split RMS for colored waveforms (low/mid/high).
    public var bandSplit: Bool = true

    public init(baseSamplesPerBin: Int = 256, levels: Int = 8, bandSplit: Bool = true) {
        self.baseSamplesPerBin = baseSamplesPerBin
        self.levels = levels
        self.bandSplit = bandSplit
    }
}

/// One waveform bin: min/max envelope plus RMS (optionally per band).
public struct WaveformBin: Equatable, Sendable {
    public var min: Float
    public var max: Float
    public var rms: Float
    /// RMS per band (low/mid/high) when `bandSplit` is enabled.
    public var bandRMS: [Float]

    public init(min: Float, max: Float, rms: Float, bandRMS: [Float] = []) {
        self.min = min
        self.max = max
        self.rms = rms
        self.bandRMS = bandRMS
    }
}

/// A multi-resolution waveform pyramid (§26.1): level 0 is the finest
/// (baseSamplesPerBin per bin), each level halves the bin count.
public struct WaveformPyramid: Equatable, Sendable {
    public var levels: [[WaveformBin]]
    public var sampleRate: Double
    public var baseSamplesPerBin: Int

    public init(levels: [[WaveformBin]], sampleRate: Double, baseSamplesPerBin: Int) {
        self.levels = levels
        self.sampleRate = sampleRate
        self.baseSamplesPerBin = baseSamplesPerBin
    }

    /// Samples covered by one bin at `level` (level 0 = `baseSamplesPerBin`,
    /// each level doubles). The renderer's zoom→level mapping (§26A.7).
    public func samplesPerBin(at level: Int) -> Double {
        Double(Swift.max(1, baseSamplesPerBin)) * pow(2.0, Double(Swift.max(0, level)))
    }
}

/// The §26A.2 band splitter: the same 200 Hz / 2 kHz crossovers as the mixer's
/// three-band EQ (§35.2), run statefully over a signal so the pyramid's per-bin
/// low/mid/high RMS is a genuine filtered measurement.
public struct WaveformBandSplit: Sendable {
    public static let lowMidHz: Float = 200
    public static let midHighHz: Float = 2_000

    private var lowMid: WFLinkwitzRiley
    private var midHigh: WFLinkwitzRiley

    public init(sampleRate: Double) {
        lowMid = WFLinkwitzRiley(splitHz: Self.lowMidHz, sampleRate: sampleRate)
        midHigh = WFLinkwitzRiley(splitHz: Self.midHighHz, sampleRate: sampleRate)
    }

    /// Split one sample into the three complementary bands (low + mid + high
    /// reconstruct the input).
    @inline(__always)
    public mutating func split(_ x: Float) -> (lo: Float, mid: Float, hi: Float) {
        let (lo, hiA) = lowMid.split(x)
        let (mid, hi) = midHigh.split(hiA)
        return (lo, mid, hi)
    }
}

/// Builds and packs the waveform pyramid (§26, App. C).
public enum WaveformPyramidBuilder {

    /// Build the pyramid from the mono downmix. Level 0 computes min/max/RMS per
    /// bin via vDSP reductions; each coarser level reduces the previous
    /// pairwise (min of mins, max of maxes, RMS energy-combined) so no audio is
    /// rescanned at render time (NFR-PERF-3).
    public static func build(_ mono: UnsafeBufferPointer<Float>,
                             sampleRate: Double,
                             config: WaveformConfig = WaveformConfig()) -> WaveformPyramid {
        let base = max(1, config.baseSamplesPerBin)
        guard mono.count > 0 else {
            return WaveformPyramid(levels: [], sampleRate: sampleRate, baseSamplesPerBin: base)
        }

        // §26A.2: the band split shares the mixer's 200 Hz / 2 kHz LR4
        // crossovers (§35.2), run **statefully over the whole signal** so a
        // bin's low/mid/high RMS is a genuine filtered measurement.
        var bandBuffers: (low: [Float], mid: [Float], high: [Float])?
        if config.bandSplit {
            var splitter = WaveformBandSplit(sampleRate: sampleRate)
            var low = [Float](repeating: 0, count: mono.count)
            var mid = [Float](repeating: 0, count: mono.count)
            var high = [Float](repeating: 0, count: mono.count)
            for i in 0..<mono.count {
                let (lo, mi, hi) = splitter.split(mono[i])
                low[i] = lo
                mid[i] = mi
                high[i] = hi
            }
            bandBuffers = (low, mid, high)
        }

        var level0: [WaveformBin] = []
        let binCount = max(1, Int(ceil(Double(mono.count) / Double(base))))
        level0.reserveCapacity(binCount)
        for b in 0..<binCount {
            let start = b * base
            let end = min(mono.count, start + base)
            guard end > start else { break }
            let slice = mono.baseAddress!.advanced(by: start)
            var mn: Float = 0
            var mx: Float = 0
            var rms: Float = 0
            vDSP_minv(slice, 1, &mn, vDSP_Length(end - start))
            vDSP_maxv(slice, 1, &mx, vDSP_Length(end - start))
            vDSP_rmsqv(slice, 1, &rms, vDSP_Length(end - start))
            var bandRMS: [Float] = []
            if let bands = bandBuffers {
                bandRMS = [rmsOfBand(bands.low, start, end),
                           rmsOfBand(bands.mid, start, end),
                           rmsOfBand(bands.high, start, end)]
            }
            level0.append(WaveformBin(min: mn, max: mx, rms: rms, bandRMS: bandRMS))
        }

        var pyramid = [level0]
        for _ in 1..<max(1, config.levels) {
            let previous = pyramid[pyramid.count - 1]
            guard previous.count > 1 else { break }
            var next: [WaveformBin] = []
            next.reserveCapacity((previous.count + 1) / 2)
            var i = 0
            while i < previous.count {
                let a = previous[i]
                if i + 1 < previous.count {
                    let b = previous[i + 1]
                    next.append(WaveformBin(min: min(a.min, b.min),
                                           max: max(a.max, b.max),
                                           rms: sqrt((a.rms * a.rms + b.rms * b.rms) / 2),
                                           bandRMS: combineBands(a.bandRMS, b.bandRMS)))
                } else {
                    next.append(a)
                }
                i += 2
            }
            pyramid.append(next)
            if next.count == 1 { break }
        }

        return WaveformPyramid(levels: pyramid, sampleRate: sampleRate,
                               baseSamplesPerBin: base)
    }

    /// RMS over a band-filtered buffer slice — the per-bin band measurement
    /// (§26A.2). The band buffers are precomputed statefully over the whole
    /// signal, so a bin's values are genuine filtered energy, not an estimate.
    static func rmsOfBand(_ buffer: [Float], _ start: Int, _ end: Int) -> Float {
        let count = end - start
        guard count > 0 else { return 0 }
        return buffer.withUnsafeBufferPointer { bp in
            var rms: Float = 0
            vDSP_rmsqv(bp.baseAddress!.advanced(by: start), 1, &rms, vDSP_Length(count))
            return rms
        }
    }

    static func combineBands(_ a: [Float], _ b: [Float]) -> [Float] {
        guard a.count == b.count else { return a }
        return zip(a, b).map { sqrt(($0 * $0 + $1 * $1) / 2) }
    }

    /// Pick the pyramid level whose bin size best matches a target zoom width.
    public static func level(binSamples: Int, pyramid: WaveformPyramid) -> Int {
        guard !pyramid.levels.isEmpty else { return 0 }
        var chosen = 0
        var binSize = pyramid.baseSamplesPerBin
        for (i, level) in pyramid.levels.enumerated() {
            if binSize >= binSamples { chosen = i; break }
            chosen = i
            binSize *= 2
            if level.isEmpty { break }
        }
        return chosen
    }
}
