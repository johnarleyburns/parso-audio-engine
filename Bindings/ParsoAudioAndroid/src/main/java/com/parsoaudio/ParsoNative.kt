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
    @JvmStatic external fun nativePlay(handle: Long, deck: Int): Boolean
    @JvmStatic external fun nativeRender(
        handle: Long, left: ByteBuffer, right: ByteBuffer, frames: Int
    ): Int
}
