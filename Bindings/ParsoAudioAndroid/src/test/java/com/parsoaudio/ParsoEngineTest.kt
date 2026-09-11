package com.parsoaudio

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ParsoEngineTest {
    @Test
    fun analysisFacadeRejectsHeapBuffersBeforeLoadingNativeRuntime() {
        assertThrows<IllegalArgumentException> {
            ParsoAnalysis.summary(ByteBuffer.allocate(32), frames = 8, sampleRateHz = 48_000)
        }
    }

    @Test
    fun vorbisFacadeRejectsHeapBuffersBeforeLoadingNativeRuntime() {
        assertThrows<IllegalArgumentException> {
            ParsoVorbis.encode(ByteBuffer.allocate(32), frames = 8, sampleRateHz = 48_000)
        }
    }

    @Test
    fun vorbisDecodeRejectsEmptyBytesBeforeLoadingNativeRuntime() {
        assertThrows<IllegalArgumentException> { ParsoVorbis.decode(ByteArray(0)) }
    }

    @Test
    fun offlineFacadeRejectsHeapBuffersBeforeLoadingNativeRuntime() {
        assertThrows<IllegalArgumentException> {
            ParsoOffline.measureLoudness(ByteBuffer.allocate(32), frames = 8, sampleRateHz = 48_000)
        }
    }

    @Test
    fun lifecycleAndTransportAreSerializedThroughTheBridge() {
        val bridge = FakeBridge()
        val engine = ParsoEngine.forTesting(native = bridge)

        engine.play(0)
        engine.pause(0)
        engine.setMix(-1.0f, 0.75f)
        engine.close()
        engine.close()

        assertEquals(listOf("play:0", "pause:0", "mix:-1.0:0.75"), bridge.operations)
        assertEquals(1, bridge.destroyCount)
    }

    @Test
    fun directBuffersAreRetainedAndValidated() {
        val bridge = FakeBridge()
        val engine = ParsoEngine.forTesting(maxFrames = 8, native = bridge)
        val left = directFloats(8)
        val right = directFloats(8)

        engine.setDeckBuffer(0, left, right, frames = 8)
        assertEquals(1, bridge.deckBufferCalls)
        assertTrue(engine.render(left, right, 8) == 8)
        engine.setRecordActive(true)
        assertEquals(8, engine.drainRecord(left, right, 8))
        assertEquals(0L, engine.recordDroppedFrames())
        engine.resetRecord()

        assertThrows<IllegalArgumentException> {
            engine.setDeckBuffer(0, ByteBuffer.allocate(32), frames = 8)
        }
        val shifted = directFloats(8)
        shifted.position(4)
        assertThrows<IllegalArgumentException> { engine.render(shifted, right, 8) }
        assertThrows<IllegalArgumentException> { engine.render(left, right, 9) }
        assertThrows<IllegalArgumentException> { engine.setMix(1.1f) }
        assertThrows<IllegalArgumentException> { engine.setMix(0.0f, -0.1f) }
    }

    private fun directFloats(frames: Int): ByteBuffer =
        ByteBuffer.allocateDirect(frames * Float.SIZE_BYTES).order(ByteOrder.nativeOrder())

    private inline fun <reified T : Throwable> assertThrows(block: () -> Unit) {
        try {
            block()
        } catch (error: Throwable) {
            assertTrue(error is T)
            return
        }
        assertFalse("expected ${T::class.java.simpleName}", true)
    }

    private class FakeBridge : NativeEngineBridge {
        val operations = mutableListOf<String>()
        var destroyCount = 0
        var deckBufferCalls = 0

        override fun create(sampleRateHz: Int, maxFrames: Int, deckCount: Int): Long = 1L

        override fun destroy(handle: Long) {
            destroyCount += 1
        }

        override fun setDeckBuffer(
            handle: Long,
            deck: Int,
            left: ByteBuffer,
            right: ByteBuffer?,
            frames: Int,
            sampleRateHz: Int,
            channelCount: Int,
        ): Boolean {
            deckBufferCalls += 1
            return true
        }

        override fun play(handle: Long, deck: Int): Boolean {
            operations += "play:$deck"
            return true
        }

        override fun pause(handle: Long, deck: Int): Boolean {
            operations += "pause:$deck"
            return true
        }

        override fun setMix(handle: Long, crossfader: Float, masterLevel: Float): Boolean {
            operations += "mix:$crossfader:$masterLevel"
            return true
        }

        override fun render(handle: Long, left: ByteBuffer, right: ByteBuffer, frames: Int): Int = frames

        override fun setRecordActive(handle: Long, active: Boolean): Boolean = true

        override fun drainRecord(handle: Long, left: ByteBuffer, right: ByteBuffer, maxFrames: Int): Int =
            maxFrames

        override fun recordDroppedFrames(handle: Long): Long = 0L

        override fun resetRecord(handle: Long): Boolean = true
    }
}
