package dev.soundlink.sound_link

import java.nio.ByteBuffer
import java.nio.ByteOrder

data class ChannelConfig(
    val protocolId: Int,
    val startBin: Int,
    val payloadLength: Int,
    val checksum: Boolean,
) {
    companion object {
        fun fromMap(map: Map<*, *>): ChannelConfig = ChannelConfig(
            protocolId = (map["protocolId"] as Number).toInt(),
            startBin = (map["startBin"] as Number).toInt(),
            payloadLength = (map["payloadLength"] as Number).toInt(),
            checksum = map["checksum"] as Boolean,
        )
    }
}

data class DecodedPayload(
    val channelIndex: Int,
    val snrDb: Float,
    val signalDbfs: Float,
    val noiseFloorDbfs: Float,
    val payload: ByteArray,
)

object SoundLinkNative {
    init {
        System.loadLibrary("sound_link")
    }

    external fun encode(
        protocolId: Int,
        startBin: Int,
        payloadLength: Int,
        checksum: Boolean,
        payload: ByteArray,
        volume: Float,
        outputSampleRate: Int,
    ): ShortArray?

    external fun receiverCreate(inputSampleRate: Int, flattenedChannels: IntArray): Long

    external fun receiverDestroy(handle: Long)

    external fun receiverProcess(handle: Long, samples: FloatArray, count: Int): Int

    external fun receiverTakeDecoded(handle: Long): ByteArray?

    external fun receiverTakeLevels(handle: Long, channelIndex: Int): FloatArray?

    external fun receiverTakeOverallDbfs(handle: Long): Float

    fun encode(config: ChannelConfig, payload: ByteArray, volume: Float, outputSampleRate: Int): ShortArray? =
        encode(config.protocolId, config.startBin, config.payloadLength, config.checksum, payload, volume, outputSampleRate)

    fun receiverCreate(inputSampleRate: Int, channels: List<ChannelConfig>): Long {
        val flattened = IntArray(channels.size * 4)
        channels.forEachIndexed { index, channel ->
            flattened[index * 4] = channel.protocolId
            flattened[index * 4 + 1] = channel.startBin
            flattened[index * 4 + 2] = channel.payloadLength
            flattened[index * 4 + 3] = if (channel.checksum) 1 else 0
        }
        return receiverCreate(inputSampleRate, flattened)
    }

    fun takeDecoded(handle: Long): DecodedPayload? {
        val packed = receiverTakeDecoded(handle) ?: return null
        val buffer = ByteBuffer.wrap(packed).order(ByteOrder.LITTLE_ENDIAN)
        val channelIndex = buffer.int
        val snrDb = buffer.float
        val signalDbfs = buffer.float
        val noiseFloorDbfs = buffer.float
        val length = buffer.int
        val payload = ByteArray(length)
        buffer.get(payload)
        return DecodedPayload(channelIndex, snrDb, signalDbfs, noiseFloorDbfs, payload)
    }
}
