#include <emscripten/emscripten.h>

#include <cstdlib>
#include <cstring>
#include <vector>

#include "sound_link_core.h"

namespace {

void writeInt(uint8_t * buffer, int & offset, int value) {
    std::memcpy(buffer + offset, &value, sizeof(value));
    offset += sizeof(value);
}

void writeFloat(uint8_t * buffer, int & offset, float value) {
    std::memcpy(buffer + offset, &value, sizeof(value));
    offset += sizeof(value);
}

}

extern "C" {

EMSCRIPTEN_KEEPALIVE
int slw_encode(
        int protocol_id,
        int start_bin,
        int payload_length,
        int checksum,
        const uint8_t * payload,
        int length,
        float volume,
        float output_sample_rate,
        int16_t ** output) {
    sl_channel_config config;
    config.protocol_id = protocol_id;
    config.start_bin = start_bin;
    config.payload_length = payload_length;
    config.checksum = checksum;
    const int capacity = sl_encode(&config, payload, length, volume, output_sample_rate, nullptr, 0);
    if (capacity <= 0) {
        return capacity;
    }
    auto * samples = static_cast<int16_t *>(std::malloc(capacity * sizeof(int16_t)));
    const int written = sl_encode(&config, payload, length, volume, output_sample_rate, samples, capacity);
    if (written <= 0) {
        std::free(samples);
        return written;
    }
    *output = samples;
    return written;
}

EMSCRIPTEN_KEEPALIVE
sl_receiver * slw_receiver_create(float input_sample_rate, const int * flattened, int channel_count) {
    std::vector<sl_channel_config> channels(channel_count);
    for (int index = 0; index < channel_count; ++index) {
        channels[index].protocol_id = flattened[index * 4];
        channels[index].start_bin = flattened[index * 4 + 1];
        channels[index].payload_length = flattened[index * 4 + 2];
        channels[index].checksum = flattened[index * 4 + 3];
    }
    return sl_receiver_create(input_sample_rate, channels.data(), channel_count);
}

EMSCRIPTEN_KEEPALIVE
void slw_receiver_destroy(sl_receiver * receiver) {
    sl_receiver_destroy(receiver);
}

EMSCRIPTEN_KEEPALIVE
int slw_receiver_process(sl_receiver * receiver, const float * samples, int count) {
    return sl_receiver_process(receiver, samples, count);
}

EMSCRIPTEN_KEEPALIVE
int slw_receiver_take_decoded(sl_receiver * receiver, uint8_t * packed) {
    sl_decoded decoded;
    if (!sl_receiver_take_decoded(receiver, &decoded)) {
        return 0;
    }
    int offset = 0;
    writeInt(packed, offset, decoded.channel_index);
    writeFloat(packed, offset, decoded.snr_db);
    writeFloat(packed, offset, decoded.signal_dbfs);
    writeFloat(packed, offset, decoded.noise_floor_dbfs);
    writeInt(packed, offset, decoded.payload_length);
    std::memcpy(packed + offset, decoded.payload, decoded.payload_length);
    return offset + decoded.payload_length;
}

EMSCRIPTEN_KEEPALIVE
int slw_receiver_take_levels(sl_receiver * receiver, int channel_index, float * output) {
    sl_levels levels;
    if (!sl_receiver_take_levels(receiver, channel_index, &levels)) {
        return 0;
    }
    output[0] = levels.signal_dbfs;
    output[1] = levels.noise_floor_dbfs;
    output[2] = levels.snr_db;
    return 1;
}

EMSCRIPTEN_KEEPALIVE
float slw_receiver_take_overall_dbfs(sl_receiver * receiver) {
    return sl_receiver_take_overall_dbfs(receiver);
}

EMSCRIPTEN_KEEPALIVE
void * slw_malloc(int bytes) {
    return std::malloc(bytes);
}

EMSCRIPTEN_KEEPALIVE
void slw_free(void * pointer) {
    std::free(pointer);
}

}
