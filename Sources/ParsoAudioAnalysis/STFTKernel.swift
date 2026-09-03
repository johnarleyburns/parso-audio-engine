//
//  STFTKernel.swift
//  Ported near-verbatim from parso-tonearm/Sources/DJ/Analysis/STFT.swift
//  (audio-engine unification, docs/UNIFICATION_PLAN.md §4 Phase 5).
//

import Foundation
import Accelerate

/// STFT configuration (§21.1). 4096-point Hann at 50% overlap on the 48 kHz
/// working rate gives ~10.8 Hz bins, ~93 ms frames and ~23.4 fps.
public struct STFTConfig: Sendable, Equatable {
    public var fftSize: Int = 4096
    public var hopSize: Int = 2048
    public var sampleRate: Double = AnalysisDecoder.workingSampleRate

    public init(fftSize: Int = 4096, hopSize: Int = 2048,
                sampleRate: Double = AnalysisDecoder.workingSampleRate) {
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.sampleRate = sampleRate
    }

    /// Envelope frame rate in Hz (= sampleRate / hopSize).
    public var frameRateHz: Double { sampleRate / Double(hopSize) }
}

/// The positive-frequency spectrum of one frame (§21.2): `fftSize/2 + 1` bins.
/// Power is magnitude-squared; magnitude is the linear amplitude.
public struct Spectrum: Sendable, Equatable {
    public let power: [Float]
    public let magnitude: [Float]
    /// Frequency (Hz) per bin.
    public let binHz: Double

    public init(power: [Float], binHz: Double) {
        self.power = power
        self.magnitude = power.map { sqrt($0) }
        self.binHz = binHz
    }
}

/// A reusable real-FFT engine (§21.2, App. F.1). The setup, Hann window and
/// scratch buffers are created once and reused across all frames and tracks —
/// per-frame setup allocation is a classic performance bug. Not thread-safe by
/// design; owned by a single analysis job.
public final class STFTKernel {
    public let config: STFTConfig
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let log2n: vDSP_Length
    private var window: [Float]
    private var real: [Float]
    private var imag: [Float]

    public init(config: STFTConfig = STFTConfig()) {
        self.config = config
        precondition(config.fftSize.isPowerOfTwo, "fftSize must be a power of two")
        self.log2n = vDSP_Length(log2(Float(config.fftSize)))
        // Force-unwrap: vDSP.FFT init fails only for unsupported sizes, which
        // the power-of-two precondition already excludes.
        self.fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        self.window = [Float](repeating: 0, count: config.fftSize)
        vDSP_hann_window(&window, vDSP_Length(config.fftSize), Int32(vDSP_HANN_NORM))
        self.real = [Float](repeating: 0, count: config.fftSize / 2)
        self.imag = [Float](repeating: 0, count: config.fftSize / 2)
    }

    /// Compute the power spectrum of one windowed frame. `frame` must contain
    /// `config.fftSize` samples of mono audio; the caller advances by the hop.
    /// Zero per-frame allocation.
    public func spectrum(_ frame: UnsafePointer<Float>) -> Spectrum {
        let n = config.fftSize
        let n2 = n / 2

        // 1) Window the frame.
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // 2) Pack real input as interleaved complex and split it (real-FFT idiom).
        var power = [Float](repeating: 0, count: n2)
        windowed.withUnsafeBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n2) { cp in
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n2))
                        // 3) In-place forward real FFT.
                        fft.forward(input: split, output: &split)
                        // 4) Magnitude-squared per bin -> power spectrum.
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n2))
                    }
                }
            }
        }
        return Spectrum(power: power, binHz: config.sampleRate / Double(n))
    }

    /// Slide the whole mono buffer, returning one spectrum per hop.
    public func spectra(_ mono: UnsafeBufferPointer<Float>) -> [Spectrum] {
        let n = config.fftSize
        let hop = config.hopSize
        guard mono.count >= n else { return [] }
        let frameCount = (mono.count - n) / hop + 1
        var result: [Spectrum] = []
        result.reserveCapacity(frameCount)
        for i in stride(from: 0, to: frameCount * hop, by: hop) {
            result.append(spectrum(mono.baseAddress!.advanced(by: i)))
        }
        return result
    }
}

private extension Int {
    var isPowerOfTwo: Bool { self > 0 && (self & (self - 1)) == 0 }
}
