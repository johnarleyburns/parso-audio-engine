package com.parsoaudio

import java.nio.ByteBuffer
import java.nio.ByteOrder

data class ResampledPcm(
    val samples: FloatArray,
    val frames: Int,
    val sampleRateHz: Int,
    val channelCount: Int,
)

data class LoudnessMeasurement(
    val integratedLufs: Double,
    val truePeakDbtp: Double,
    val gainToTargetDb: Double,
    val loudnessRangeLu: Double,
)

/** Shared offline SRC and EBU R128 services; calls must stay off the audio callback. */
object ParsoOffline {
    fun convertSampleRate(
        samples: ByteBuffer,
        frames: Int,
        sourceSampleRateHz: Int,
        destinationSampleRateHz: Int,
        channelCount: Int = 1,
        quality: Int = 0,
    ): ResampledPcm {
        validate(samples, frames, sourceSampleRateHz, channelCount)
        require(destinationSampleRateHz > 0) { "destination sample rate must be positive" }
        require(quality in 0..2) { "quality must be between 0 and 2" }
        val result = ParsoNative.nativeConvertSampleRate(
            samples, frames, sourceSampleRateHz, destinationSampleRateHz, channelCount, quality,
        ) ?: error("native sample-rate conversion failed")
        require(result.size % channelCount == 0) { "native SRC result has invalid shape" }
        return ResampledPcm(result, result.size / channelCount, destinationSampleRateHz, channelCount)
    }

    fun measureLoudness(
        samples: ByteBuffer,
        frames: Int,
        sampleRateHz: Int,
        channelCount: Int = 1,
        targetLufs: Double = -14.0,
    ): LoudnessMeasurement {
        validate(samples, frames, sampleRateHz, channelCount)
        require(targetLufs.isFinite()) { "target LUFS must be finite" }
        val result = ParsoNative.nativeMeasureLoudness(
            samples, frames, sampleRateHz, channelCount, targetLufs,
        ) ?: error("native loudness measurement failed")
        require(result.size == 4) { "native loudness result has invalid shape" }
        return LoudnessMeasurement(result[0], result[1], result[2], result[3])
    }

    private fun validate(samples: ByteBuffer, frames: Int, sampleRateHz: Int, channelCount: Int) {
        require(samples.isDirect) { "samples must be direct" }
        require(samples.order() == ByteOrder.nativeOrder()) { "samples must use native byte order" }
        require(samples.position() == 0) { "samples position must be zero" }
        require(frames > 0 && sampleRateHz > 0 && channelCount in 1..2) { "invalid PCM format" }
        val sampleCount = Math.multiplyExact(frames, channelCount)
        require(samples.capacity() >= Math.multiplyExact(sampleCount, Float.SIZE_BYTES)) {
            "samples buffer is too small"
        }
    }
}
