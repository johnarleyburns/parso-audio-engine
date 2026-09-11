package com.parsoaudio

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Output formats supported by the Android control-side recorder. */
enum class RecordingFormat(val codec: Int) {
    WAV(1),
    FLAC(2),
    AAC(6),
}

/**
 * Control-side recorder for stereo blocks drained from [ParsoEngine]. PCM is
 * copied into managed storage on append; encoding is synchronous and must stay
 * off the audio callback. MP3 and Ogg recording are intentionally unavailable.
 */
class ParsoRecorder(
    private val sampleRateHz: Int,
    private val format: RecordingFormat = RecordingFormat.WAV,
    private val bitrateKbps: Int = 192,
) {
    private val samples = ArrayList<Float>()

    init {
        require(sampleRateHz > 0) { "sample rate must be positive" }
        require(bitrateKbps in 8..512) { "bitrate must be between 8 and 512 kbps" }
    }

    val frames: Int
        get() = samples.size / 2

    /** Append one non-empty stereo block, copying it before returning. */
    fun append(left: ByteBuffer, right: ByteBuffer, blockFrames: Int) {
        require(blockFrames > 0) { "block frames must be positive" }
        validate(left, blockFrames, "left")
        validate(right, blockFrames, "right")
        repeat(blockFrames) { index ->
            samples += left.getFloat(index * Float.SIZE_BYTES)
            samples += right.getFloat(index * Float.SIZE_BYTES)
        }
    }

    /** Drain one record block from the engine and append it; returns frames copied. */
    fun appendEngine(engine: ParsoEngine, maxFrames: Int): Int {
        require(maxFrames > 0) { "max frames must be positive" }
        val left = ByteBuffer.allocateDirect(maxFrames * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
        val right = ByteBuffer.allocateDirect(maxFrames * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
        val drained = engine.drainRecord(left, right, maxFrames)
        if (drained > 0) append(left, right, drained)
        return drained
    }

    /** Encode all accumulated frames through the shared native codec service. */
    fun encode(): ByteArray {
        require(samples.isNotEmpty()) { "cannot encode an empty recording" }
        val interleaved = ByteBuffer.allocateDirect(samples.size * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
        val floats = interleaved.asFloatBuffer()
        samples.forEachIndexed { index, sample -> floats.put(index, sample) }
        return ParsoNative.nativeEncodeRecording(
            interleaved, frames, sampleRateHz, 2, format.codec, bitrateKbps, 0,
        ) ?: error("native recording encode failed")
    }

    fun reset() = samples.clear()

    private fun validate(buffer: ByteBuffer, blockFrames: Int, name: String) {
        require(buffer.isDirect) { "$name buffer must be direct" }
        require(buffer.order() == ByteOrder.nativeOrder()) {
            "$name buffer must use the native byte order"
        }
        require(buffer.position() == 0) { "$name buffer position must be zero" }
        require(buffer.capacity() >= blockFrames * Float.SIZE_BYTES) {
            "$name buffer is too small"
        }
    }
}
