package com.parsoaudio

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Closeable Kotlin facade for the direct-buffer JNI render seam.
 *
 * One owner must serialize control, render, and close calls. In particular,
 * stop the device callback before calling [close]; this wrapper deliberately
 * adds no lock to the audio path. The direct buffers must be allocated with
 * [ByteBuffer.allocateDirect], use [ByteOrder.nativeOrder], and have position 0.
 */
class ParsoEngine(
    private val sampleRateHz: Int = 48_000,
    private val maxFrames: Int = 512,
    private val deckCount: Int = 2,
) : AutoCloseable {
    private var nativeHandle: Long = ParsoNative.nativeCreate(sampleRateHz, maxFrames, deckCount)

    init {
        require(nativeHandle != 0L) {
            "native engine creation failed; check sample rate, maxFrames, and deckCount"
        }
    }

    /** Queue a play command for one of the configured decks. */
    fun play(deck: Int) {
        val handle = requireOpen()
        require(deck in 0 until deckCount) { "deck is out of range" }
        check(ParsoNative.nativePlay(handle, deck)) { "native play command was rejected" }
    }

    /** Fill caller-owned stereo direct buffers and return the rendered frame count. */
    fun render(left: ByteBuffer, right: ByteBuffer, frames: Int): Int {
        val handle = requireOpen()
        require(frames in 1..maxFrames) { "frames must be between 1 and maxFrames" }
        validateBuffer(left, frames, "left")
        validateBuffer(right, frames, "right")
        val rendered = ParsoNative.nativeRender(handle, left, right, frames)
        check(rendered == frames) { "native render failed: $rendered" }
        return rendered
    }

    /** Idempotently destroy the native engine after its callback has stopped. */
    override fun close() {
        val handle = nativeHandle
        if (handle != 0L) {
            nativeHandle = 0L
            ParsoNative.nativeDestroy(handle)
        }
    }

    private fun requireOpen(): Long {
        check(nativeHandle != 0L) { "ParsoEngine is closed" }
        return nativeHandle
    }

    private fun validateBuffer(buffer: ByteBuffer, frames: Int, name: String) {
        require(buffer.isDirect) { "$name buffer must be direct" }
        require(buffer.order() == ByteOrder.nativeOrder()) {
            "$name buffer must use the native byte order"
        }
        require(buffer.position() == 0) { "$name buffer position must be zero" }
        require(buffer.capacity() >= frames * Float.SIZE_BYTES) {
            "$name buffer is smaller than the requested render block"
        }
    }
}
