package com.parsoaudio

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Xiph Ogg Vorbis encoder backed by the shared permissive native bridge. */
object ParsoVorbis {
    fun encode(
        samples: ByteBuffer,
        frames: Int,
        sampleRateHz: Int,
        channelCount: Int = 1,
        bitrateKbps: Int = 192,
    ): ByteArray {
        require(samples.isDirect) { "samples must be direct" }
        require(samples.order() == ByteOrder.nativeOrder()) { "samples must use native byte order" }
        require(samples.position() == 0) { "samples position must be zero" }
        require(frames > 0 && sampleRateHz > 0 && channelCount in 1..2) { "invalid PCM format" }
        require(bitrateKbps in 8..512) { "bitrate must be between 8 and 512 kbps" }
        val sampleCount = Math.multiplyExact(frames, channelCount)
        require(samples.capacity() >= Math.multiplyExact(sampleCount, Float.SIZE_BYTES)) {
            "samples buffer is too small"
        }
        return ParsoNative.nativeEncodeOggVorbis(
            samples, frames, sampleRateHz, channelCount, bitrateKbps,
        ) ?: error("native Ogg Vorbis encoding failed")
    }
}
