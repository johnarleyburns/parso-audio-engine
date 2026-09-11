package com.parsoaudio.consumer

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Runtime proof that an independent app can call through the published AAR. */
@RunWith(AndroidJUnit4::class)
class ConsumerScenarioInstrumentationTest {
    @Test
    fun publishedAarRunsEndToEndScenario() {
        val result = ConsumerScenario.run()
        assertTrue(result.contains("encoded="))
        assertTrue(result.contains("decoded="))
        assertTrue(result.contains("recorded="))
    }
}
