#include <jni.h>

#include <cstring>
#include <vector>

#include "sound_link_core.h"

namespace {

sl_receiver * receiverFrom(jlong handle) {
    return reinterpret_cast<sl_receiver *>(handle);
}

void writeInt(std::vector<jbyte> & buffer, int value) {
    for (int shift = 0; shift < 32; shift += 8) {
        buffer.push_back((jbyte) ((value >> shift) & 0xFF));
    }
}

void writeFloat(std::vector<jbyte> & buffer, float value) {
    int bits;
    std::memcpy(&bits, &value, sizeof(bits));
    writeInt(buffer, bits);
}

}

extern "C" {

JNIEXPORT jshortArray JNICALL
Java_dev_soundlink_sound_1link_SoundLinkNative_encode(
        JNIEnv * env,
        jobject,
        jint protocolId,
        jint startBin,
        jint payloadLength,
        jboolean checksum,
        jbyteArray payload,
        jfloat volume,
        jint outputSampleRate) {
    sl_channel_config config;
    config.protocol_id = protocolId;
    config.start_bin = startBin;
    config.payload_length = payloadLength;
    config.checksum = checksum ? 1 : 0;

    const jsize length = env->GetArrayLength(payload);
    std::vector<uint8_t> bytes(length);
    env->GetByteArrayRegion(payload, 0, length, reinterpret_cast<jbyte *>(bytes.data()));

    const int capacity = sl_encode(&config, bytes.data(), length, volume, (float) outputSampleRate, nullptr, 0);
    if (capacity <= 0) {
        return nullptr;
    }
    std::vector<int16_t> samples(capacity);
    const int written = sl_encode(&config, bytes.data(), length, volume, (float) outputSampleRate, samples.data(), capacity);
    if (written <= 0) {
        return nullptr;
    }
    jshortArray result = env->NewShortArray(written);
    env->SetShortArrayRegion(result, 0, written, reinterpret_cast<const jshort *>(samples.data()));
    return result;
}

JNIEXPORT jlong JNICALL
Java_dev_soundlink_sound_1link_SoundLinkNative_receiverCreate(
        JNIEnv * env,
        jobject,
        jint inputSampleRate,
        jintArray flattenedChannels) {
    const jsize values = env->GetArrayLength(flattenedChannels);
    if (values == 0 || values % 4 != 0) {
        return 0;
    }
    std::vector<jint> flattened(values);
    env->GetIntArrayRegion(flattenedChannels, 0, values, flattened.data());
    std::vector<sl_channel_config> channels(values / 4);
    for (size_t index = 0; index < channels.size(); ++index) {
        channels[index].protocol_id = flattened[index * 4];
        channels[index].start_bin = flattened[index * 4 + 1];
        channels[index].payload_length = flattened[index * 4 + 2];
        channels[index].checksum = flattened[index * 4 + 3];
    }
    return reinterpret_cast<jlong>(sl_receiver_create((float) inputSampleRate, channels.data(), (int) channels.size()));
}

JNIEXPORT void JNICALL
Java_dev_soundlink_sound_1link_SoundLinkNative_receiverDestroy(JNIEnv *, jobject, jlong handle) {
    sl_receiver_destroy(receiverFrom(handle));
}

JNIEXPORT jint JNICALL
Java_dev_soundlink_sound_1link_SoundLinkNative_receiverProcess(
        JNIEnv * env,
        jobject,
        jlong handle,
        jfloatArray samples,
        jint count) {
    jfloat * elements = env->GetFloatArrayElements(samples, nullptr);
    const int decoded = sl_receiver_process(receiverFrom(handle), elements, count);
    env->ReleaseFloatArrayElements(samples, elements, JNI_ABORT);
    return decoded;
}

JNIEXPORT jbyteArray JNICALL
Java_dev_soundlink_sound_1link_SoundLinkNative_receiverTakeDecoded(JNIEnv * env, jobject, jlong handle) {
    sl_decoded decoded;
    if (!sl_receiver_take_decoded(receiverFrom(handle), &decoded)) {
        return nullptr;
    }
    std::vector<jbyte> buffer;
    writeInt(buffer, decoded.channel_index);
    writeFloat(buffer, decoded.snr_db);
    writeFloat(buffer, decoded.signal_dbfs);
    writeFloat(buffer, decoded.noise_floor_dbfs);
    writeInt(buffer, decoded.payload_length);
    for (int index = 0; index < decoded.payload_length; ++index) {
        buffer.push_back((jbyte) decoded.payload[index]);
    }
    jbyteArray result = env->NewByteArray((jsize) buffer.size());
    env->SetByteArrayRegion(result, 0, (jsize) buffer.size(), buffer.data());
    return result;
}

JNIEXPORT jfloatArray JNICALL
Java_dev_soundlink_sound_1link_SoundLinkNative_receiverTakeLevels(JNIEnv * env, jobject, jlong handle, jint channelIndex) {
    sl_levels levels;
    if (!sl_receiver_take_levels(receiverFrom(handle), channelIndex, &levels)) {
        return nullptr;
    }
    const jfloat values[3] = {levels.signal_dbfs, levels.noise_floor_dbfs, levels.snr_db};
    jfloatArray result = env->NewFloatArray(3);
    env->SetFloatArrayRegion(result, 0, 3, values);
    return result;
}

JNIEXPORT jfloat JNICALL
Java_dev_soundlink_sound_1link_SoundLinkNative_receiverTakeOverallDbfs(JNIEnv *, jobject, jlong handle) {
    return sl_receiver_take_overall_dbfs(receiverFrom(handle));
}

}
