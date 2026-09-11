package com.parsoaudio

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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

    @Test
    fun nativeOfflineAnalysisUsesSharedServices() {
        val sampleRate = 48_000
        val frames = sampleRate * 8
        val samples = ByteBuffer.allocateDirect(frames * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
        val floats = samples.asFloatBuffer()
        for (index in 0 until frames) {
            floats.put(index, if (index in sampleRate * 2 until sampleRate * 4) 0.25f else 0.0f)
        }
        val summary = ParsoAnalysis.summary(samples, frames, sampleRate)
        assertEquals(8.0, summary.durationSeconds, 1.0e-6)
        assertTrue(summary.peak > 0.2)
        val key = ParsoAnalysis.key(samples, frames, sampleRate)
        assertTrue(key.tonicPitchClass in 0..11)
        assertTrue(key.camelotLetter == 'A' || key.camelotLetter == 'B')
        val sections = ParsoAnalysis.structure(samples, frames, sampleRate)
        assertTrue(sections.isNotEmpty())
        assertEquals(0, sections.first().kind)
    }

    @Test
    fun nativeXiphVorbisEncoderReturnsOggBytes() {
        val sampleRate = 48_000
        val frames = sampleRate / 4
        val samples = ByteBuffer.allocateDirect(frames * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
        val floats = samples.asFloatBuffer()
        for (index in 0 until frames) {
            floats.put(index, (0.25 * kotlin.math.sin(
                2.0 * Math.PI * 440.0 * index / sampleRate,
            )).toFloat())
        }
        val encoded = ParsoVorbis.encode(samples, frames, sampleRate)
        assertTrue(encoded.size > 64)
        assertEquals('O'.code.toByte(), encoded[0])
        assertEquals('g'.code.toByte(), encoded[1])
        assertEquals('g'.code.toByte(), encoded[2])
        assertEquals('S'.code.toByte(), encoded[3])
        val decoded = ParsoVorbis.decode(encoded)
        assertEquals(sampleRate, decoded.sampleRateHz)
        assertEquals(1, decoded.channelCount)
        assertTrue(decoded.frames > 0)
        assertEquals(decoded.frames, decoded.samples.size)
    }
}
