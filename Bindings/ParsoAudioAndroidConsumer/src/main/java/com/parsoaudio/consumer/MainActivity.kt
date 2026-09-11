package com.parsoaudio.consumer

import android.app.Activity
import android.os.Bundle
import android.widget.TextView

/** Minimal launcher for manually exercising the published AAR on an emulator. */
class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val result = try {
            ConsumerScenario.run()
        } catch (error: Throwable) {
            "FAILED: ${error::class.simpleName}: ${error.message}"
        }
        setContentView(TextView(this).apply { text = result })
    }
}
