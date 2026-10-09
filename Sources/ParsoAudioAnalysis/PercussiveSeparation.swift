//
//  PercussiveSeparation.swift
//  Harmonic/percussive separation (Fitzgerald 2010): a spectrogram median along
//  time keeps sustained partials (harmonic), a median along frequency keeps
//  broadband clicks (percussive); a Wiener-style mask splits the signal. Ported
//  from parso-tonearm/tools/blend-lab/stemswap.py (4096-point Hann STFT, hop
//  1024, 17-frame / 31-bin medians, nearest-edge padding), where the groove read
//  on the percussive part matched the owner-approved placements within 4 ms and
//  placed techno and deep house, whose full-mix groove can't be read.
//

import Foundation
import Accelerate
import ParsoAudioCore

public enum PercussiveSeparation {
    public static let fftSize = 4_096
    public static let hop = 1_024
    public static let timeMedian = 17
    public static let frequencyMedian = 31

    /// The percussive part of the mono mix of `buffer`, same length and rate.
    public static func percussive(_ buffer: PCMBuffer) -> PCMBuffer {
        let n = fftSize, half = n / 2, bins = half + 1
        let mono = BlendAnalyzer.monoSamples(buffer)
        let length = mono.count
        // Centred frames, zero padding of n/2 at both ends (scipy boundary='zeros').
        let padded = [Float](repeating: 0, count: half) + mono + [Float](repeating: 0, count: half + n)
        let frames = max(1, (length + hop - 1) / hop + 1)
        var window = [Float](repeating: 0, count: n)
        for i in 0..<n { window[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))) }   // periodic Hann

        let log2n = vDSP_Length(n.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return PCMBuffer(format: AudioFormat(sampleRate: buffer.format.sampleRate, channelCount: 1), capacity: length)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        // Forward STFT, packed real spectra (vDSP: bin 0 real = DC, bin 0 imag = Nyquist).
        var re = [Float](repeating: 0, count: frames * half), im = [Float](repeating: 0, count: frames * half)
        var mag = [Float](repeating: 0, count: frames * bins)          // [frame][bin]
        var frame = [Float](repeating: 0, count: n)
        for f in 0..<frames {
            let start = f * hop
            for i in 0..<n { frame[i] = padded[start + i] * window[i] }
            re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { m in
                var split = DSPSplitComplex(realp: r.baseAddress! + f * half, imagp: m.baseAddress! + f * half)
                frame.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            } }
            let o = f * half, b = f * bins
            mag[b] = abs(re[o])
            mag[b + half] = abs(im[o])
            for k in 1..<half { mag[b + k] = (re[o + k] * re[o + k] + im[o + k] * im[o + k]).squareRoot() }
        }

        // Medians: along time per bin (harmonic), along frequency per frame (percussive).
        var harmonic = [Float](repeating: 0, count: frames * bins)
        var percussive = [Float](repeating: 0, count: frames * bins)
        var column = [Float](repeating: 0, count: frames), out = [Float](repeating: 0, count: max(frames, bins))
        for k in 0..<bins {
            for f in 0..<frames { column[f] = mag[f * bins + k] }
            slidingMedian(column, width: timeMedian, into: &out)
            for f in 0..<frames { harmonic[f * bins + k] = out[f] }
        }
        var row = [Float](repeating: 0, count: bins)
        for f in 0..<frames {
            for k in 0..<bins { row[k] = mag[f * bins + k] }
            slidingMedian(row, width: frequencyMedian, into: &out)
            for k in 0..<bins { percussive[f * bins + k] = out[k] }
        }

        // Mask, inverse STFT, overlap-add normalised by the summed squared window.
        var y = [Float](repeating: 0, count: padded.count)
        var norm = [Float](repeating: 0, count: padded.count)
        let scale = 1 / Float(2 * n)                                   // vDSP forward+inverse = 2n
        for f in 0..<frames {
            let o = f * half, b = f * bins
            func mask(_ k: Int) -> Float {
                let h = harmonic[b + k], p = percussive[b + k]
                return (p * p) / (h * h + p * p + 1e-12)
            }
            re[o] *= mask(0)
            im[o] *= mask(half)
            for k in 1..<half { let m = mask(k); re[o + k] *= m; im[o + k] *= m }
            re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { m in
                var split = DSPSplitComplex(realp: r.baseAddress! + o, imagp: m.baseAddress! + o)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                frame.withUnsafeMutableBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                    }
                }
            } }
            let start = f * hop
            for i in 0..<n {
                y[start + i] += frame[i] * scale * window[i]
                norm[start + i] += window[i] * window[i]
            }
        }
        let result = PCMBuffer(format: AudioFormat(sampleRate: buffer.format.sampleRate, channelCount: 1), capacity: length)
        let ch = result.channel(0)
        for i in 0..<length {
            let w = norm[i + half]
            ch[i] = w > 1e-8 ? y[i + half] / w : 0
        }
        return result
    }

    /// Median of each `width`-wide window centred on every sample, edges padded
    /// with the nearest value (scipy median_filter mode='nearest'). Keeps the
    /// window sorted: O(width) per step.
    static func slidingMedian(_ x: [Float], width: Int, into out: inout [Float]) {
        let n = x.count, r = width / 2
        guard n > 0 else { return }
        func at(_ i: Int) -> Float { x[min(n - 1, max(0, i))] }
        var sorted = (0..<width).map { at($0 - r) }.sorted()
        for i in 0..<n {
            out[i] = sorted[r]
            guard i + 1 < n else { break }
            let leaving = at(i - r), entering = at(i + 1 + r)
            // Remove one copy of `leaving`, insert `entering`, keeping order.
            var lo = 0, hi = sorted.count - 1
            while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < leaving { lo = mid + 1 } else { hi = mid } }
            sorted.remove(at: lo)
            lo = 0; hi = sorted.count
            while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < entering { lo = mid + 1 } else { hi = mid } }
            sorted.insert(entering, at: lo)
        }
    }
}
