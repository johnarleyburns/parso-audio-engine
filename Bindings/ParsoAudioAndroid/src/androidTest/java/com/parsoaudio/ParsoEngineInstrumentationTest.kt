package com.parsoaudio

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ParsoEngineInstrumentationTest {
    @Test
    fun nativeLifecycleAndBoundedRender() {
        val frames = 64
        val left = ByteBuffer.allocateDirect(frames * Float.SIZE_BYTES).order(ByteOrder.nativeOrder())
        val right = ByteBuffer.allocateDirect(frames * Float.SIZE_BYTES).order(ByteOrder.nativeOrder())
        val engine = ParsoEngine(maxFrames = frames)
        try {
            engine.play(0)
            engine.pause(0)
            assertEquals(frames, engine.render(left, right, frames))
        } finally {
            engine.close()
        }
    }
}
