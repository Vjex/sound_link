#ifndef SOUND_LINK_CORE_H
#define SOUND_LINK_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SL_MAX_PAYLOAD_BYTES 256

typedef struct {
    int protocol_id;
    int start_bin;
    int payload_length;
    int checksum;
} sl_channel_config;

typedef struct {
    int channel_index;
    int payload_length;
    uint8_t payload[SL_MAX_PAYLOAD_BYTES];
    float snr_db;
    float signal_dbfs;
    float noise_floor_dbfs;
} sl_decoded;

typedef struct {
    float signal_dbfs;
    float noise_floor_dbfs;
    float snr_db;
} sl_levels;

typedef struct sl_receiver sl_receiver;

float sl_operating_sample_rate(void);
int sl_samples_per_frame(void);
int sl_band_bins(const sl_channel_config * config);
int sl_message_frames(const sl_channel_config * config, int payload_length);
int sl_max_payload_length(const sl_channel_config * config);

int sl_encode(
        const sl_channel_config * config,
        const uint8_t * payload,
        int payload_length,
        float volume,
        float output_sample_rate,
        int16_t * output,
        int output_capacity);

sl_receiver * sl_receiver_create(
        float input_sample_rate,
        const sl_channel_config * channels,
        int channel_count);
void sl_receiver_destroy(sl_receiver * receiver);
int sl_receiver_process(sl_receiver * receiver, const float * samples, int sample_count);
int sl_receiver_take_decoded(sl_receiver * receiver, sl_decoded * output);
int sl_receiver_take_levels(sl_receiver * receiver, int channel_index, sl_levels * output);
float sl_receiver_take_overall_dbfs(sl_receiver * receiver);

#ifdef __cplusplus
}
#endif

#endif
