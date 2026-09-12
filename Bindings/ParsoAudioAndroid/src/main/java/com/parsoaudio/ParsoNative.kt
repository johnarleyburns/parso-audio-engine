package com.parsoaudio

import java.nio.ByteBuffer

/** Minimal JNI-facing headless engine seam; callers provide direct float buffers. */
object ParsoNative {
    init {
        System.loadLibrary("parso")
        System.loadLibrary("parso_android")
    }

    @JvmStatic external fun nativeCreate(sampleRateHz: Int, maxFrames: Int, deckCount: Int): Long
    @JvmStatic external fun nativeDestroy(handle: Long)
    @JvmStatic external fun nativeSetDeckBuffer(
        handle: Long, deck: Int, left: ByteBuffer, right: ByteBuffer?,
        frames: Int, sampleRateHz: Int, channelCount: Int
    ): Boolean
    @JvmStatic external fun nativePlay(handle: Long, deck: Int): Boolean
    @JvmStatic external fun nativePause(handle: Long, deck: Int): Boolean
    @JvmStatic external fun nativeSetMix(
        handle: Long, crossfader: Float, masterLevel: Float
    ): Boolean
    @JvmStatic external fun nativePostCommand(
        handle: Long, type: Int, deck: Int,
        i0: Int, i1: Int, i2: Int, f0: Float, f1: Float
    ): Boolean
    @JvmStatic external fun nativeGetStats(handle: Long): LongArray?
    @JvmStatic external fun nativePollEvents(handle: Long, maxEvents: Int): LongArray?
    @JvmStatic external fun nativeEncodeRecording(
        samples: ByteBuffer, frames: Int, sampleRateHz: Int,
        channelCount: Int, codec: Int, bitrateKbps: Int, quality: Int
    ): ByteArray?
    @JvmStatic external fun nativeRender(
        handle: Long, left: ByteBuffer, right: ByteBuffer, frames: Int
    ): Int
    @JvmStatic external fun nativeAnalysisSummary(
        samples: ByteBuffer, frames: Int, sampleRateHz: Int, channelCount: Int
    ): DoubleArray?
    @JvmStatic external fun nativeKey(
        samples: ByteBuffer, frames: Int, sampleRateHz: Int, channelCount: Int
    ): DoubleArray?
    @JvmStatic external fun nativeStructure(
        samples: ByteBuffer, frames: Int, sampleRateHz: Int, channelCount: Int,
        bpm: Double, maxSections: Int
    ): DoubleArray?
    @JvmStatic external fun nativeEncodeOggVorbis(
        samples: ByteBuffer, frames: Int, sampleRateHz: Int,
        channelCount: Int, bitrateKbps: Int
    ): ByteArray?
    @JvmStatic external fun nativeDecodeOggVorbis(encoded: ByteArray): DecodedVorbis?
    @JvmStatic external fun nativeConvertSampleRate(
        samples: ByteBuffer, frames: Int, sourceSampleRateHz: Int,
        destinationSampleRateHz: Int, channelCount: Int, quality: Int
    ): FloatArray?
    @JvmStatic external fun nativeMeasureLoudness(
        samples: ByteBuffer, frames: Int, sampleRateHz: Int,
        channelCount: Int, targetLufs: Double
    ): DoubleArray?
    @JvmStatic external fun nativeRecordSetActive(handle: Long, active: Boolean): Boolean
    @JvmStatic external fun nativeRecordDrain(
        handle: Long, left: ByteBuffer, right: ByteBuffer, maxFrames: Int
    ): Int
    @JvmStatic external fun nativeRecordDroppedFrames(handle: Long): Long
    @JvmStatic external fun nativeRecordReset(handle: Long): Boolean
    @JvmStatic external fun nativeDeviceCreate(
        engineHandle: Long, sampleRateHz: Int, maxFrames: Int, captureFrames: Int
    ): Long
    @JvmStatic external fun nativeDeviceDestroy(handle: Long)
    @JvmStatic external fun nativeDeviceStart(handle: Long): Boolean
    @JvmStatic external fun nativeDeviceStop(handle: Long): Boolean
    @JvmStatic external fun nativeDeviceState(handle: Long): Int
    @JvmStatic external fun nativeDeviceReadCapture(
        handle: Long, output: java.nio.ByteBuffer, maxFrames: Int
    ): Int
    @JvmStatic external fun nativeDeviceAvailableCapture(handle: Long): Int
    @JvmStatic external fun nativeDeviceDroppedCapture(handle: Long): Long
}
