//
//  SpleeterSpectrogram.swift
//  The STFT/mask/ISTFT frontend matching Deezer's Spleeter `4stems`
//  configuration (Phase 7c). New in this session — not a port; there is no
//  existing Swift or Core ML Spleeter implementation in either repo to port
//  from, unlike the CLAP (tools/clap-coreml) and Demucs (tools/demucs-coreml)
//  cases which had a verified conversion tool and golden reference tensors.
//
//  Parameters below are Spleeter's published `4stems` config
//  (github.com/deezer/spleeter, `configs/4stems/base_config.json`): a 4096-
//  sample STFT window, 1024-sample hop (75% overlap), 44.1 kHz, and a U-Net
//  operating on a 1024-frequency-bin × 512-time-frame crop of the spectrogram.
//  Source separation is ratio ("soft") masking: each source's mask is its
//  predicted magnitude raised to `maskPower`, normalized so the four masks
//  sum to 1 at every bin, applied to the mixture's complex STFT (phase is
//  reused from the mixture — Spleeter does not model phase), then inverted.
//
//  Honesty note (unlike DemucsSpectrogram, which is pinned to golden torch
//  tensors): this frontend is believed correct against Spleeter's published
//  architecture and config, but has **not** been verified bit-for-bit
//  against the reference Python `Separator.separate()` output — there is no
//  converted Core ML model or reference audio in this repo to check it
//  against yet. Treat the exact scale/windowing constants as "best available
//  from the public spec" until a real conversion (a `tools/spleeter-coreml`
//  tool, mirroring the existing `tools/demucs-coreml`/`tools/clap-coreml`)
//  produces golden vectors to pin against, the same way `StemSpectrogramTests`
//  pins `DemucsSpectrogram`.
//
#if !os(watchOS)
import Accelerate
import Foundation

public struct SpleeterSpectrogram: Sendable {

    /// Spleeter's training/inference sample rate.
    public static let sampleRate: Double = 44_100
    /// STFT window length.
    public static let nfft = 4096
    /// STFT hop length (75% overlap).
    public static let hop = 1024
    /// Frequency bins the U-Net operates on (a crop of the full `nfft/2+1`
    /// real-FFT output; higher bins are carried through unmasked/passthrough
    /// on the mixture, per Spleeter's `extend_mask: "zeros"` default, which
    /// this frontend implements as "leave those bins in `other`'s mask 1.0,
    /// every other source 0.0" — the highest-frequency content lands in the
    /// catch-all voice rather than being silently dropped).
    public static let modelBins = 1024
    /// Time frames per model input patch.
    public static let modelFrames = 512
    /// Exponent applied to each source's predicted magnitude before
    /// normalizing into a ratio mask (Spleeter's default `separation_exponent`).
    public static let maskPower: Float = 2
    /// Denominator floor so a silent frame does not divide by zero.
    public static let maskEpsilon: Float = 1e-10

    /// The full real-FFT bin count for `nfft` (`nfft/2 + 1`).
    public static let fullBins = nfft / 2 + 1

    private static let window: [Float] = {
        (0..<nfft).map { i in
            Float(0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(nfft))))
        }
    }()

    // MARK: - Forward STFT (one channel)

    /// One channel's complex STFT, `frames × fullBins`, row-major
    /// `[frame][bin]`, from a periodic-Hann-windowed FFT at `hop` stride.
    /// `signal` is zero-padded on the right to a whole number of frames.
    public struct ChannelSpectrum: Sendable {
        public let frames: Int
        public let re: [Float]
        public let im: [Float]
    }

    public static func forward(_ signal: [Float]) -> ChannelSpectrum {
        guard !signal.isEmpty else { return ChannelSpectrum(frames: 0, re: [], im: []) }
        let frameCount = max(1, (signal.count - nfft) / hop + 2)
        let padded = signal + [Float](repeating: 0, count: max(0, (frameCount - 1) * hop + nfft - signal.count))

        var re = [Float](repeating: 0, count: frameCount * fullBins)
        var im = [Float](repeating: 0, count: frameCount * fullBins)
        let log2n = vDSP_Length(log2(Double(nfft)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return ChannelSpectrum(frames: frameCount, re: re, im: im)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let n2 = nfft / 2
        var rbuf = [Float](repeating: 0, count: n2)
        var ibuf = [Float](repeating: 0, count: n2)
        var windowed = [Float](repeating: 0, count: nfft)

        padded.withUnsafeBufferPointer { base in
            for t in 0..<frameCount {
                let offset = t * hop
                guard offset + nfft <= padded.count else { break }
                windowed.withUnsafeMutableBufferPointer { wp in
                    vDSP_vmul(base.baseAddress!.advanced(by: offset), 1, window, 1,
                              wp.baseAddress!, 1, vDSP_Length(nfft))
                    rbuf.withUnsafeMutableBufferPointer { rp in
                        ibuf.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n2) { cp in
                                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n2))
                            }
                            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                            var scale: Float = 0.5
                            vDSP_vsmul(split.realp, 1, &scale, rp.baseAddress!, 1, vDSP_Length(n2))
                            vDSP_vsmul(split.imagp, 1, &scale, ip.baseAddress!, 1, vDSP_Length(n2))
                        }
                    }
                }
                re.withUnsafeMutableBufferPointer { rowRe in
                    im.withUnsafeMutableBufferPointer { rowIm in
                        let base = t * fullBins
                        rowRe[base] = rbuf[0]
                        rowIm[base] = 0
                        for k in 1..<n2 { rowRe[base + k] = rbuf[k]; rowIm[base + k] = ibuf[k] }
                        rowRe[base + n2] = ibuf[0]
                        rowIm[base + n2] = 0
                    }
                }
            }
        }
        return ChannelSpectrum(frames: frameCount, re: re, im: im)
    }

    // MARK: - Masking

    /// Ratio-mask the mixture spectrum with four predicted-magnitude planes
    /// (one per `SeparationVoice`, each `frames × modelBins`) and reconstruct each
    /// source's complex spectrum at the mixture's full bin count. Bins above
    /// `modelBins` (outside the U-Net's crop) pass through entirely into
    /// `.other`, zeroed for the other three sources — Spleeter's
    /// `extend_mask: "zeros"` default.
    public static func maskedSpectra(mixture: ChannelSpectrum,
                                     predictedMagnitudes: [SeparationVoice: [Float]])
        -> [SeparationVoice: ChannelSpectrum] {
        let frames = mixture.frames
        var masks: [SeparationVoice: [Float]] = [:]
        for kind in SeparationVoice.allCases {
            masks[kind] = [Float](repeating: 0, count: frames * modelBins)
        }
        for t in 0..<frames {
            for b in 0..<modelBins {
                var denom: Float = maskEpsilon
                var powered: [SeparationVoice: Float] = [:]
                for kind in SeparationVoice.allCases {
                    let mag = predictedMagnitudes[kind]?[t * modelBins + b] ?? 0
                    let p = powf(max(0, mag), maskPower)
                    powered[kind] = p
                    denom += p
                }
                for kind in SeparationVoice.allCases {
                    masks[kind]![t * modelBins + b] = (powered[kind] ?? 0) / denom
                }
            }
        }

        var out: [SeparationVoice: ChannelSpectrum] = [:]
        for kind in SeparationVoice.allCases {
            var re = [Float](repeating: 0, count: frames * fullBins)
            var im = [Float](repeating: 0, count: frames * fullBins)
            let mask = masks[kind]!
            for t in 0..<frames {
                for b in 0..<fullBins {
                    let mixIdx = t * fullBins + b
                    if b < modelBins {
                        let m = mask[t * modelBins + b]
                        re[mixIdx] = mixture.re[mixIdx] * m
                        im[mixIdx] = mixture.im[mixIdx] * m
                    } else if kind == .other {
                        re[mixIdx] = mixture.re[mixIdx]
                        im[mixIdx] = mixture.im[mixIdx]
                    }
                }
            }
            out[kind] = ChannelSpectrum(frames: frames, re: re, im: im)
        }
        return out
    }

    // MARK: - Inverse STFT

    /// Overlap-add ISTFT of one channel's complex spectrum back to `length`
    /// time-domain samples, normalized by the summed squared window (the
    /// standard COLA denominator for a Hann window at 75% overlap).
    public static func inverse(_ spectrum: ChannelSpectrum, length: Int) -> [Float] {
        guard spectrum.frames > 0 else { return [Float](repeating: 0, count: length) }
        let n2 = nfft / 2
        let log2n = vDSP_Length(log2(Double(nfft)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 0, count: length)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let totalLength = (spectrum.frames - 1) * hop + nfft
        var ola = [Float](repeating: 0, count: totalLength)
        var envelope = [Float](repeating: 0, count: totalLength)
        let w2 = window.map { $0 * $0 }

        var rbuf = [Float](repeating: 0, count: n2)
        var ibuf = [Float](repeating: 0, count: n2)
        var scratch = [Float](repeating: 0, count: nfft)

        for t in 0..<spectrum.frames {
            let base = t * fullBins
            rbuf[0] = spectrum.re[base]
            ibuf[0] = spectrum.im[base + n2]
            for k in 1..<n2 { rbuf[k] = spectrum.re[base + k]; ibuf[k] = spectrum.im[base + k] }

            rbuf.withUnsafeMutableBufferPointer { rp in
                ibuf.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                    scratch.withUnsafeMutableBufferPointer { sp in
                        sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n2) { cp in
                            vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(n2))
                        }
                        // vDSP's zrip inverse returns nfft × the true IDFT.
                        var scale = Float(1.0 / Double(nfft))
                        vDSP_vsmul(sp.baseAddress!, 1, &scale, sp.baseAddress!, 1, vDSP_Length(nfft))
                        var windowed = [Float](repeating: 0, count: nfft)
                        vDSP_vmul(sp.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(nfft))
                        let offset = t * hop
                        ola.withUnsafeMutableBufferPointer { op in
                            windowed.withUnsafeBufferPointer { wp in
                                vDSP_vadd(op.baseAddress!.advanced(by: offset), 1, wp.baseAddress!, 1,
                                          op.baseAddress!.advanced(by: offset), 1, vDSP_Length(nfft))
                            }
                        }
                        envelope.withUnsafeMutableBufferPointer { ep in
                            w2.withUnsafeBufferPointer { w2p in
                                vDSP_vadd(ep.baseAddress!.advanced(by: offset), 1, w2p.baseAddress!, 1,
                                          ep.baseAddress!.advanced(by: offset), 1, vDSP_Length(nfft))
                            }
                        }
                    }
                }
            }
        }
        for i in 0..<envelope.count where envelope[i] < 1e-8 { envelope[i] = 1 }
        vDSP_vdiv(envelope, 1, ola, 1, &ola, 1, vDSP_Length(totalLength))

        var out = [Float](repeating: 0, count: length)
        let copyCount = min(length, totalLength)
        out.withUnsafeMutableBufferPointer { op in
            ola.withUnsafeBufferPointer { olap in
                op.baseAddress!.update(from: olap.baseAddress!, count: copyCount)
            }
        }
        return out
    }

    /// Crop/pad one channel's magnitude spectrum to the model's fixed
    /// `modelFrames × modelBins` input patch, one patch per `modelFrames`
    /// (zero-padding the final, shorter patch).
    public static func magnitudePatches(_ spectrum: ChannelSpectrum) -> [[Float]] {
        guard spectrum.frames > 0 else { return [] }
        var magnitude = [Float](repeating: 0, count: spectrum.frames * fullBins)
        vDSP_vdist(spectrum.re, 1, spectrum.im, 1, &magnitude, 1, vDSP_Length(spectrum.frames * fullBins))

        var patches: [[Float]] = []
        var start = 0
        while start < spectrum.frames {
            var patch = [Float](repeating: 0, count: modelFrames * modelBins)
            let framesInPatch = min(modelFrames, spectrum.frames - start)
            for t in 0..<framesInPatch {
                let srcBase = (start + t) * fullBins
                let dstBase = t * modelBins
                for b in 0..<modelBins {
                    patch[dstBase + b] = magnitude[srcBase + b]
                }
            }
            patches.append(patch)
            start += modelFrames
        }
        return patches
    }
}
#endif
