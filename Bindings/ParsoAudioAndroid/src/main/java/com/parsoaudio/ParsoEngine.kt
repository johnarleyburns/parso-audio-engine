package com.parsoaudio

import java.nio.ByteBuffer
import java.nio.ByteOrder

internal interface NativeEngineBridge {
    fun create(sampleRateHz: Int, maxFrames: Int, deckCount: Int): Long
    fun destroy(handle: Long)
    fun setDeckBuffer(
        handle: Long,
        deck: Int,
        left: ByteBuffer,
        right: ByteBuffer?,
        frames: Int,
        sampleRateHz: Int,
        channelCount: Int,
    ): Boolean
    fun play(handle: Long, deck: Int): Boolean
    fun pause(handle: Long, deck: Int): Boolean
    fun setMix(handle: Long, crossfader: Float, masterLevel: Float): Boolean
    fun render(handle: Long, left: ByteBuffer, right: ByteBuffer, frames: Int): Int
    fun setRecordActive(handle: Long, active: Boolean): Boolean
    fun drainRecord(handle: Long, left: ByteBuffer, right: ByteBuffer, maxFrames: Int): Int
    fun recordDroppedFrames(handle: Long): Long
    fun resetRecord(handle: Long): Boolean
}

private object JniEngineBridge : NativeEngineBridge {
    override fun create(sampleRateHz: Int, maxFrames: Int, deckCount: Int): Long =
        ParsoNative.nativeCreate(sampleRateHz, maxFrames, deckCount)

    override fun destroy(handle: Long) = ParsoNative.nativeDestroy(handle)

    override fun setDeckBuffer(
        handle: Long,
        deck: Int,
        left: ByteBuffer,
        right: ByteBuffer?,
        frames: Int,
        sampleRateHz: Int,
        channelCount: Int,
    ): Boolean = ParsoNative.nativeSetDeckBuffer(
        handle, deck, left, right, frames, sampleRateHz, channelCount
    )

    override fun play(handle: Long, deck: Int): Boolean = ParsoNative.nativePlay(handle, deck)

    override fun pause(handle: Long, deck: Int): Boolean = ParsoNative.nativePause(handle, deck)

    override fun setMix(handle: Long, crossfader: Float, masterLevel: Float): Boolean =
        ParsoNative.nativeSetMix(handle, crossfader, masterLevel)

    override fun render(handle: Long, left: ByteBuffer, right: ByteBuffer, frames: Int): Int =
        ParsoNative.nativeRender(handle, left, right, frames)

    override fun setRecordActive(handle: Long, active: Boolean): Boolean =
        ParsoNative.nativeRecordSetActive(handle, active)

    override fun drainRecord(handle: Long, left: ByteBuffer, right: ByteBuffer, maxFrames: Int): Int =
        ParsoNative.nativeRecordDrain(handle, left, right, maxFrames)

    override fun recordDroppedFrames(handle: Long): Long =
        ParsoNative.nativeRecordDroppedFrames(handle)

    override fun resetRecord(handle: Long): Boolean = ParsoNative.nativeRecordReset(handle)
}

/**
 * Closeable Kotlin facade for the direct-buffer JNI render seam.
 *
 * One owner must serialize control, render, and close calls. In particular,
 * stop the device callback before calling [close]; this wrapper deliberately
 * adds no lock to the audio path. The direct buffers must be allocated with
 * [ByteBuffer.allocateDirect], use [ByteOrder.nativeOrder], and have position 0.
 */
class ParsoEngine private constructor(
    private val sampleRateHz: Int,
    private val maxFrames: Int,
    private val deckCount: Int,
    private val native: NativeEngineBridge,
) : AutoCloseable {
    constructor(
        sampleRateHz: Int = 48_000,
        maxFrames: Int = 512,
        deckCount: Int = 2,
    ) : this(sampleRateHz, maxFrames, deckCount, JniEngineBridge)

    private var nativeHandle: Long = native.create(sampleRateHz, maxFrames, deckCount)
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
        check(native.setDeckBuffer(
            handle, deck, left, right, frames, sourceSampleRateHz, channelCount
        )) { "native deck buffer was rejected" }
        deckBuffers[deck] = DeckBuffer(left, right)
    }

    /** Queue a play command for one of the configured decks. */
    fun play(deck: Int) {
        val handle = requireOpen()
        require(deck in 0 until deckCount) { "deck is out of range" }
        check(native.play(handle, deck)) { "native play command was rejected" }
    }

    /** Queue a pause command for one of the configured decks. */
    fun pause(deck: Int) {
        val handle = requireOpen()
        require(deck in 0 until deckCount) { "deck is out of range" }
        check(native.pause(handle, deck)) { "native pause command was rejected" }
    }

    /** Set the shared mixer crossfader and master level from the control thread. */
    fun setMix(crossfader: Float, masterLevel: Float = 1.0f) {
        require(crossfader.isFinite() && crossfader in -1.0f..1.0f) {
            "crossfader must be finite and between -1 and 1"
        }
        require(masterLevel.isFinite() && masterLevel in 0.0f..1.0f) {
            "master level must be finite and between 0 and 1"
        }
        check(native.setMix(requireOpen(), crossfader, masterLevel)) {
            "native mixer control was rejected"
        }
    }

    /** Fill caller-owned stereo direct buffers and return the rendered frame count. */
    fun render(left: ByteBuffer, right: ByteBuffer, frames: Int): Int {
        val handle = requireOpen()
        require(frames in 1..maxFrames) { "frames must be between 1 and maxFrames" }
        validateBuffer(left, frames, "left")
        validateBuffer(right, frames, "right")
        val rendered = native.render(handle, left, right, frames)
        check(rendered == frames) { "native render failed: $rendered" }
        return rendered
    }

    /** Activate or deactivate the bounded off-thread master record tap. */
    fun setRecordActive(active: Boolean) {
        check(native.setRecordActive(requireOpen(), active)) { "native record activation was rejected" }
    }

    /** Drain copied planar master frames into caller-owned direct buffers. */
    fun drainRecord(left: ByteBuffer, right: ByteBuffer, maxFrames: Int): Int {
        val handle = requireOpen()
        require(maxFrames > 0 && maxFrames <= this.maxFrames) {
            "maxFrames must be between 1 and the engine maximum"
        }
        validateBuffer(left, maxFrames, "left")
        validateBuffer(right, maxFrames, "right")
        val drained = native.drainRecord(handle, left, right, maxFrames)
        check(drained in 0..maxFrames) { "native record drain failed: $drained" }
        return drained
    }

    fun recordDroppedFrames(): Long = native.recordDroppedFrames(requireOpen()).also {
        check(it >= 0) { "native record drop query failed" }
    }

    fun resetRecord() {
        check(native.resetRecord(requireOpen())) { "native record reset was rejected" }
    }

    /** Idempotently destroy the native engine after its callback has stopped. */
    override fun close() {
        val handle = nativeHandle
        if (handle != 0L) {
            nativeHandle = 0L
            native.destroy(handle)
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

    internal companion object {
        fun forTesting(
            sampleRateHz: Int = 48_000,
            maxFrames: Int = 512,
            deckCount: Int = 2,
            native: NativeEngineBridge,
        ): ParsoEngine = ParsoEngine(sampleRateHz, maxFrames, deckCount, native)
    }
}
