package dev.soundlink.sound_link

import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler

class AudioFocusController(
    private val audioManager: AudioManager,
    private val mainHandler: Handler,
) {
    private var focusRequest: AudioFocusRequest? = null
    private var legacyListener: AudioManager.OnAudioFocusChangeListener? = null

    fun request(focusGain: Int, onChange: (Int) -> Unit): Boolean {
        abandon()
        val listener = AudioManager.OnAudioFocusChangeListener { change -> onChange(change) }
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(focusGain)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_UNKNOWN)
                        .build(),
                )
                .setOnAudioFocusChangeListener(listener, mainHandler)
                .build()
            focusRequest = request
            audioManager.requestAudioFocus(request)
        } else {
            legacyListener = listener
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, focusGain)
        }
        return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    fun abandon() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { request -> audioManager.abandonAudioFocusRequest(request) }
        } else {
            @Suppress("DEPRECATION")
            legacyListener?.let { listener -> audioManager.abandonAudioFocus(listener) }
        }
        focusRequest = null
        legacyListener = null
    }
}
