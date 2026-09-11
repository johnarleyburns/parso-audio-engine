package com.parsoaudio.consumer

import com.parsoaudio.ParsoAnalysis
import com.parsoaudio.ParsoEngine
import com.parsoaudio.ParsoOffline
import com.parsoaudio.ParsoRecorder
import com.parsoaudio.ParsoVorbis
import com.parsoaudio.EngineCommand
import com.parsoaudio.RecordingFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.sin

/**
 * Small application-side smoke path for the published AAR. All offline calls
 * are made before the engine is opened; an app should run this work away from
 * its audio callback and replace the sample PCM with its own decoded source.
 */
object ConsumerScenario {
    private const val SAMPLE_RATE_HZ = 48_000
    private const val ANALYSIS_FRAMES = 4_096
    private const val RENDER_FRAMES = 256

    fun run(): String {
        val mono = directFloats(ANALYSIS_FRAMES)
        val summary = ParsoAnalysis.summary(mono, ANALYSIS_FRAMES, SAMPLE_RATE_HZ)
        val key = ParsoAnalysis.key(mono, ANALYSIS_FRAMES, SAMPLE_RATE_HZ)
        val structure = ParsoAnalysis.structure(mono, ANALYSIS_FRAMES, SAMPLE_RATE_HZ)
        val resampled = ParsoOffline.convertSampleRate(
            mono, ANALYSIS_FRAMES, SAMPLE_RATE_HZ, SAMPLE_RATE_HZ / 2,
        )
        val loudness = ParsoOffline.measureLoudness(mono, ANALYSIS_FRAMES, SAMPLE_RATE_HZ)
        val encoded = ParsoVorbis.encode(mono, ANALYSIS_FRAMES, SAMPLE_RATE_HZ)
        val decoded = ParsoVorbis.decode(encoded)

        val renderLeft = directFloats(RENDER_FRAMES)
        val renderRight = directFloats(RENDER_FRAMES)
        var rendered = 0
        var recorded = 0
        var dropped = 0L
        var events = 0
        ParsoEngine(maxFrames = RENDER_FRAMES).use { engine ->
            engine.setDeckBuffer(0, monoPlane(ANALYSIS_FRAMES), monoPlane(ANALYSIS_FRAMES), ANALYSIS_FRAMES)
            engine.setMix(-1.0f, 0.9f)
            engine.postCommand(EngineCommand.SET_KEYLOCK, f0 = 1.0f)
            engine.setRecordActive(true)
            engine.play(0)
            rendered = engine.render(renderLeft, renderRight, RENDER_FRAMES)
            val recordLeft = directFloats(RENDER_FRAMES)
            val recordRight = directFloats(RENDER_FRAMES)
            recorded = engine.drainRecord(recordLeft, recordRight, RENDER_FRAMES)
            if (recorded > 0) {
                val recorder = ParsoRecorder(SAMPLE_RATE_HZ, RecordingFormat.WAV)
                recorder.append(recordLeft, recordRight, recorded)
                val recording = recorder.encode()
                check(recording.size > 44)
                check(recording[0] == 'R'.code.toByte())
                check(recording[1] == 'I'.code.toByte())
                check(recording[2] == 'F'.code.toByte())
                check(recording[3] == 'F'.code.toByte())
            }
            dropped = engine.recordDroppedFrames()
            check(engine.stats().deckCount == 2)
            events = engine.pollEvents().size
        }

        check(rendered == RENDER_FRAMES)
        check(decoded.frames > 0 && resampled.frames > 0)
        return "frames=$rendered recorded=$recorded events=$events dropped=$dropped " +
            "bpm=${summary.bpm} key=${key.camelotLetter}${key.camelotNumber} " +
            "sections=${structure.size} lufs=${loudness.integratedLufs} " +
            "encoded=${encoded.size} decoded=${decoded.frames}"
    }

    private fun directFloats(frames: Int): ByteBuffer {
        val buffer = ByteBuffer.allocateDirect(frames * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
        val floats = buffer.asFloatBuffer()
        repeat(frames) { index ->
            floats.put(index, (0.2 * sin(2.0 * PI * 440.0 * index / SAMPLE_RATE_HZ)).toFloat())
        }
        return buffer
    }

    private fun monoPlane(frames: Int): ByteBuffer = directFloats(frames)
}
