package dev.soundlink.sound_link

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Process
import android.os.SystemClock
import kotlin.math.max

class SoundLinkReceiver(
    private val audioManager: AudioManager,
    private val mainHandler: Handler,
) {
    private val lock = Any()
    private var record: AudioRecord? = null
    private var readerThread: Thread? = null
    private val audioFocus = AudioFocusController(audioManager, mainHandler)
    private var stateEmitter: ((Map<String, Any?>) -> Unit)? = null
    private var activeSampleRate = 0
    private var activeSourceName = ""

    val isActive: Boolean
        get() = running

    @Volatile
    private var running = false

    fun unprocessedSupported(): Boolean =
        audioManager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"

    fun preferredInputSampleRate(): Int =
        if (AudioRecord.getMinBufferSize(48000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT) > 0) 48000 else 44100

    @SuppressLint("MissingPermission")
    fun start(
        channels: List<ChannelConfig>,
        levelIntervalMilliseconds: Int,
        sourcePreference: String,
        emit: (Map<String, Any?>) -> Unit,
        fail: (String, String) -> Unit,
    ) {
        synchronized(lock) {
            stopLocked()
            if (AudioRoutes.isInCall(audioManager)) {
                fail("in_call", "A phone or VoIP call is using the microphone")
                return
            }
            val (sourceName, source) = resolveSource(sourcePreference)
            var created: AudioRecord? = null
            var sampleRate = 0
            for (candidateRate in intArrayOf(48000, 44100)) {
                val minimumBuffer = AudioRecord.getMinBufferSize(candidateRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                if (minimumBuffer <= 0) continue
                val candidate = try {
                    AudioRecord(source, candidateRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, max(minimumBuffer * 4, 16384))
                } catch (error: Exception) {
                    null
                }
                if (candidate != null && candidate.state == AudioRecord.STATE_INITIALIZED) {
                    created = candidate
                    sampleRate = candidateRate
                    break
                }
                candidate?.release()
            }
            val audioRecord = created ?: run {
                fail("microphone_unavailable", "AudioRecord could not be initialised")
                return
            }
            AudioRoutes.builtInMicrophone(audioManager)?.let { microphone -> audioRecord.preferredDevice = microphone }

            val handle = SoundLinkNative.receiverCreate(sampleRate, channels)
            if (handle == 0L) {
                audioRecord.release()
                fail("invalid_arguments", "Receiver could not be created for these channels")
                return
            }

            try {
                audioRecord.startRecording()
            } catch (error: IllegalStateException) {
                SoundLinkNative.receiverDestroy(handle)
                audioRecord.release()
                fail("microphone_in_use", error.message ?: "startRecording failed")
                return
            }
            if (audioRecord.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                SoundLinkNative.receiverDestroy(handle)
                audioRecord.release()
                fail("microphone_in_use", "Microphone is in use by another app or a call")
                return
            }

            record = audioRecord
            running = true
            stateEmitter = emit
            activeSampleRate = sampleRate
            activeSourceName = sourceName
            audioFocus.request(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE) { change ->
                if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                    emitState("focusLost")
                }
            }
            emitState("listening")
            readerThread = Thread(
                { readLoop(audioRecord, handle, sampleRate, channels.size, levelIntervalMilliseconds, emit, fail) },
                "sound_link_rx",
            ).also { thread -> thread.start() }
        }
    }

    fun emitState(status: String) {
        val emit = stateEmitter ?: return
        val audioRecord = record ?: return
        post(emit, mapOf(
            "type" to "state",
            "status" to status,
            "sampleRate" to activeSampleRate,
            "audioSource" to activeSourceName,
            "inputRoute" to AudioRoutes.name(audioRecord.routedDevice ?: audioRecord.preferredDevice),
        ))
    }

    fun stop() {
        synchronized(lock) { stopLocked() }
    }

    private fun stopLocked() {
        running = false
        stateEmitter = null
        audioFocus.abandon()
        val audioRecord = record
        record = null
        try {
            audioRecord?.stop()
        } catch (error: IllegalStateException) {
        }
        readerThread?.join(1000)
        readerThread = null
        audioRecord?.release()
    }

    private fun resolveSource(preference: String): Pair<String, Int> = when (preference) {
        "unprocessed" -> "unprocessed" to MediaRecorder.AudioSource.UNPROCESSED
        "voiceRecognition" -> "voiceRecognition" to MediaRecorder.AudioSource.VOICE_RECOGNITION
        "microphone" -> "microphone" to MediaRecorder.AudioSource.MIC
        else -> if (unprocessedSupported()) {
            "unprocessed" to MediaRecorder.AudioSource.UNPROCESSED
        } else {
            "voiceRecognition" to MediaRecorder.AudioSource.VOICE_RECOGNITION
        }
    }

    private fun readLoop(
        audioRecord: AudioRecord,
        handle: Long,
        sampleRate: Int,
        channelCount: Int,
        levelIntervalMilliseconds: Int,
        emit: (Map<String, Any?>) -> Unit,
        fail: (String, String) -> Unit,
    ) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val shorts = ShortArray(1024)
        val floats = FloatArray(1024)
        var lastLevelsAt = SystemClock.elapsedRealtime()
        var processingNanos = 0L
        var processedSamples = 0L
        var totalSamples = 0L
        var heardSound = false
        var startupChecked = false
        var silencedChecked = false
        try {
            while (running) {
                val read = audioRecord.read(shorts, 0, shorts.size)
                if (read < 0) {
                    if (running) mainHandler.post { fail("microphone_unavailable", "AudioRecord read failed: $read") }
                    break
                }
                for (index in 0 until read) {
                    floats[index] = shorts[index] / 32768.0f
                    if (shorts[index].toInt() != 0) heardSound = true
                }
                totalSamples += read
                if (!silencedChecked && totalSamples >= sampleRate / 2) {
                    silencedChecked = true
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && audioRecord.activeRecordingConfiguration?.isClientSilenced == true) {
                        running = false
                        mainHandler.post { fail("microphone_in_use", "Another app has priority on the microphone; this app receives silence") }
                        break
                    }
                }
                if (!startupChecked && totalSamples >= sampleRate) {
                    startupChecked = true
                    if (!heardSound) {
                        running = false
                        mainHandler.post { fail("microphone_silent", "The microphone delivers only silence (privacy switch off or hardware problem)") }
                        break
                    }
                }
                val processingStartedAt = System.nanoTime()
                val decodedCount = SoundLinkNative.receiverProcess(handle, floats, read)
                processingNanos += System.nanoTime() - processingStartedAt
                processedSamples += read
                if (decodedCount > 0) {
                    while (true) {
                        val decoded = SoundLinkNative.takeDecoded(handle) ?: break
                        post(emit, mapOf(
                            "type" to "decoded",
                            "channelIndex" to decoded.channelIndex,
                            "payload" to decoded.payload,
                            "snrDb" to decoded.snrDb.toDouble(),
                            "signalDbfs" to decoded.signalDbfs.toDouble(),
                            "noiseFloorDbfs" to decoded.noiseFloorDbfs.toDouble(),
                        ))
                    }
                }
                val now = SystemClock.elapsedRealtime()
                if (now - lastLevelsAt >= levelIntervalMilliseconds) {
                    lastLevelsAt = now
                    val channelLevels = (0 until channelCount).mapNotNull { channelIndex ->
                        SoundLinkNative.receiverTakeLevels(handle, channelIndex)?.let { levels ->
                            mapOf(
                                "channelIndex" to channelIndex,
                                "signalDbfs" to levels[0].toDouble(),
                                "noiseFloorDbfs" to levels[1].toDouble(),
                                "snrDb" to levels[2].toDouble(),
                            )
                        }
                    }
                    val audioNanos = processedSamples * 1_000_000_000L / sampleRate
                    val processingLoad = if (audioNanos > 0) processingNanos.toDouble() / audioNanos else 0.0
                    processingNanos = 0L
                    processedSamples = 0L
                    if (channelLevels.isNotEmpty()) {
                        post(emit, mapOf(
                            "type" to "levels",
                            "overallDbfs" to SoundLinkNative.receiverTakeOverallDbfs(handle).toDouble(),
                            "processingLoad" to processingLoad,
                            "channels" to channelLevels,
                        ))
                    }
                }
            }
        } finally {
            SoundLinkNative.receiverDestroy(handle)
        }
    }

    private fun post(emit: (Map<String, Any?>) -> Unit, event: Map<String, Any?>) {
        val stamped = event + ("timestampMilliseconds" to System.currentTimeMillis())
        mainHandler.post { if (running) emit(stamped) }
    }
}
