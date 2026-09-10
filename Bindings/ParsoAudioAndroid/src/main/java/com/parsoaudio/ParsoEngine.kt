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
    private val deckBuffers = arrayOfNulls<DeckBuffer>(deckCount)

    init {
        require(nativeHandle != 0L) {
            "native engine creation failed; check sample rate, maxFrames, and deckCount"
        }
    }

    /**
     * Install caller-owned direct float planes for a deck. The wrapper retains
     * the ByteBuffer references until replacement or [close].
     */
    fun setDeckBuffer(
        deck: Int,
        left: ByteBuffer,
        right: ByteBuffer? = null,
        frames: Int,
        sourceSampleRateHz: Int = sampleRateHz,
    ) {
        val handle = requireOpen()
        require(deck in 0 until deckCount) { "deck is out of range" }
        require(sourceSampleRateHz > 0) { "source sample rate must be positive" }
        require(right == null || right.order() == ByteOrder.nativeOrder()) {
            "right buffer must use the native byte order"
        }
        require(right == null || right.isDirect) { "right buffer must be direct" }
        val channelCount = if (right == null) 1 else 2
        validateBuffer(left, frames, "left")
        if (right != null) validateBuffer(right, frames, "right")
        check(ParsoNative.nativeSetDeckBuffer(
            handle, deck, left, right, frames, sourceSampleRateHz, channelCount
        )) { "native deck buffer was rejected" }
        deckBuffers[deck] = DeckBuffer(left, right)
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
            deckBuffers.fill(null)
        }
    }

    private fun requireOpen(): Long {
        check(nativeHandle != 0L) { "ParsoEngine is closed" }
        return nativeHandle
    }

    private fun validateBuffer(buffer: ByteBuffer, frames: Int, name: String) {
        require(frames > 0) { "frames must be positive" }
        require(buffer.isDirect) { "$name buffer must be direct" }
        require(buffer.order() == ByteOrder.nativeOrder()) {
            "$name buffer must use the native byte order"
        }
        require(buffer.position() == 0) { "$name buffer position must be zero" }
        require(buffer.capacity() >= frames * Float.SIZE_BYTES) {
            "$name buffer is smaller than the requested render block"
        }
    }

    private data class DeckBuffer(val left: ByteBuffer, val right: ByteBuffer?)
}
