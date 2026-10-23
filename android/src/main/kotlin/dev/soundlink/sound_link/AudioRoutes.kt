package dev.soundlink.sound_link

import android.media.AudioDeviceInfo
import android.media.AudioManager

object AudioRoutes {
    fun name(device: AudioDeviceInfo?): String = when (device?.type) {
        null -> "unknown"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "builtInSpeaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "builtInEarpiece"
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "builtInMic"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wiredHeadset"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wiredHeadphones"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetoothA2dp"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetoothSco"
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> "usb"
        else -> "type${device.type}"
    }

    fun builtInSpeaker(audioManager: AudioManager): AudioDeviceInfo? =
        audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .firstOrNull { device -> device.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }

    fun builtInMicrophone(audioManager: AudioManager): AudioDeviceInfo? =
        audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .firstOrNull { device -> device.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }

    fun outputKind(audioManager: AudioManager): String = kind(audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS))

    fun inputKind(audioManager: AudioManager): String = kind(audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS))

    private fun kind(devices: Array<AudioDeviceInfo>): String {
        val types = devices.map { device -> device.type }.toSet()
        val bluetoothTypes = setOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO) + bleTypes()
        val wiredTypes = setOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET,
        )
        return when {
            types.any { type -> type in bluetoothTypes } -> "bluetooth"
            types.any { type -> type in wiredTypes } -> "wired"
            types.contains(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) || types.contains(AudioDeviceInfo.TYPE_BUILTIN_MIC) -> "builtIn"
            types.isEmpty() -> "unknown"
            else -> "other"
        }
    }

    private fun bleTypes(): Set<Int> =
        if (android.os.Build.VERSION.SDK_INT >= 31) {
            setOf(AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER)
        } else {
            emptySet()
        }

    fun isInCall(audioManager: AudioManager): Boolean =
        audioManager.mode == AudioManager.MODE_IN_CALL ||
            audioManager.mode == AudioManager.MODE_IN_COMMUNICATION ||
            audioManager.mode == AudioManager.MODE_RINGTONE

    fun isOtherAudioPlaying(audioManager: AudioManager): Boolean =
        audioManager.isMusicActive ||
            (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O && audioManager.activePlaybackConfigurations.isNotEmpty())

    fun connectedOutputs(audioManager: AudioManager): String =
        audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .map { device -> name(device) }
            .distinct()
            .joinToString(",")
}
