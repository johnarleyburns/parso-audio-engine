package com.parsoaudio

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** State reported by the native Oboe device adapter. */
enum class AudioDeviceState(val value: Int) {
    STOPPED(0),
    RUNNING(1),
    RUNNING_WITHOUT_INPUT(2),
    ERROR(3),
}

/**
 * Oboe-backed low-latency device bridge.
 *
 * The native callback owns all render scratch storage and calls the same
 * engine render entry point used by the headless tests. Capture is copied into
 * a bounded lock-free mono ring and is drained by the control thread through
 * [readCapture]. Stop this device before closing its [engine].
 */
class ParsoAudioDevice(
    private val engine: ParsoEngine,
    private val sampleRateHz: Int = 48_000,
    private val maxFrames: Int = 512,
    captureFrames: Int = sampleRateHz * 2,
) : AutoCloseable {
    private var nativeHandle = ParsoNative.nativeDeviceCreate(
        engine.nativeHandleForDevice(), sampleRateHz, maxFrames, captureFrames,
    )

    init {
        require(nativeHandle != 0L) { "native audio device creation failed" }
        require(sampleRateHz > 0) { "sample rate must be positive" }
        require(maxFrames > 0) { "maxFrames must be positive" }
        require(captureFrames >= maxFrames) { "captureFrames must cover maxFrames" }
    }

    fun start(): Boolean = ParsoNative.nativeDeviceStart(requireOpen())

    fun stop(): Boolean = ParsoNative.nativeDeviceStop(requireOpen())

    fun state(): AudioDeviceState = AudioDeviceState.entries.firstOrNull {
        it.value == ParsoNative.nativeDeviceState(requireOpen())
    } ?: AudioDeviceState.ERROR

    fun availableCaptureFrames(): Int = ParsoNative.nativeDeviceAvailableCapture(requireOpen())

    fun droppedCaptureFrames(): Long = ParsoNative.nativeDeviceDroppedCapture(requireOpen())

    /** Drain mono float capture into a direct, native-order buffer. */
    fun readCapture(output: ByteBuffer, maxFrames: Int = output.capacity() / Float.SIZE_BYTES): Int {
        require(output.isDirect) { "capture output must be a direct buffer" }
        require(output.order() == ByteOrder.nativeOrder()) {
            "capture output must use native byte order"
        }
        require(maxFrames > 0 && output.capacity() >= maxFrames * Float.SIZE_BYTES) {
            "capture output is too small"
        }
        return ParsoNative.nativeDeviceReadCapture(requireOpen(), output, maxFrames)
    }

    override fun close() {
        val handle = nativeHandle
        if (handle != 0L) {
            ParsoNative.nativeDeviceStop(handle)
            nativeHandle = 0L
            ParsoNative.nativeDeviceDestroy(handle)
        }
    }

    private fun requireOpen(): Long {
        check(nativeHandle != 0L) { "audio device is closed" }
        return nativeHandle
    }
}
