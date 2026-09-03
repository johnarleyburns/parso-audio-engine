//
//  Energy.swift
//  Ported from parso-tonearm/Sources/DJ/Analysis/Energy.swift (audio-engine
//  unification, docs/UNIFICATION_PLAN.md §4 Phase 5). `EnergyResult` is new —
//  it bundles the scalar + curve + hop so `FullAnalysis` can carry both.
//

import Foundation
import Accelerate

/// Energy curve configuration (§25.2, App. F.7).
public struct EnergyConfig: Sendable, Equatable {
    /// Blend weight for RMS loudness vs spectral activity.
    public var loudnessWeight: Float = 0.6
    /// Smoothing window in beats.
    public var smoothingBeats: Int = 4
    /// Band indices (into `SpectralFrame.bandEnergy`) counted as "activity".
    public var activityBands: ClosedRange<Int> = 5...7

    public init(loudnessWeight: Float = 0.6, smoothingBeats: Int = 4,
                activityBands: ClosedRange<Int> = 5...7) {
        self.loudnessWeight = loudnessWeight
        self.smoothingBeats = smoothingBeats
        self.activityBands = activityBands
    }
}

/// Per-beat energy plus its scalar summary (§25.2). `hopSeconds` is the STFT hop
/// the curve was measured at — carried so a consumer can time-align the curve.
public struct EnergyResult: Sendable, Equatable {
    public var scalar: Float
    public var curve: [Float]
    public var hopSeconds: Double

    public init(scalar: Float, curve: [Float], hopSeconds: Double) {
        self.scalar = scalar
        self.curve = curve
        self.hopSeconds = hopSeconds
    }
}

/// Per-beat perceived energy (App. F.7, §25.2): a normalized blend of loudness
/// (RMS) and high-frequency spectral activity, smoothed over a few beats. The
/// result feeds phrase segmentation, transition scoring, and `track.energy`.
public enum EnergyAnalyzer {

    /// Per-beat energy in [0,1] for the beats in `beatSamples`.
    /// `frames` is the per-STFT-frame feature sequence at the given frame rate.
    public static func curve(frames: [SpectralFrame], beatSamples: [Int64],
                             frameRateHz: Double, sampleRate: Double,
                             config: EnergyConfig = EnergyConfig()) -> [Float] {
        guard !beatSamples.isEmpty, !frames.isEmpty else { return [] }

        // Frame index nearest each beat's sample position.
        func frameIndex(for sample: Int64) -> Int {
            let seconds = Double(sample) / sampleRate
            let idx = Int((seconds * frameRateHz).rounded())
            return max(0, min(frames.count - 1, idx))
        }

        func atFrame(_ idx: Int) -> Float {
            let f = frames[idx]
            let loud = f.rms
            var hf: Float = 0
            for b in config.activityBands where b >= 0 && b < 8 {
                hf += f.bandEnergy[b]
            }
            let blended = config.loudnessWeight * loud + (1 - config.loudnessWeight) * sqrt(max(0, hf))
            return blended
        }

        var raw = beatSamples.map { atFrame(frameIndex(for: $0)) }

        // Normalize to [0,1] by the peak (F.7).
        if let mx = raw.max(), mx > 0 {
            raw = raw.map { min(1, $0 / mx) }
        }

        // Moving average over a few beats (F.7).
        let window = max(1, config.smoothingBeats)
        var smoothed = [Float](repeating: 0, count: raw.count)
        var acc: Float = 0
        var count = 0
        for i in 0..<raw.count {
            acc += raw[i]
            count += 1
            if i >= window { acc -= raw[i - window]; count -= 1 }
            smoothed[i] = count > 0 ? acc / Float(count) : 0
        }
        return smoothed
    }

    /// Scalar track energy on a 0...10 scale: the robust central tendency
    /// (median) of the normalized curve (§25.2). Silence → 0.
    public static func scalar(_ curve: [Float]) -> Float {
        guard !curve.isEmpty else { return 0 }
        let sorted = curve.sorted()
        let median = sorted[sorted.count / 2]
        return min(10, max(0, median * 10))
    }
}
