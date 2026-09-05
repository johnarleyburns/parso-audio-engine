//
//  DemucsSpectrogram.swift
//  Ported verbatim from parso-tonearm/Sources/DJ/Stems/StemSpectrogram.swift for
//  the acceptance tool only (tool-local, not shipped in any library target):
//  it lets this human-listening harness run real Demucs separation against the
//  `DemucsStems.mlpackage` weights already converted for tonearm, without
//  making the acceptance tool depend on the app repo. See ATTRIBUTION.md.
//
import Accelerate
import Foundation

/// Demucs' analysis/synthesis transform pair, reproduced in Swift (plan
/// `dj-stems-model.md` §5). The Core ML model takes `(mag, audio)` and returns
/// `(spec, waveform)`; both transforms live here, on the Swift side, because
/// Core ML has complex as a type but almost no MIL op accepts it and it has no
/// `istft` at all (S1).
///
/// The contract is pinned to `demucs 4.1.0` (see the table in plan §5.1) and is
/// verified against saved torch tensors — the golden tests in
/// `StemSpectrogramTests` compare `forward` against the torch `mag` and
/// `inverse` against the torch `ispec`, `max|d| ≤ 1e-4`. **Never assert
/// STFT/ISTFT round-trip identity**: Demucs' pair is not invertible (the
/// forward drops the Nyquist bin and trims two frames each end; measured
/// round-trip error on unit-variance noise is 1.54). The golden vectors are the
/// only valid reference.
///
/// Pure and `Sendable`: no Core ML import, no engine dependency, testable in
/// `swift test` with no model present. The existing `STFTKernel`
/// (`Sources/DJ/Analysis/STFT.swift`) cannot be reused — it computes a power
/// spectrum, discards phase, has no inverse, uses `vDSP_HANN_NORM`, and hops at
/// 2048 on 48 kHz. It is untouched; this is a new kernel.
public struct DemucsSpectrogram: Sendable {

    /// The model's sample rate (plan §5.1). The separator resamples the track
    /// to this rate once, chunks, and resamples the voices back (S4).
    public static let sampleRate: Double = 44_100
    /// The model's fixed segment length in frames (`39/5 s` at 44 100 Hz).
    public static let segmentFrames = 343_980
    /// FFT size.
    public static let nfft = 4096
    /// Hop length (`= nfft // 4`; the model asserts this).
    public static let hop = 1024
    /// Positive-frequency bins kept — the Nyquist bin is dropped by `_spec`.
    public static let bins = 2048
    /// Frames per full segment (`ceil(segmentFrames / hop)`).
    public static let frames = 336

    // MARK: - Constants derived from the demucs geometry

    /// The periodic Hann of `nfft` — `torch.hann_window(4096)`. This is not
    /// `vDSP_HANN_NORM` (energy-normalised); the plan is explicit that the
    /// window must match torch's exactly.
    static let window: [Float] = {
        (0..<nfft).map { i in
            Float(0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(nfft))))
        }
    }()

    /// The extra time-domain padding `_spec` applies before the STFT:
    /// `pad1d(x, (1536, 1536 + le*hop - N))`. Left pad is always `hop*3/2`.
    private static let stftLeftPad = hop * 3 / 2

    // MARK: - Forward: `_spec` then `_magnitude`

    /// The real spectrogram of a stereo frame, in the model's `mag` layout:
    /// four planes `[L.re, L.im, R.re, R.im]`, each `bins * frames` floats,
    /// row-major `(freq, frame)` (`index = channel*2 + reim`, plan §5.2). The
    /// input is `left`/`right` of equal length at `sampleRate`.
    ///
    /// Reproduces `HTDemucs._spec` + `_magnitude` (cac): reflect-pad by
    /// `(1536, 1536 + le*hop − N)`, then for each of the `le = ceil(N/hop)`
    /// kept frames an FFT of the `nfft` windowed samples at `hop` stride,
    /// normalized by `1/sqrt(nfft)` (torch `normalized=True`), Nyquist bin
    /// dropped.
    public static func forward(left: [Float], right: [Float]) -> [Float] {
        let n = left.count
        guard n > 0, right.count == n else { return [] }
        let le = (n + hop - 1) / hop
        let rightPad = stftLeftPad + le * hop - n

        let leftPadded = reflectPad(left, left: stftLeftPad, right: rightPad)
        let rightPadded = reflectPad(right, left: stftLeftPad, right: rightPad)

        var result = [Float](repeating: 0, count: 4 * bins * le)
        result.withUnsafeMutableBufferPointer { out in
            // Plane base addresses inside the output.
            let planes = [0, 1, 2, 3].map { p -> UnsafeMutablePointer<Float> in
                out.baseAddress!.advanced(by: p * bins * le)
            }
            var re = [Float](repeating: 0, count: nfft / 2)
            var im = [Float](repeating: 0, count: nfft / 2)
            let fft = makeFFT()
            for (channel, signal) in [leftPadded, rightPadded].enumerated() {
                signal.withUnsafeBufferPointer { base in
                    frameFFTs(signal: base, le: le, fft: fft,
                              re: &re, im: &im) { frame, re, im in
                        // `mag` plane layout: channel-major, re/im minor.
                        writeFrame(planes[channel * 2], le: le, frame: frame, re: re, im: im)
                        writeFrame(planes[channel * 2 + 1], le: le, frame: frame, re: re, im: im,
                                   imaginary: true)
                    }
                }
            }
        }
        return result
    }

    // MARK: - Inverse: `_mask` then `_ispec`

    /// The inverse of `forward`'s layout for one source: `spec` is four planes
    /// `[L.re, L.im, R.re, R.im]`, each `bins * frames`, row-major. Returns
    /// `segmentFrames` per channel, reproducing `_mask`+`_ispec`: unpack the
    /// cac layout to complex, restore the Nyquist bin as zero, pad two zero
    /// frames each end, then `istft(normalized=True, center=True, length=…)`
    /// and trim `[1536 : 1536 + segmentFrames]` (plan §5.3).
    public static func inverse(spec: UnsafeBufferPointer<Float>) -> (left: [Float], right: [Float]) {
        let total = spec.count
        let frameCount = total / (4 * bins)
        guard frameCount > 0, frameCount * 4 * bins == total else {
            return ([Float](repeating: 0, count: segmentFrames),
                    [Float](repeating: 0, count: segmentFrames))
        }

        // The istft's full output length (torch `expected_output_signal_len`):
        // the padded frame count (`+4` = the two zero frames each end of `_ispec`).
        let paddedFrames = frameCount + 4
        let expected = nfft + hop * (paddedFrames - 1)
        let envelope = windowEnvelope(frames: paddedFrames, length: expected)

        var left = [Float](repeating: 0, count: segmentFrames)
        var right = [Float](repeating: 0, count: segmentFrames)

        let fft = makeFFT()
        var re = [Float](repeating: 0, count: nfft / 2)
        var im = [Float](repeating: 0, count: nfft / 2)
        var scratch = [Float](repeating: 0, count: nfft)

        // Two channels, each accumulated independently (L and R never mix).
        for channel in 0..<2 {
            let rePlane = spec.baseAddress!.advanced(by: (channel * 2) * bins * frameCount)
            let imPlane = spec.baseAddress!.advanced(by: (channel * 2 + 1) * bins * frameCount)
            var ola = [Float](repeating: 0, count: expected)
            ola.withUnsafeMutableBufferPointer { olaPtr in
                for frame in 0..<paddedFrames {
                    // The two zero frames each end of `_ispec`.
                    let t = frame - 2
                    guard t >= 0, t < frameCount else { continue }
                    spectrumFrame(rePlane: rePlane, imPlane: imPlane,
                                  frame: t, frameCount: frameCount, re: &re, im: &im)
                    inverseFrame(fft: fft, re: &re, im: &im,
                                 scratch: &scratch) { samples in
                        var windowed = [Float](repeating: 0, count: nfft)
                        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(nfft))
                        // torch `_fft_c2r` by_root_n = (1/√nfft)·Σ X e^{…}.
                        // vDSP's inverse returns the raw sum (N·IDFT), so the
                        // scale is exactly 1/√nfft = 1/64.
                        var scale = Float(1 / sqrt(Double(nfft)))
                        vDSP_vsmul(windowed, 1, &scale,
                                   &windowed, 1, vDSP_Length(nfft))
                        vDSP_vadd(olaPtr.baseAddress!.advanced(by: frame * hop), 1,
                                  windowed, 1,
                                  olaPtr.baseAddress!.advanced(by: frame * hop), 1,
                                  vDSP_Length(nfft))
                    }
                }
                // Divide by the envelope (clamped — outside the frames' coverage
                // both it and the signal are 0, and torch zero-pads that tail).
                vDSP_vdiv(envelope, 1, olaPtr.baseAddress!, 1,
                          olaPtr.baseAddress!, 1, vDSP_Length(expected))
            }
            // The model trims the istft's [nfft/2 : ...] slice at [pad : pad+length]
            // (plan §5.3), so output[i] = ola[nfft/2 + pad + i], zero past the
            // frames' coverage.
            if channel == 0 {
                copyTrimmed(ola: ola, expected: expected, into: &left)
            } else {
                copyTrimmed(ola: ola, expected: expected, into: &right)
            }
        }
        return (left, right)
    }

    /// The `_ispec` trim: `x[pad : pad + length]` applied to the istft's
    /// `[nfft/2 : ...]` slice, zero past the frames' coverage (torch pads the
    /// tail when `length` exceeds the istft output).
    private static func copyTrimmed(ola: [Float], expected: Int,
                                    into dest: inout [Float]) {
        let count = dest.count
        dest.withUnsafeMutableBufferPointer { dp in
            ola.withUnsafeBufferPointer { src in
                let start = nfft / 2 + stftLeftPad
                let srcBase = src.baseAddress!
                for i in 0..<count {
                    let idx = start + i
                    dp[i] = idx < expected ? srcBase[idx] : 0
                }
            }
        }
    }

    // MARK: - Primitives

    /// The vDSP real-FFT engine, created once per call (setup is the only
    /// allocation the plan permits here; the golden tests run off-device).
    private static func makeFFT() -> vDSP.FFT<DSPSplitComplex> {
        vDSP.FFT(log2n: vDSP_Length(log2(Float(nfft))), radix: .radix2,
                 ofType: DSPSplitComplex.self)!
    }

    /// Reflect-pad `x` by `(left, right)` exactly as torch's `F.pad(mode="reflect")`
    /// does (no edge repeat): `out[i] = x[left - i]` on the left and
    /// `out[N+j] = x[N - 2 - j]` on the right.
    private static func reflectPad(_ x: [Float], left: Int, right: Int) -> [Float] {
        let n = x.count
        var out = [Float](repeating: 0, count: n + left + right)
        x.withUnsafeBufferPointer { xp in
            out.withUnsafeMutableBufferPointer { op in
                let base = op.baseAddress!
                let src = xp.baseAddress!
                for i in 0..<left { base[i] = src[left - i] }
                memcpy(base.advanced(by: left), src, n * MemoryLayout<Float>.size)
                for j in 0..<right { base[n + left + j] = src[n - 2 - j] }
            }
        }
        return out
    }

    /// Compute every kept frame's FFT of the reflect-padded signal. The kept
    /// frames (torch frames `2 ..< 2+le`) window `[i*hop, i*hop+nfft)` of the
    /// padded signal — never touching the STFT's own centre reflect padding,
    /// which only frames 0/1 and the tail use and which are dropped.
    private static func frameFFTs(signal: UnsafeBufferPointer<Float>, le: Int,
                                  fft: vDSP.FFT<DSPSplitComplex>,
                                  re: inout [Float], im: inout [Float],
                                  emit: (Int, inout [Float], inout [Float]) -> Void) {
        var windowed = [Float](repeating: 0, count: nfft)
        for frame in 0..<le {
            let offset = frame * hop
            windowed.withUnsafeMutableBufferPointer { wp in
                vDSP_vmul(signal.baseAddress!.advanced(by: offset), 1,
                          window, 1, wp.baseAddress!, 1, vDSP_Length(nfft))
                windowedFFT(windowed: wp, fft: fft, re: &re, im: &im)
            }
            emit(frame, &re, &im)
        }
    }

    /// One windowed frame → bins `0 ..< 2048` (re/im), torch-normalized
    /// (`×1/(2·64)`: vDSP's real FFT returns the DFT scaled by 2, and
    /// `normalized=True` divides by `sqrt(nfft)`).
    private static func windowedFFT(windowed: UnsafeMutableBufferPointer<Float>,
                                    fft: vDSP.FFT<DSPSplitComplex>,
                                    re: inout [Float], im: inout [Float]) {
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nfft / 2) { cp in
                        var packed = split
                        vDSP_ctoz(cp, 2, &packed, 1, vDSP_Length(nfft / 2))
                        fft.forward(input: packed, output: &packed)
                        split = packed
                    }
                }
            }
        }
    }

    /// Write one frame's bins into a `mag` plane (row-major freq, frame).
    /// `re`/`im` already hold the vDSP-packed spectrum: `realp[0]`=DC,
    /// `imagp[0]`=Nyquist, bins 1..2047 split. `imaginary` selects the
    /// `[L.im]`/`[R.im]` plane.
    private static func writeFrame(_ plane: UnsafeMutablePointer<Float>, le: Int,
                                   frame: Int, re: [Float], im: [Float],
                                   imaginary: Bool = false) {
        let stride = le
        let values = imaginary ? im : re
        if imaginary {
            // Bin 0's imaginary part is 0; the vDSP buffer's imagp[0] holds the
            // Nyquist bin's *real* part, which `_spec` drops — so write bins 1..2047.
            for k in 1..<bins {
                plane[k * stride + frame] = values[k] * scaleFactor
            }
        } else {
            plane[frame] = re[0] * scaleFactor
            for k in 1..<bins {
                plane[k * stride + frame] = values[k] * scaleFactor
            }
        }
    }

    /// The torch `normalized=True` forward scale applied to vDSP's ×2 output.
    private static let scaleFactor = Float(1.0 / (2 * sqrt(Double(nfft))))

    /// Assemble the `nfft/2 + 1` complex bins of one frame from a `mag` plane
    /// pair (re/im), dropping the Nyquist bin (`bin 2048 = 0`).
    private static func spectrumFrame(rePlane: UnsafePointer<Float>,
                                      imPlane: UnsafePointer<Float>,
                                      frame: Int, frameCount: Int,
                                      re: inout [Float], im: inout [Float]) {
        let stride = frameCount
        re[0] = rePlane[frame]
        im[0] = 0                       // imagp[0] holds Nyquist real; it is 0 here
        for k in 1..<bins {
            re[k] = rePlane[k * stride + frame]
            im[k] = imPlane[k * stride + frame]
        }
    }

    /// One inverse FFT of the packed spectrum; `emit` receives the `nfft`
    /// time-domain samples (vDSP's packed pair output).
    private static func inverseFrame(fft: vDSP.FFT<DSPSplitComplex>,
                                     re: inout [Float], im: inout [Float],
                                     scratch: inout [Float],
                                     emit: (UnsafePointer<Float>) -> Void) {
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                fft.inverse(input: split, output: &split)
                scratch.withUnsafeMutableBufferPointer { sp in
                    sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nfft / 2) { cp in
                        vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(nfft / 2))
                    }
                    emit(sp.baseAddress!)
                }
            }
        }
    }

    /// The istft's division term: the overlap-add of the squared window over
    /// the same (padded) frames (torch `ifft_window_sum`), clamped to a tiny
    /// floor so the zero tail stays zero instead of dividing by zero.
    private static func windowEnvelope(frames: Int, length: Int) -> [Float] {
        var envelope = [Float](repeating: 0, count: length)
        let w2 = window.map { $0 * $0 }
        envelope.withUnsafeMutableBufferPointer { ep in
            w2.withUnsafeBufferPointer { wp in
                for frame in 0..<frames {
                    let offset = frame * hop
                    vDSP_vadd(ep.baseAddress!.advanced(by: offset), 1,
                              wp.baseAddress!, 1,
                              ep.baseAddress!.advanced(by: offset), 1,
                              vDSP_Length(nfft))
                }
            }
        }
        for i in 0..<envelope.count where envelope[i] < 1e-12 {
            envelope[i] = 1
        }
        return envelope
    }
}
