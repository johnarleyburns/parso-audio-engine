package com.parsoaudio

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Portable offline analysis results returned by the shared C ABI. */
data class AnalysisSummary(
    val durationSeconds: Double,
    val rms: Double,
    val peak: Double,
    val bpm: Double,
    val bpmConfidence: Double,
)

data class KeyEstimate(
    val tonicPitchClass: Int,
    val isMinor: Boolean,
    val camelotNumber: Int,
    val camelotLetter: Char,
    val confidence: Double,
)

data class StructureSection(
    val startSeconds: Double,
    val kind: Int,
    val bar: Int,
    val energy: Double,
    val confidence: Double,
)

/**
 * Synchronous, off-audio-thread analysis facade. The input is borrowed only
 * for the duration of each call and must be a direct native-order float buffer
 * positioned at zero; callers retain ownership and may reuse it afterward.
 */
object ParsoAnalysis {
    fun summary(
        samples: ByteBuffer,
        frames: Int,
        sampleRateHz: Int,
        channelCount: Int = 1,
    ): AnalysisSummary {
        validate(samples, frames, sampleRateHz, channelCount)
        val result = ParsoNative.nativeAnalysisSummary(samples, frames, sampleRateHz, channelCount)
            ?: error("native analysis summary failed")
        require(result.size == 5) { "native analysis summary has invalid shape" }
        return AnalysisSummary(result[0], result[1], result[2], result[3], result[4])
    }

    fun key(
        samples: ByteBuffer,
        frames: Int,
        sampleRateHz: Int,
        channelCount: Int = 1,
    ): KeyEstimate {
        validate(samples, frames, sampleRateHz, channelCount)
        val result = ParsoNative.nativeKey(samples, frames, sampleRateHz, channelCount)
            ?: error("native key analysis failed")
        require(result.size == 5) { "native key result has invalid shape" }
        return KeyEstimate(
            result[0].toInt(), result[1] != 0.0, result[2].toInt(),
            if (result[3] == 1.0) 'A' else 'B', result[4],
        )
    }

    fun structure(
        samples: ByteBuffer,
        frames: Int,
        sampleRateHz: Int,
        channelCount: Int = 1,
        bpm: Double = 120.0,
        maxSections: Int = 256,
    ): List<StructureSection> {
        validate(samples, frames, sampleRateHz, channelCount)
        require(bpm in 30.0..300.0) { "bpm must be between 30 and 300" }
        require(maxSections in 1..4096) { "maxSections must be between 1 and 4096" }
        val result = ParsoNative.nativeStructure(
            samples, frames, sampleRateHz, channelCount, bpm, maxSections,
        ) ?: error("native structure analysis failed")
        require(result.size % 5 == 0) { "native structure result has invalid shape" }
        return result.asList().chunked(5).map { values ->
            StructureSection(
                values[0], values[1].toInt(), values[2].toInt(), values[3], values[4],
            )
        }
    }

    private fun validate(samples: ByteBuffer, frames: Int, sampleRateHz: Int, channelCount: Int) {
        require(samples.isDirect) { "samples must be direct" }
        require(samples.order() == ByteOrder.nativeOrder()) { "samples must use native byte order" }
        require(samples.position() == 0) { "samples position must be zero" }
        require(frames > 0 && sampleRateHz > 0 && channelCount in 1..2) {
            "invalid PCM format"
        }
        val requiredBytes = Math.multiplyExact(Math.multiplyExact(frames, channelCount), Float.SIZE_BYTES)
        require(samples.capacity() >= requiredBytes) { "samples buffer is too small" }
    }
}
