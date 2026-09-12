import Foundation
import Cebur128

// MARK: - Loudness / auto-gain (libebur128)

public struct LoudnessResult: Sendable, Equatable {
    public var integratedLUFS: Double
    public var truePeakDBTP: Double
    /// Gain (dB) to reach the analyzer's target loudness.
    public var gainToTargetDB: Double
    /// EBU R128 loudness range (LU) — the p95−p10 spread of short-term
    /// loudness. `0` when the buffer is shorter than one 3 s short-term window
    /// (`EBUR128_MODE_LRA`'s minimum). Used by `ParsoAudioAnalysis` (Phase 5).
    public var loudnessRangeLU: Double

    public init(integratedLUFS: Double, truePeakDBTP: Double, gainToTargetDB: Double,
                loudnessRangeLU: Double = 0) {
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
        self.gainToTargetDB = gainToTargetDB
        self.loudnessRangeLU = loudnessRangeLU
    }
}

public struct LoudnessAnalyzer: Sendable {
    public var targetLUFS: Double
    public init(targetLUFS: Double = -14.0) { self.targetLUFS = targetLUFS }
    public func measure(_ buffer: PCMBuffer) -> LoudnessResult {
        let channels = buffer.channelCount
        let mode = EBUR128_MODE_I.rawValue | EBUR128_MODE_TRUE_PEAK.rawValue | EBUR128_MODE_LRA.rawValue
        var optionalState = ebur128_init(
            UInt32(channels),
            UInt(buffer.format.sampleRate.rounded()),
            Int32(mode)
        )
        guard let state = optionalState else {
            return LoudnessResult(
                integratedLUFS: -.infinity,
                truePeakDBTP: -.infinity,
                gainToTargetDB: .infinity
            )
        }
        defer { ebur128_destroy(&optionalState) }

        var interleaved = [Float](repeating: 0, count: buffer.frameCount * channels)
        for frame in 0..<buffer.frameCount {
            for channel in 0..<channels {
                interleaved[frame * channels + channel] = buffer.channel(channel)[frame]
            }
        }
        interleaved.withUnsafeBufferPointer {
            _ = ebur128_add_frames_float(state, $0.baseAddress, buffer.frameCount)
        }

        var integratedLUFS = -Double.infinity
        _ = ebur128_loudness_global(state, &integratedLUFS)

        var truePeak = 0.0
        for channel in 0..<channels {
            var channelPeak = 0.0
            if ebur128_true_peak(state, UInt32(channel), &channelPeak) == EBUR128_SUCCESS.rawValue {
                truePeak = max(truePeak, channelPeak)
            }
        }
        let truePeakDBTP = truePeak > 0 ? 20 * log10(truePeak) : -Double.infinity

        // LRA needs at least one 3 s short-term window; on a shorter buffer
        // ebur128 returns a non-success code and we report 0.
        var loudnessRangeLU = 0.0
        if ebur128_loudness_range(state, &loudnessRangeLU) != EBUR128_SUCCESS.rawValue
            || !loudnessRangeLU.isFinite {
            loudnessRangeLU = 0
        }

        return LoudnessResult(
            integratedLUFS: integratedLUFS,
            truePeakDBTP: truePeakDBTP,
            gainToTargetDB: targetLUFS - integratedLUFS,
            loudnessRangeLU: max(0, loudnessRangeLU)
        )
    }
}


