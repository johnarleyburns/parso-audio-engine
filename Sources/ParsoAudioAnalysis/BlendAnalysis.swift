//
//  BlendAnalysis.swift
//  The analysis behind Tonearm's automatic beat-locked blends, ported from
//  parso-tonearm/tools/blend-lab (lock.py, structure.py, groove.py) where the
//  owner validated it by ear (2026-10-08, "dj2").
//
//  - Beat period and phase from the kick band: the period whose folded kick-band
//    rise is sharpest, searched ±1 % around an approximate BPM.
//  - Structure: per-beat kick-band level; drops and bass exits are ±6 dB steps of
//    the 8-beat mean, at the sharpest step.
//  - Groove: coherent beat averaging. Each of four bands is averaged over N beats
//    at the exact period, so what repeats every beat (kick, hats, the groove's
//    transients) adds up and what changes (bass notes, chords, vocals) averages
//    out. Two grooves are lined up by circular cross-correlation of their log
//    envelopes; the reading is trusted only when the bands' own onsets agree.
//    (The lab's earlier fold-angle meter read bass and sidechain pump instead of
//    kicks and flammed by 40-75 ms.)
//

import Foundation
import Accelerate
import ParsoAudioCore

// MARK: - Zero-phase band filtering

/// 2nd-order Butterworth sections run forward then backward: zero phase, so
/// beat times read from the result are not delayed by the filter.
enum ZeroPhase {
    struct Section {
        var b0, b1, b2, a1, a2: Double
        init(sampleRate: Double, hz: Double, high: Bool) {
            let w0 = 2 * Double.pi * hz / sampleRate
            let c = cos(w0), alpha = sin(w0) / (2 * 0.5.squareRoot())
            let a0 = 1 + alpha
            if high { b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = b0 }
            else { b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = b0 }
            a1 = -2 * c / a0; a2 = (1 - alpha) / a0
        }
        func run(_ x: inout [Double], reverse: Bool) {
            var z1 = 0.0, z2 = 0.0
            let n = x.count
            for k in 0..<n {
                let i = reverse ? n - 1 - k : k
                let v = x[i]
                let y = b0 * v + z1
                z1 = b1 * v - a1 * y + z2
                z2 = b2 * v - a2 * y
                x[i] = y
            }
        }
    }

    /// Band-pass `lo`..`hi` Hz, zero phase (4th order each edge after the
    /// forward-backward pass).
    static func bandPass(_ x: [Float], sampleRate: Double, lo: Double, hi: Double) -> [Double] {
        var y = x.map(Double.init)
        let sections = [Section(sampleRate: sampleRate, hz: lo, high: true),
                        Section(sampleRate: sampleRate, hz: hi, high: false)]
        for s in sections { s.run(&y, reverse: false) }
        for s in sections { s.run(&y, reverse: true) }
        return y
    }
}

// MARK: - Beat grid and structure

/// A constant-tempo beat grid: beat k is at `phase + k * period` seconds.
public struct BlendGrid: Codable, Sendable, Equatable {
    public var period: Double
    public var phase: Double
    /// How sharp the folded kick profile is at this period (max / mean).
    public var sharpness: Double

    public init(period: Double, phase: Double, sharpness: Double) {
        self.period = period
        self.phase = phase
        self.sharpness = sharpness
    }

    public var bpm: Double { 60 / period }

    /// Beat times inside [0, duration).
    public func beats(duration: Double) -> [Double] {
        let first = Int((-phase / period).rounded(.up))
        let last = Int(((duration - phase) / period).rounded(.down))
        guard last >= first else { return [] }
        return (first...last).map { phase + Double($0) * period }.filter { $0 >= 0 && $0 < duration }
    }
}

/// Everything the blend planner needs from one track, besides its groove.
public struct BlendTrackAnalysis: Codable, Sendable, Equatable {
    public var sampleRate: Double
    public var duration: Double
    public var grid: BlendGrid
    /// Beat times (seconds), `grid.beats(duration:)`.
    public var beats: [Double]
    /// Kick-band (35-160 Hz) level per beat interval, dB; `beats.count - 1` values.
    public var bassDB: [Double]
    /// Beat indices where the bass comes in (drops) / goes out (breakdowns, outro).
    public var drops: [Int]
    public var exits: [Int]
    /// The 8-beat step size at each drop / exit, dB.
    public var dropStepDB: [Double]
    public var exitStepDB: [Double]
    public var leadingSilence: Double
    public var rmsDB: Double
}

public enum BlendAnalyzer {
    public static let kickBand = (lo: 35.0, hi: 160.0)
    static let structureSpan = 8
    static let dropDB = 6.0

    /// Analyses a decoded track. `approximateBPM` comes from the regular beat
    /// tracker; the period is refined within ±1 % of it.
    public static func analyze(_ buffer: PCMBuffer, approximateBPM: Double) -> BlendTrackAnalysis {
        let sr = buffer.format.sampleRate
        let mono = monoSamples(buffer)
        let low = ZeroPhase.bandPass(mono, sampleRate: sr, lo: kickBand.lo, hi: kickBand.hi)
        let duration = Double(buffer.frameCount) / sr
        let grid = period(lowBand: low, sampleRate: sr, approximateBPM: approximateBPM)
        let beats = grid.beats(duration: duration)
        let db = bassDB(lowBand: low, beats: beats, sampleRate: sr)
        let (drops, dropSteps) = events(db, sign: 1)
        let (exits, exitSteps) = events(db, sign: -1)
        return BlendTrackAnalysis(sampleRate: sr, duration: duration, grid: grid, beats: beats, bassDB: db,
                                  drops: drops, exits: exits,
                                  dropStepDB: drops.map { dropSteps[$0] }, exitStepDB: exits.map { exitSteps[$0] },
                                  leadingSilence: leadingSilence(buffer), rmsDB: rmsDB(buffer))
    }

    /// Structure, silence and level of `buffer` on a grid already known (the
    /// incoming track after its tempo change: its own period / tempo).
    public static func analyze(_ buffer: PCMBuffer, grid: BlendGrid) -> BlendTrackAnalysis {
        let sr = buffer.format.sampleRate
        let low = ZeroPhase.bandPass(monoSamples(buffer), sampleRate: sr, lo: kickBand.lo, hi: kickBand.hi)
        let duration = Double(buffer.frameCount) / sr
        let beats = grid.beats(duration: duration)
        let db = bassDB(lowBand: low, beats: beats, sampleRate: sr)
        let (drops, dropSteps) = events(db, sign: 1)
        let (exits, exitSteps) = events(db, sign: -1)
        return BlendTrackAnalysis(sampleRate: sr, duration: duration, grid: grid, beats: beats, bassDB: db,
                                  drops: drops, exits: exits,
                                  dropStepDB: drops.map { dropSteps[$0] }, exitStepDB: exits.map { exitSteps[$0] },
                                  leadingSilence: leadingSilence(buffer), rmsDB: rmsDB(buffer))
    }

    static func monoSamples(_ buffer: PCMBuffer) -> [Float] {
        var out = [Float](repeating: 0, count: buffer.frameCount)
        let scale = 1 / Float(buffer.channelCount)
        for c in 0..<buffer.channelCount {
            let ch = buffer.channel(c)
            for i in 0..<buffer.frameCount { out[i] += ch[i] * scale }
        }
        return out
    }

    /// Envelope hop: ~0.5 ms, an exact number of samples (44.1 kHz -> 22).
    static func hop(_ sampleRate: Double) -> Int { max(1, Int((sampleRate / 2_004.5).rounded())) }

    /// Kick-band RMS envelope per hop, 9-hop moving average (~4.5 ms).
    static func lowEnvelope(_ low: [Double], sampleRate: Double) -> [Double] {
        let h = hop(sampleRate), n = low.count / h
        var e = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = 0.0
            for k in 0..<h { let v = low[i * h + k]; s += v * v }
            e[i] = (s / Double(h)).squareRoot()
        }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = 0.0
            for k in -4...4 { let j = i + k; if j >= 0, j < n { s += e[j] } }
            out[i] = s / 9
        }
        return out
    }

    /// The beat period with the sharpest folded kick-band rise, ±1 % around the
    /// approximate BPM (coarse then fine), and the phase of the fold peak.
    static func period(lowBand: [Double], sampleRate: Double, approximateBPM: Double) -> BlendGrid {
        let env = lowEnvelope(lowBand, sampleRate: sampleRate)
        let rate = sampleRate / Double(hop(sampleRate))
        var flux = [Double](repeating: 0, count: env.count)
        for i in 1..<max(1, env.count) { flux[i] = max(0, env[i] - env[i - 1]) }
        let nominal = 60 / max(1, approximateBPM)

        func score(_ p: Double) -> Double {
            var h = [Double](repeating: 0, count: 96), c = [Double](repeating: 0, count: 96)
            let step = 1 / (rate * p)
            var ph = 0.0
            for i in flux.indices {
                let bin = min(95, Int(ph * 96))
                h[bin] += flux[i]; c[bin] += 1
                ph += step
                if ph >= 1 { ph -= ph.rounded(.down) }
            }
            var mx = 0.0, sum = 0.0
            for b in 0..<96 { let v = h[b] / max(c[b], 1); mx = max(mx, v); sum += v }
            return mx / (sum / 96 + 1e-12)
        }
        func search(_ lo: Double, _ hi: Double, _ steps: Int) -> (Double, Double) {
            var best = (score: -1.0, p: nominal)
            for k in 0..<steps {
                let p = lo + (hi - lo) * Double(k) / Double(steps - 1)
                let s = score(p)
                if s > best.score { best = (s, p) }
            }
            return (best.p, best.score)
        }
        // The lab's full scan: 801 periods across ±1 % (the sharpness surface has
        // narrow peaks a coarse-to-fine search can step over).
        let (p, sharp) = search(nominal * 0.99, nominal * 1.01, 801)

        var h = [Double](repeating: 0, count: 192)
        let step = 1 / (rate * p)
        var ph = 0.0
        for i in flux.indices {
            h[min(191, Int(ph * 192))] += flux[i]
            ph += step
            if ph >= 1 { ph -= ph.rounded(.down) }
        }
        let peak = h.indices.max { h[$0] < h[$1] } ?? 0
        return BlendGrid(period: p, phase: (Double(peak) + 0.5) / 192 * p, sharpness: sharp)
    }

    static func bassDB(lowBand: [Double], beats: [Double], sampleRate: Double) -> [Double] {
        guard beats.count > 1 else { return [] }
        return (0..<(beats.count - 1)).map { k in
            let a = Int(beats[k] * sampleRate), b = min(lowBand.count, Int(beats[k + 1] * sampleRate))
            guard b > a else { return -120 }
            var s = 0.0
            for i in a..<b { s += lowBand[i] * lowBand[i] }
            return 10 * log10(s / Double(b - a) + 1e-12)
        }
    }

    /// Beat indices of drops (sign +1) or bass exits (sign -1): local maxima of
    /// the 8-beat step of at least 6 dB. Also returns the step per beat.
    static func events(_ db: [Double], sign: Double) -> ([Int], [Double]) {
        let n = db.count, span = structureSpan
        var step = [Double](repeating: 0, count: n)
        guard n > 2 * span else { return ([], step) }
        for i in span..<(n - span) {
            let after = db[i..<(i + span)].reduce(0, +) / Double(span)
            let before = db[(i - span)..<i].reduce(0, +) / Double(span)
            step[i] = sign * (after - before)
        }
        var out: [Int] = []
        for i in span..<(n - span) where step[i] >= dropDB {
            let localMax = step[max(0, i - span)..<min(n, i + span)].max() ?? 0
            if step[i] == localMax { out.append(i) }
        }
        return (out, step)
    }

    /// First 50 ms frame (mean |channel|) at or above -50 dBFS RMS, seconds.
    static func leadingSilence(_ buffer: PCMBuffer) -> Double {
        let sr = buffer.format.sampleRate, frame = Int(sr / 20)
        let level = pow(10, -50.0 / 20)
        let chans = (0..<buffer.channelCount).map { buffer.channel($0) }
        var i = 0
        while i + frame < buffer.frameCount {
            var s = 0.0
            for k in i..<(i + frame) {
                var m: Float = 0
                for ch in chans { m += abs(ch[k]) }
                let v = Double(m) / Double(chans.count)
                s += v * v
            }
            if (s / Double(frame)).squareRoot() >= level { return Double(i) / sr }
            i += frame
        }
        return 0
    }

    static func rmsDB(_ buffer: PCMBuffer) -> Double {
        var s = 0.0
        for c in 0..<buffer.channelCount {
            let ch = buffer.channel(c)
            for i in 0..<buffer.frameCount { s += Double(ch[i] * ch[i]) }
        }
        return 20 * log10((s / Double(max(1, buffer.frameCount * buffer.channelCount))).squareRoot() + 1e-12)
    }
}

// MARK: - Groove

/// The beat-averaged envelopes of four bands over one beat, `bins` per beat.
public struct GrooveProfile: Sendable, Equatable {
    public static let bands: [(lo: Double, hi: Double)] = [(35, 200), (200, 1_000), (1_000, 4_000), (4_000, 12_000)]
    public static let bins = 2_048
    /// One envelope per band, `bins` values each (linear amplitude).
    public var envelopes: [[Float]]
}

public struct GrooveOffset: Sendable, Equatable {
    /// How late the second groove sits against the first, as a fraction of a
    /// beat in (-0.5, 0.5].
    public var lagBeats: Double
    /// Each band's own onset lag, fraction of a beat.
    public var bandOnsetBeats: [Double]
    /// Bands whose onset lag is within `Groove.agreeSeconds` of `lagBeats`.
    public var agreeing: Int
    /// The best cross-correlation peak more than 1/8 beat from the chosen one,
    /// relative to it (0 = unambiguous, 1 = a tie, e.g. kick vs off-beat hats).
    public var rivalPeak: Double
}

public enum Groove {
    public static let agreeSeconds = 0.012
    public static let minimumAgreeing = 3

    /// The groove of `buffer` over `beats` beats of `period` seconds starting at
    /// `start` seconds (all in the buffer's own time). Nil when the window
    /// leaves the track.
    public static func profile(_ buffer: PCMBuffer, start: Double, beats: Int, period: Double) -> GrooveProfile? {
        let sr = buffer.format.sampleRate
        let pad = Int(sr)                                  // 1 s each side against FFT edge ringing
        let first = Int((start * sr).rounded(.down)) - pad
        let length = Int((Double(beats) * period * sr).rounded(.up)) + 2 * pad + 2
        guard beats > 0, period > 0, start >= 0,
              (start + Double(beats) * period) * sr <= Double(buffer.frameCount) else { return nil }

        var n = 1
        while n < length { n <<= 1 }
        let log2n = vDSP_Length(n.trailingZeroBitCount)
        // vDSP.FFT<DSPSplitComplex> only does packed real transforms; the analytic
        // band signal needs a true complex FFT, so use vDSP_fft_zop directly.
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        // Segment (mono), zero outside the track and beyond `length`.
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        let scale = 1 / Float(buffer.channelCount)
        for c in 0..<buffer.channelCount {
            let ch = buffer.channel(c)
            for i in 0..<length {
                let j = first + i
                if j >= 0, j < buffer.frameCount { re[i] += ch[j] * scale }
            }
        }
        var specRe = [Float](repeating: 0, count: n), specIm = [Float](repeating: 0, count: n)
        re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { i in
            specRe.withUnsafeMutableBufferPointer { sr2 in specIm.withUnsafeMutableBufferPointer { si in
                var input = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                var output = DSPSplitComplex(realp: sr2.baseAddress!, imagp: si.baseAddress!)
                vDSP_fft_zop(setup, &input, 1, &output, 1, log2n, FFTDirection(kFFTDirection_Forward))
            } }
        } }

        let binHz = sr / Double(n)
        let L = Int((period * sr).rounded(.down))
        var envelopes: [[Float]] = []
        var bandRe = [Float](repeating: 0, count: n), bandIm = [Float](repeating: 0, count: n)
        var outRe = [Float](repeating: 0, count: n), outIm = [Float](repeating: 0, count: n)
        for band in GrooveProfile.bands {
            // Analytic band signal: positive frequencies in the band only.
            for k in 0..<n {
                let f = Double(k) * binHz
                let keep = k > 0 && k < n / 2 && f >= band.lo && f <= band.hi
                bandRe[k] = keep ? specRe[k] : 0
                bandIm[k] = keep ? specIm[k] : 0
            }
            bandRe.withUnsafeMutableBufferPointer { br in bandIm.withUnsafeMutableBufferPointer { bi in
                outRe.withUnsafeMutableBufferPointer { orr in outIm.withUnsafeMutableBufferPointer { oi in
                    var input = DSPSplitComplex(realp: br.baseAddress!, imagp: bi.baseAddress!)
                    var output = DSPSplitComplex(realp: orr.baseAddress!, imagp: oi.baseAddress!)
                    vDSP_fft_zop(setup, &input, 1, &output, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                } }
            } }
            // Coherent average of the complex band signal over the beats.
            var accRe = [Double](repeating: 0, count: L), accIm = [Double](repeating: 0, count: L)
            for b in 0..<beats {
                let s = (start + Double(b) * period) * sr - Double(first)
                let i0 = Int(s.rounded(.down)), fr = s - Double(i0)
                guard i0 >= 0, i0 + L + 1 < n else { return nil }
                for k in 0..<L {
                    accRe[k] += Double(outRe[i0 + k]) * (1 - fr) + Double(outRe[i0 + k + 1]) * fr
                    accIm[k] += Double(outIm[i0 + k]) * (1 - fr) + Double(outIm[i0 + k + 1]) * fr
                }
            }
            // Magnitude, then bin means down to `bins` per beat.
            var env = [Float](repeating: 0, count: GrooveProfile.bins)
            for j in 0..<GrooveProfile.bins {
                let a = j * L / GrooveProfile.bins, z = max(a + 1, (j + 1) * L / GrooveProfile.bins)
                var s = 0.0
                for k in a..<z { s += (accRe[k] * accRe[k] + accIm[k] * accIm[k]).squareRoot() }
                env[j] = Float(s / Double(z - a))
            }
            envelopes.append(env)
        }
        return GrooveProfile(envelopes: envelopes)
    }

    /// How late `incoming`'s groove sits against `outgoing`'s (both one beat of
    /// the same output period), and whether the bands agree.
    public static func offset(outgoing: GrooveProfile, incoming: GrooveProfile, period: Double) -> GrooveOffset {
        let n = GrooveProfile.bins
        var xc = [Double](repeating: 0, count: n)
        var onsets: [Double] = []
        for (a, b) in zip(outgoing.envelopes, incoming.envelopes) {
            let la = logEnvelope(a), lb = logEnvelope(b)
            for lag in 0..<n {
                var s = 0.0
                for i in 0..<n { s += la[i] * lb[(i + lag) % n] }
                xc[lag] += s
            }
            onsets.append(wrap(onsetBin(b) - onsetBin(a), n) / Double(n))
        }
        let k = xc.indices.max { xc[$0] < xc[$1] } ?? 0
        let y0 = xc[(k - 1 + n) % n], y1 = xc[k], y2 = xc[(k + 1) % n]
        let den = y0 - 2 * y1 + y2
        let refined = Double(k) + (den != 0 ? 0.5 * (y0 - y2) / den : 0)
        let lag = wrap(refined, n) / Double(n)
        let tolerance = agreeSeconds / period
        let agree = onsets.filter { abs(wrapUnit($0 - lag)) <= tolerance }.count
        let floor = xc.min() ?? 0
        var rival = floor
        for j in 0..<n where abs(wrap(Double(j - k), n)) > Double(n) / 8 { rival = max(rival, xc[j]) }
        let rivalPeak = y1 > floor ? (rival - floor) / (y1 - floor) : 1
        return GrooveOffset(lagBeats: lag, bandOnsetBeats: onsets, agreeing: agree, rivalPeak: rivalPeak)
    }

    static func logEnvelope(_ e: [Float]) -> [Double] {
        let mx = Double(e.max() ?? 0)
        guard mx > 0 else { return [Double](repeating: 0, count: e.count) }
        let l = e.map { log1p(Double($0) / mx * 100) }
        let mean = l.reduce(0, +) / Double(l.count)
        return l.map { $0 - mean }
    }

    /// First 50 % crossing walking back from the peak (circular), in bins.
    static func onsetBin(_ e: [Float]) -> Double {
        let n = e.count
        let peak = e.indices.max { e[$0] < e[$1] } ?? 0
        let threshold = 0.5 * e[peak]
        var i = peak
        while e[(i - 1 + n) % n] >= threshold && peak - i < n { i -= 1 }
        return Double((i % n + n) % n)
    }

    static func wrap(_ x: Double, _ n: Int) -> Double {
        let m = Double(n)
        var v = x.truncatingRemainder(dividingBy: m)
        if v < 0 { v += m }
        return v > m / 2 ? v - m : v
    }

    static func wrapUnit(_ x: Double) -> Double {
        var v = x - x.rounded(.down)
        if v > 0.5 { v -= 1 }
        return v
    }
}
