//
//  Onsets.swift
//  Ported verbatim from parso-tonearm/Sources/DJ/Analysis/Onsets.swift
//  (audio-engine unification, docs/UNIFICATION_PLAN.md §4 Phase 5).
//

import Foundation
import Accelerate

/// Onset detection configuration (§22.1). Multi-band spectral flux with
/// transient-relevant bands, adaptive mean removal and threshold peak-picking.
public struct OnsetConfig: Sendable, Equatable {
    public var bands: [ClosedRange<Float>] = [20...120, 120...2_000, 2_000...16_000]
    public var bandWeights: [Float] = [1.0, 0.8, 0.6]
    /// Window for the moving mean used to remove slow drift (in frames).
    public var meanRemovalWindow: Int = 16
    /// Window for the adaptive peak-picking threshold (in frames).
    /// Must be smaller than the shortest beat interval you expect: at the DJ
    /// tempo floor (~60 BPM) a beat is ~19 frames at 23.4 fps, so 8 frames
    /// (~0.34 s) stays safely under it.
    public var thresholdWindow: Int = 8
    /// Threshold multiple of the local standard deviation above the local mean.
    public var thresholdK: Float = 2.0
    /// Minimum inter-onset gap in seconds (refractory period).
    public var minGapSeconds: Double = 0.03

    public init(bands: [ClosedRange<Float>] = [20...120, 120...2_000, 2_000...16_000],
                bandWeights: [Float] = [1.0, 0.8, 0.6],
                meanRemovalWindow: Int = 16,
                thresholdWindow: Int = 8,
                thresholdK: Float = 2.0,
                minGapSeconds: Double = 0.03) {
        self.bands = bands
        self.bandWeights = bandWeights
        self.meanRemovalWindow = meanRemovalWindow
        self.thresholdWindow = thresholdWindow
        self.thresholdK = thresholdK
        self.minGapSeconds = minGapSeconds
    }
}

/// A detected onset (App. F.3).
public struct OnsetPeak: Equatable, Sendable {
    /// Frame index into the onset envelope.
    public var frameIndex: Int
    /// Time in seconds.
    public var timeSeconds: Double
    /// Normalized novelty strength (0...1).
    public var strength: Float
}

public enum OnsetDetector {
    /// The multi-band spectral-flux novelty envelope (§22.1). Sums the
    /// half-wave-rectified flux within each band, weighted toward percussive
    /// content, removes slow drift with a moving mean, and normalizes to 0...1.
    public static func envelope(spectra: [Spectrum], config: OnsetConfig = OnsetConfig()) -> [Float] {
        guard let first = spectra.first else { return [] }
        let n2 = first.power.count
        let binHz = first.binHz

        // Per-band per-frame energy.
        var bandEnergies: [[Float]] = config.bands.map { _ in [Float](repeating: 0, count: spectra.count) }
        for (b, band) in config.bands.enumerated() {
            let lo = max(1, Int((band.lowerBound / Float(binHz)).rounded()))
            let hi = min(n2, Int((band.upperBound / Float(binHz)).rounded()))
            for (i, spec) in spectra.enumerated() {
                var e: Float = 0
                for k in lo..<hi { e += spec.power[k] }
                bandEnergies[b][i] = e
            }
        }

        // Half-wave-rectified flux per band, weighted sum.
        var novelty = [Float](repeating: 0, count: spectra.count)
        for (b, energies) in bandEnergies.enumerated() {
            for i in 1..<energies.count {
                let d = energies[i] - energies[i - 1]
                if d > 0 { novelty[i] += config.bandWeights[b] * d }
            }
        }

        // Remove slow drift with a moving mean, then half-wave rectify.
        let window = max(1, config.meanRemovalWindow)
        var denoised = [Float](repeating: 0, count: novelty.count)
        for i in novelty.indices {
            let lo = max(0, i - window / 2)
            let hi = min(novelty.count, i + window / 2 + 1)
            var sum: Float = 0
            for j in lo..<hi { sum += novelty[j] }
            denoised[i] = max(0, novelty[i] - sum / Float(hi - lo))
        }

        // Normalize to 0...1.
        if let mx = denoised.max(), mx > 0 {
            return denoised.map { $0 / mx }
        }
        return denoised
    }

    /// Adaptive-threshold peak picking (§22.2, App. F.3): local maxima above
    /// `mean + k·std` with a refractory gap.
    public static func peaks(_ envelope: [Float], config: OnsetConfig = OnsetConfig(),
                             frameRateHz: Double) -> [OnsetPeak] {
        guard envelope.count > 2 else { return [] }
        let minGap = max(1, Int((config.minGapSeconds * frameRateHz).rounded()))
        let window = max(1, config.thresholdWindow)

        var peaks: [OnsetPeak] = []
        var last = -minGap
        for i in 1..<(envelope.count - 1) {
            let v = envelope[i]
            guard v > envelope[i - 1] && v >= envelope[i + 1] else { continue }

            // Local mean + k·std over the window.
            let lo = max(0, i - window)
            let hi = min(envelope.count, i + window + 1)
            var sum: Float = 0
            var sumSq: Float = 0
            for j in lo..<hi {
                sum += envelope[j]
                sumSq += envelope[j] * envelope[j]
            }
            let count = Float(hi - lo)
            let mean = sum / count
            let variance = max(0, sumSq / count - mean * mean)
            let threshold = mean + config.thresholdK * sqrt(variance)

            if v >= threshold && (i - last) >= minGap {
                // Sub-frame parabolic refinement so peak times are not locked
                // to the frame grid (§23.1, FR-ANL-4).
                let delta = BeatTracker.subFrameOffset(envelope, at: i) ?? 0
                peaks.append(OnsetPeak(frameIndex: i,
                                       timeSeconds: (Double(i) + Double(delta)) / frameRateHz,
                                       strength: v))
                last = i
            }
        }
        return peaks
    }
}
