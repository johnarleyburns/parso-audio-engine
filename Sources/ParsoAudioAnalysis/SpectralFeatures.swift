//
//  SpectralFeatures.swift
//  Ported verbatim from parso-tonearm/Sources/DJ/Analysis/SpectralFeatures.swift
//  (audio-engine unification, docs/UNIFICATION_PLAN.md §4 Phase 5).
//

import Foundation
import Accelerate

/// Per-frame spectral features (§21.3, App. F.2). All are vDSP reductions over
/// the power spectrum, deterministic for a fixed input.
public struct SpectralFrame: Equatable, Sendable {
    public var centroid: Float
    public var rolloff: Float
    public var flux: Float
    public var rms: Float
    public var zcr: Float
    /// Eight log-spaced band energies (sub-bass … air).
    public var bandEnergy: SIMD8<Float>

    public init(centroid: Float = 0, rolloff: Float = 0, flux: Float = 0,
                rms: Float = 0, zcr: Float = 0, bandEnergy: SIMD8<Float> = .zero) {
        self.centroid = centroid
        self.rolloff = rolloff
        self.flux = flux
        self.rms = rms
        self.zcr = zcr
        self.bandEnergy = bandEnergy
    }
}

public enum SpectralFeatures {
    /// 85% spectral rolloff.
    public static let rolloffPercent: Float = 0.85

    /// Eight log-spaced band edge bins across the positive spectrum
    /// (sub-bass … air), per App. F.2's `bandEdgeBins`.
    public static func bandEdges(n2: Int, sampleRate: Float) -> [Int] {
        guard n2 > 1 else { return [0, 1] }
        let binHz = sampleRate / Float(2 * n2)
        // Log-spaced edges from ~30 Hz to the Nyquist, 9 edges -> 8 bands.
        let fMin: Float = 30
        let fMax: Float = sampleRate / 2
        let logMin = log10(fMin)
        let logMax = log10(fMax)
        var edges: [Int] = []
        for i in 0...8 {
            let f = pow(10, logMin + (logMax - logMin) * Float(i) / 8)
            edges.append(min(n2, max(0, Int((f / binHz).rounded()))))
        }
        // Ensure strictly increasing.
        for i in 1..<edges.count where edges[i] <= edges[i - 1] {
            edges[i] = edges[i - 1] + 1
        }
        return edges
    }

    /// Per-frame features for one spectrum. `prevPower` is the previous frame's
    /// power spectrum (same length); use the current frame for the first frame.
    public static func frame(_ spectrum: Spectrum, prevPower: [Float],
                             frameSamples: UnsafeBufferPointer<Float>) -> SpectralFrame {
        let power = spectrum.power
        let n2 = power.count
        var total: Float = 0
        vDSP_sve(power, 1, &total, vDSP_Length(n2))

        // Centroid: sum f·P / sum P.
        var num: Float = 0
        for k in 0..<n2 { num += Float(k) * power[k] }
        let centroid = total > 0 ? (num / total) * Float(spectrum.binHz) : 0

        // Rolloff: frequency below which 85% of energy lies.
        var cum: Float = 0
        let thresh = total * rolloffPercent
        var rolloffBin = n2 - 1
        for k in 0..<n2 {
            cum += power[k]
            if cum >= thresh { rolloffBin = k; break }
        }
        let rolloff = Float(rolloffBin) * Float(spectrum.binHz)

        // Flux: half-wave-rectified spectral difference vs the previous frame.
        var flux: Float = 0
        for k in 0..<n2 {
            let d = power[k] - prevPower[k]
            if d > 0 { flux += d }
        }

        // RMS of the time-domain frame.
        var rms: Float = 0
        vDSP_rmsqv(frameSamples.baseAddress!, 1, &rms, vDSP_Length(frameSamples.count))

        // Zero-crossing rate.
        var zc = 0
        let samples = frameSamples
        for i in 1..<samples.count {
            if (samples[i] >= 0) != (samples[i - 1] >= 0) { zc += 1 }
        }
        let zcr = Float(zc) / Float(samples.count)

        // Eight log-spaced band energies.
        var bands = SIMD8<Float>(repeating: 0)
        let edges = bandEdges(n2: n2, sampleRate: Float(spectrum.binHz * Double(2 * n2)))
        for b in 0..<8 {
            var e: Float = 0
            let lo = max(1, edges[b])
            let hi = min(n2, edges[b + 1])
            for k in lo..<hi { e += power[k] }
            bands[b] = e
        }

        return SpectralFrame(centroid: centroid, rolloff: rolloff, flux: flux,
                             rms: rms, zcr: zcr, bandEnergy: bands)
    }
}
