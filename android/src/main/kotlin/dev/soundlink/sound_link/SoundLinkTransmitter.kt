package dev.soundlink.sound_link

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Process
import kotlin.math.max

class SoundLinkException(val code: String, message: String) : Exception(message)

class SoundLinkTransmitter(
    private val audioManager: AudioManager,
    private val mainHandler: Handler,
    private val emitEvent: (String) -> Unit,
) {
    private val lock = Any()
    private val audioFocus = AudioFocusController(audioManager, mainHandler)
    private var track: AudioTrack? = null
    private var writerThread: Thread? = null
    private var channel: ChannelConfig? = null
    private var volume = 0.6f
    private var gapSamples = 0
    private var sampleRate = 48000

    @Volatile
    private var running = false

    @Volatile
    private var pendingLoop: ShortArray? = null

    val isActive: Boolean
        get() = running

    fun outputSampleRate(): Int {
        val reported = audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull()
        return if (reported != null && reported >= 44100) reported else 48000
    }

    fun start(config: ChannelConfig, payload: ByteArray, volume: Float, gapMilliseconds: Int): Map<String, Any?> {
        synchronized(lock) {
            stopLocked()
            sampleRate = outputSampleRate()
            channel = config
            this.volume = volume
            gapSamples = max(0, gapMilliseconds) * sampleRate / 1000
            val message = encode(config, payload)
            val loop = withGap(message)

            val minimumBuffer = AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
            if (minimumBuffer <= 0) {
                throw SoundLinkException("speaker_unavailable", "AudioTrack does not support $sampleRate Hz mono PCM16")
            }
            val audioTrack = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_UNKNOWN)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(max(minimumBuffer * 2, sampleRate / 5 * 2))
                .build()
            if (audioTrack.state != AudioTrack.STATE_INITIALIZED) {
                audioTrack.release()
                throw SoundLinkException("speaker_unavailable", "AudioTrack failed to initialise")
            }
            AudioRoutes.builtInSpeaker(audioManager)?.let { speaker -> audioTrack.preferredDevice = speaker }
            audioTrack.setVolume(1.0f)
            audioFocus.request(AudioManager.AUDIOFOCUS_GAIN) { change ->
                when (change) {
                    AudioManager.AUDIOFOCUS_LOSS -> emitEvent("focusLost")
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> emitEvent("interrupted")
                    AudioManager.AUDIOFOCUS_GAIN -> emitEvent("focusGained")
                }
            }
            audioTrack.play()

            track = audioTrack
            pendingLoop = null
            running = true
            writerThread = Thread({ writeLoop(audioTrack, loop) }, "sound_link_tx").also { thread -> thread.start() }

            return info(message.size, loop.size, audioTrack)
        }
    }

    fun update(payload: ByteArray): Map<String, Any?> {
        synchronized(lock) {
            val config = channel ?: throw SoundLinkException("not_broadcasting", "No broadcast is running")
            val audioTrack = track ?: throw SoundLinkException("not_broadcasting", "No broadcast is running")
            val message = encode(config, payload)
            val loop = withGap(message)
            pendingLoop = loop
            return info(message.size, loop.size, audioTrack)
        }
    }

    fun stop() {
        synchronized(lock) { stopLocked() }
    }

    private fun stopLocked() {
        running = false
        audioFocus.abandon()
        writerThread?.join(1000)
        writerThread = null
        val audioTrack = track
        track = null
        channel = null
        pendingLoop = null
        if (audioTrack != null) {
            try {
                audioTrack.pause()
                audioTrack.flush()
            } catch (error: IllegalStateException) {
            }
            audioTrack.release()
        }
    }

    private fun encode(config: ChannelConfig, payload: ByteArray): ShortArray =
        SoundLinkNative.encode(config, payload, volume, sampleRate)
            ?: throw SoundLinkException("encode_failed", "Payload could not be encoded for this channel")

    private fun withGap(message: ShortArray): ShortArray = message.copyOf(message.size + gapSamples)

    private fun info(messageSamples: Int, loopSamples: Int, audioTrack: AudioTrack): Map<String, Any?> = mapOf(
        "sampleRate" to sampleRate,
        "messageSamples" to messageSamples,
        "loopSamples" to loopSamples,
        "outputRoute" to AudioRoutes.name(audioTrack.routedDevice ?: audioTrack.preferredDevice),
    )

    private fun writeLoop(audioTrack: AudioTrack, initialLoop: ShortArray) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        var currentLoop = initialLoop
        while (running) {
            pendingLoop?.let { replacement ->
                currentLoop = replacement
                pendingLoop = null
            }
            var offset = 0
            while (running && offset < currentLoop.size) {
                val written = audioTrack.write(currentLoop, offset, currentLoop.size - offset, AudioTrack.WRITE_NON_BLOCKING)
                if (written < 0) {
                    running = false
                    mainHandler.post { emitEvent("stopped") }
                    break
                }
                if (written == 0) {
                    Thread.sleep(5)
                }
                offset += written
            }
        }
    }
}
