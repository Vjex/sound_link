package dev.soundlink.sound_link

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class SoundLinkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var audioManager: AudioManager
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var broadcastEventChannel: EventChannel
    private var broadcastEventSink: EventChannel.EventSink? = null
    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = onRoutesChanged()

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = onRoutesChanged()
    }
    private var initialRoutesReported = false
    private lateinit var transmitter: SoundLinkTransmitter
    private lateinit var receiver: SoundLinkReceiver
    private lateinit var worker: ExecutorService
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        transmitter = SoundLinkTransmitter(audioManager, mainHandler) { status -> emitBroadcastEvent(status) }
        receiver = SoundLinkReceiver(audioManager, mainHandler)
        worker = Executors.newSingleThreadExecutor()
        methodChannel = MethodChannel(binding.binaryMessenger, "sound_link/methods")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "sound_link/events")
        eventChannel.setStreamHandler(this)
        broadcastEventChannel = EventChannel(binding.binaryMessenger, "sound_link/broadcast_events")
        broadcastEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                broadcastEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                broadcastEventSink = null
            }
        })
        audioManager.registerAudioDeviceCallback(deviceCallback, mainHandler)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        broadcastEventChannel.setStreamHandler(null)
        audioManager.unregisterAudioDeviceCallback(deviceCallback)
        receiver.stop()
        worker.execute { transmitter.stop() }
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkCapabilities" -> result.success(capabilities())
            "checkReadiness" -> result.success(readiness())
            "setMediaVolume" -> setMediaVolume(call.argument<Double>("fraction")!!, result)
            "startBroadcast" -> runOnWorker(result) {
                val channel = ChannelConfig.fromMap(call.argument<Map<*, *>>("channel")!!)
                val payload = call.argument<ByteArray>("payload")!!
                val volume = call.argument<Double>("volume")!!.toFloat()
                val gap = call.argument<Int>("gapMilliseconds")!!
                transmitter.start(channel, payload, volume, gap)
            }
            "updateBroadcastPayload" -> runOnWorker(result) {
                transmitter.update(call.argument<ByteArray>("payload")!!)
            }
            "stopBroadcast" -> runOnWorker(result) {
                transmitter.stop()
                null
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        if (!hasMicrophonePermission()) {
            events.error("microphone_permission_denied", "RECORD_AUDIO permission is not granted", null)
            return
        }
        val map = arguments as? Map<*, *>
        val channels = (map?.get("channels") as? List<*>)?.map { entry -> ChannelConfig.fromMap(entry as Map<*, *>) }
        if (channels.isNullOrEmpty()) {
            events.error("invalid_arguments", "At least one channel is required", null)
            return
        }
        val interval = (map["levelIntervalMilliseconds"] as? Number)?.toInt() ?: 100
        val source = map["androidAudioSource"] as? String ?: "automatic"
        receiver.start(
            channels,
            interval,
            source,
            emit = { event -> events.success(event) },
            fail = { code, message -> events.error(code, message, null) },
        )
    }

    override fun onCancel(arguments: Any?) {
        receiver.stop()
    }

    private fun runOnWorker(result: MethodChannel.Result, action: () -> Any?) {
        worker.execute {
            try {
                val value = action()
                mainHandler.post { result.success(value) }
            } catch (error: SoundLinkException) {
                mainHandler.post { result.error(error.code, error.message, null) }
            } catch (error: Exception) {
                mainHandler.post { result.error("invalid_arguments", error.message, null) }
            }
        }
    }

    private fun onRoutesChanged() {
        if (!initialRoutesReported) {
            initialRoutesReported = true
            return
        }
        if (receiver.isActive) receiver.emitState("routeChanged")
        if (transmitter.isActive) emitBroadcastEvent("routeChanged")
    }

    private fun emitBroadcastEvent(status: String) {
        val sink = broadcastEventSink ?: return
        val event = mapOf(
            "status" to status,
            "outputRoute" to AudioRoutes.outputKind(audioManager),
            "timestampMilliseconds" to System.currentTimeMillis(),
        )
        if (Looper.myLooper() == Looper.getMainLooper()) sink.success(event) else mainHandler.post { sink.success(event) }
    }

    private fun readiness(): Map<String, Any?> {
        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        return mapOf(
            "microphonePermission" to if (hasMicrophonePermission()) "granted" else "denied",
            "inCall" to AudioRoutes.isInCall(audioManager),
            "otherAudioPlaying" to AudioRoutes.isOtherAudioPlaying(audioManager),
            "inputRoute" to AudioRoutes.inputKind(audioManager),
            "outputRoute" to AudioRoutes.outputKind(audioManager),
            "mediaVolume" to if (maxVolume > 0) audioManager.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / maxVolume else 0.0,
            "canSetMediaVolume" to !audioManager.isVolumeFixed,
        )
    }

    private fun setMediaVolume(fraction: Double, result: MethodChannel.Result) {
        if (audioManager.isVolumeFixed) {
            result.error("unsupported", "This device uses a fixed volume", null)
            return
        }
        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        try {
            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, Math.round(fraction * maxVolume).toInt(), 0)
            result.success(audioManager.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / maxVolume)
        } catch (error: SecurityException) {
            result.error("unsupported", error.message ?: "Volume change not allowed (Do Not Disturb policy)", null)
        }
    }

    private fun hasMicrophonePermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun capabilities(): Map<String, Any?> {
        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        return mapOf(
            "platform" to "android",
            "deviceModel" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "osVersion" to "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            "outputSampleRate" to transmitter.outputSampleRate(),
            "inputSampleRate" to receiver.preferredInputSampleRate(),
            "unprocessedMicrophoneSupported" to receiver.unprocessedSupported(),
            "microphonePermission" to if (hasMicrophonePermission()) "granted" else "denied",
            "mediaVolume" to if (maxVolume > 0) currentVolume.toDouble() / maxVolume else 0.0,
            "outputRoute" to AudioRoutes.connectedOutputs(audioManager),
            "inputRoute" to AudioRoutes.name(AudioRoutes.builtInMicrophone(audioManager)),
        )
    }
}
