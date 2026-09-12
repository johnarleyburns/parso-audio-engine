package com.parsoaudio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper

/**
 * Control-side Android focus and route owner for [ParsoAudioDevice].
 *
 * Callbacks never run on the native audio callback. Focus loss stops the
 * stream, focus gain resumes it, and a route change reopens the stream so the
 * Oboe builder can renegotiate the device's native path.
 */
class ParsoAudioRoute(
    context: Context,
    private val device: ParsoAudioDevice,
) : AutoCloseable, AudioManager.OnAudioFocusChangeListener {
    private val audioManager = context.applicationContext
        .getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val callbackHandler = Handler(Looper.getMainLooper())
    private val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_GAME)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build(),
        )
        .setOnAudioFocusChangeListener(this, callbackHandler)
        .setWillPauseWhenDucked(false)
        .build()
    private var active = false
    private var closed = false
    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = restart()

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = restart()
    }

    /** Request focus, register route monitoring, and start the native stream. */
    fun start(): Boolean {
        check(!closed) { "audio route is closed" }
        if (active) return true
        if (audioManager.requestAudioFocus(focusRequest) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            return false
        }
        audioManager.registerAudioDeviceCallback(deviceCallback, callbackHandler)
        active = device.start()
        if (!active) {
            audioManager.unregisterAudioDeviceCallback(deviceCallback)
            audioManager.abandonAudioFocusRequest(focusRequest)
        }
        return active
    }

    fun stop() {
        if (!active) return
        active = false
        device.stop()
        audioManager.unregisterAudioDeviceCallback(deviceCallback)
        audioManager.abandonAudioFocusRequest(focusRequest)
    }

    override fun onAudioFocusChange(focusChange: Int) {
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> if (!closed && !active) start()
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> stop()
        }
    }

    override fun close() {
        if (!closed) {
            stop()
            closed = true
        }
    }

    private fun restart() {
        if (!active || closed) return
        device.stop()
        active = device.start()
    }
}
