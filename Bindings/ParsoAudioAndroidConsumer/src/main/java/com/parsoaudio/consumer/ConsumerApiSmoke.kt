package com.parsoaudio.consumer

import com.parsoaudio.AnalysisSummary
import com.parsoaudio.DecodedVorbis
import com.parsoaudio.KeyEstimate
import com.parsoaudio.LoudnessMeasurement
import com.parsoaudio.ParsoAnalysis
import com.parsoaudio.ParsoEngine
import com.parsoaudio.ParsoOffline
import com.parsoaudio.ParsoVorbis
import com.parsoaudio.ResampledPcm
import com.parsoaudio.StructureSection

/** Compile-time consumer surface check for the published AAR coordinate. */
object ConsumerApiSmoke {
    fun summarize(
        summary: AnalysisSummary,
        key: KeyEstimate,
        sections: List<StructureSection>,
        decoded: DecodedVorbis,
        converted: ResampledPcm,
        loudness: LoudnessMeasurement,
    ): String = listOf(
        summary.durationSeconds, key.camelotLetter, sections.size, decoded.frames,
        converted.sampleRateHz, loudness.integratedLufs,
        ParsoAnalysis::class, ParsoVorbis::class, ParsoOffline::class, ParsoEngine::class,
    ).joinToString()
}
