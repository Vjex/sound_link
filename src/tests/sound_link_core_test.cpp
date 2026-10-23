#include "sound_link_core.h"

#ifndef PROGMEM
#define PROGMEM
#endif
#include "../ggwave/src/reed-solomon/rs.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <random>
#include <string>
#include <vector>

namespace {

constexpr int kMonoToneFastest = 11;
constexpr int kDualToneFastest = 8;
constexpr int kDirectStartBin = 395;
constexpr int kRelayStartBin = 418;
constexpr float kPi = 3.14159265358979323846f;

int failures = 0;

void expect(bool condition, const std::string & message) {
    if (!condition) {
        ++failures;
        std::printf("  FAIL: %s\n", message.c_str());
    }
}

sl_channel_config channelConfig(int protocolId, int startBin, int payloadLength) {
    sl_channel_config config;
    config.protocol_id = protocolId;
    config.start_bin = startBin;
    config.payload_length = payloadLength;
    config.checksum = 1;
    return config;
}

std::vector<uint8_t> payloadOfLength(int length, uint32_t seed) {
    std::mt19937 generator(seed);
    std::vector<uint8_t> payload(length);
    for (auto & byte : payload) {
        byte = (uint8_t) (generator() & 0xFF);
    }
    return payload;
}

std::vector<float> encodeToFloat(const sl_channel_config & config, const std::vector<uint8_t> & payload, float volume, float outputRate) {
    const int capacity = sl_encode(&config, payload.data(), (int) payload.size(), volume, outputRate, nullptr, 0);
    if (capacity <= 0) {
        return {};
    }
    std::vector<int16_t> pcm(capacity);
    const int written = sl_encode(&config, payload.data(), (int) payload.size(), volume, outputRate, pcm.data(), capacity);
    if (written <= 0) {
        return {};
    }
    std::vector<float> samples(written);
    for (int index = 0; index < written; ++index) {
        samples[index] = pcm[index] / 32768.0f;
    }
    return samples;
}

std::vector<float> silence(float seconds, float rate) {
    return std::vector<float>((size_t) (seconds * rate), 0.0f);
}

void append(std::vector<float> & target, const std::vector<float> & source) {
    target.insert(target.end(), source.begin(), source.end());
}

struct Decode {
    int channelIndex;
    std::vector<uint8_t> payload;
    float snrDb;
};

std::vector<Decode> runReceiver(
        const std::vector<sl_channel_config> & channels,
        const std::vector<float> & audio,
        float inputRate,
        uint32_t chunkSeed) {
    std::vector<Decode> decodes;
    sl_receiver * receiver = sl_receiver_create(inputRate, channels.data(), (int) channels.size());
    if (receiver == nullptr) {
        return decodes;
    }
    std::mt19937 generator(chunkSeed);
    std::uniform_int_distribution<int> chunkSize(64, 4096);
    size_t offset = 0;
    while (offset < audio.size()) {
        const int count = (int) std::min<size_t>(chunkSize(generator), audio.size() - offset);
        sl_receiver_process(receiver, audio.data() + offset, count);
        offset += count;
        sl_decoded decoded;
        while (sl_receiver_take_decoded(receiver, &decoded)) {
            decodes.push_back({decoded.channel_index,
                std::vector<uint8_t>(decoded.payload, decoded.payload + decoded.payload_length),
                decoded.snr_db});
        }
    }
    sl_receiver_destroy(receiver);
    return decodes;
}

void addWhiteNoise(std::vector<float> & audio, float rmsAmplitude, uint32_t seed) {
    std::mt19937 generator(seed);
    std::normal_distribution<float> distribution(0.0f, rmsAmplitude);
    for (auto & sample : audio) {
        sample += distribution(generator);
    }
}

void addLowFrequencyBabble(std::vector<float> & audio, float rmsAmplitude, float rate, uint32_t seed) {
    std::mt19937 generator(seed);
    std::normal_distribution<float> distribution(0.0f, 1.0f);
    const float alpha = 1.0f - std::exp(-2.0f * kPi * 3000.0f / rate);
    float stageOne = 0.0f;
    float stageTwo = 0.0f;
    float stageThree = 0.0f;
    float stageFour = 0.0f;
    std::vector<float> babble(audio.size());
    double energy = 0.0;
    for (size_t index = 0; index < audio.size(); ++index) {
        stageOne += alpha * (distribution(generator) - stageOne);
        stageTwo += alpha * (stageOne - stageTwo);
        stageThree += alpha * (stageTwo - stageThree);
        stageFour += alpha * (stageThree - stageFour);
        const float syllableEnvelope = 0.6f + 0.4f * std::sin(2.0f * kPi * 4.0f * index / rate);
        babble[index] = stageFour * syllableEnvelope;
        energy += (double) babble[index] * babble[index];
    }
    const float scale = rmsAmplitude / (float) std::sqrt(energy / std::max<size_t>(1, babble.size()));
    for (size_t index = 0; index < audio.size(); ++index) {
        audio[index] += babble[index] * scale;
    }
}

void addFanHum(std::vector<float> & audio, float amplitude, float rate) {
    for (size_t index = 0; index < audio.size(); ++index) {
        const float time = index / rate;
        audio[index] += amplitude * (std::sin(2.0f * kPi * 100.0f * time) +
            0.5f * std::sin(2.0f * kPi * 200.0f * time) +
            0.25f * std::sin(2.0f * kPi * 300.0f * time));
    }
}

void addClicks(std::vector<float> & audio, float rate, uint32_t seed) {
    std::mt19937 generator(seed);
    std::uniform_real_distribution<float> uniform(-1.0f, 1.0f);
    const size_t interval = (size_t) (0.7f * rate);
    const size_t length = (size_t) (0.003f * rate);
    for (size_t start = interval / 3; start + length < audio.size(); start += interval) {
        for (size_t index = 0; index < length; ++index) {
            audio[start + index] += 0.8f * uniform(generator);
        }
    }
}

void scale(std::vector<float> & audio, float factor) {
    for (auto & sample : audio) {
        sample *= factor;
    }
}

void clip(std::vector<float> & audio) {
    for (auto & sample : audio) {
        sample = std::max(-1.0f, std::min(1.0f, sample));
    }
}

float decibelsToAmplitude(float decibels) {
    return std::pow(10.0f, decibels / 20.0f);
}

int countMatching(const std::vector<Decode> & decodes, int channelIndex, const std::vector<uint8_t> & payload) {
    int matches = 0;
    for (const auto & decode : decodes) {
        if (decode.channelIndex == channelIndex && decode.payload == payload) {
            ++matches;
        }
    }
    return matches;
}

int countWrong(const std::vector<Decode> & decodes, const std::vector<std::vector<uint8_t>> & validPayloads) {
    int wrong = 0;
    for (const auto & decode : decodes) {
        bool isValid = false;
        for (const auto & payload : validPayloads) {
            if (decode.payload == payload) {
                isValid = true;
            }
        }
        if (!isValid) {
            ++wrong;
        }
    }
    return wrong;
}

void testBandGeometry() {
    std::printf("band geometry\n");
    const float hzPerBin = sl_operating_sample_rate() / sl_samples_per_frame();
    const auto monoTone = channelConfig(kMonoToneFastest, kDirectStartBin, 7);
    const auto dualTone = channelConfig(kDualToneFastest, kDirectStartBin, 0);
    const int monoBins = sl_band_bins(&monoTone);
    const int dualBins = sl_band_bins(&dualTone);
    std::printf("  mono-tone: %d bins, %.1f-%.1f Hz\n", monoBins, kDirectStartBin * hzPerBin, (kDirectStartBin + monoBins - 1) * hzPerBin);
    std::printf("  dual-tone: %d bins, %.1f-%.1f Hz\n", dualBins, kDirectStartBin * hzPerBin, (kDirectStartBin + dualBins - 1) * hzPerBin);
    std::printf("  relay mono-tone: %.1f-%.1f Hz\n", kRelayStartBin * hzPerBin, (kRelayStartBin + monoBins - 1) * hzPerBin);
    expect(monoBins == 16, "mono-tone band is 16 bins");
    expect(dualBins == 32, "dual-tone band is 32 bins");
    expect((kDirectStartBin + monoBins - 1) * hzPerBin < 19500.0f, "mono-tone direct band ends below 19.5 kHz");
    expect(kRelayStartBin * hzPerBin > 19500.0f, "relay band starts above 19.5 kHz");

    for (int length : {7, 9, 31, 33, 40}) {
        const auto config = channelConfig(kMonoToneFastest, kDirectStartBin, length);
        const int frames = sl_message_frames(&config, length);
        std::printf("  mono-tone fastest, %2d-byte payload: %d frames = %.2f s\n", length, frames, frames * sl_samples_per_frame() / sl_operating_sample_rate());
    }
    for (int length : {7, 31, 40}) {
        const auto config = channelConfig(kDualToneFastest, kDirectStartBin, 0);
        const int frames = sl_message_frames(&config, length);
        std::printf("  dual-tone fastest, %2d-byte payload: %d frames = %.2f s\n", length, frames, frames * sl_samples_per_frame() / sl_operating_sample_rate());
    }
}

void testInvalidConfigs() {
    std::printf("invalid configs\n");
    const auto monoVariable = channelConfig(kMonoToneFastest, kDirectStartBin, 0);
    const uint8_t payload[4] = {1, 2, 3, 4};
    int16_t output[16];
    expect(sl_encode(&monoVariable, payload, 4, 0.5f, 48000.0f, output, 16) < 0, "mono-tone without fixed length is rejected");
    const auto aboveNyquist = channelConfig(kMonoToneFastest, 500, 4);
    expect(sl_encode(&aboveNyquist, payload, 4, 0.5f, 48000.0f, output, 16) < 0, "band above Nyquist is rejected");
    const auto wrongLength = channelConfig(kMonoToneFastest, kDirectStartBin, 5);
    expect(sl_encode(&wrongLength, payload, 4, 0.5f, 48000.0f, output, 16) < 0, "payload length mismatch is rejected");
    const auto tooLong = channelConfig(kMonoToneFastest, kDirectStartBin, 61);
    expect(sl_receiver_create(48000.0f, &tooLong, 1) == nullptr, "fixed payload over 60 bytes with checksum is rejected");
}

void testLoopback(int protocolId, int length, bool fixedLength, float rate) {
    const auto config = channelConfig(protocolId, kDirectStartBin, fixedLength ? length : 0);
    const auto payload = payloadOfLength(length, 1000 + length);
    std::vector<float> audio = silence(0.37f, rate);
    append(audio, encodeToFloat(config, payload, 0.6f, rate));
    append(audio, silence(0.5f, rate));
    const auto decodes = runReceiver({config}, audio, rate, 7);
    const int matches = countMatching(decodes, 0, payload);
    std::printf("  protocol %d, %d bytes, %.0f Hz: %d decode(s), snr %.1f dB\n", protocolId, length, rate, matches, decodes.empty() ? 0.0f : decodes.front().snrDb);
    expect(matches == 1 && decodes.size() == 1, "clean loopback decodes exactly once");
}

void testCleanLoopback() {
    std::printf("clean loopback\n");
    for (float rate : {48000.0f, 44100.0f}) {
        for (int length : {9, 33, 40}) {
            testLoopback(kMonoToneFastest, length, true, rate);
        }
        testLoopback(kDualToneFastest, 31, false, rate);
    }
}

struct Scenario {
    std::string name;
    float attenuationDb;
    std::function<void(std::vector<float> &, float, uint32_t)> impair;
    int minimumSuccessPercent;
};

void testRobustness() {
    std::printf("robustness (mono-tone fastest, 33-byte payload, 10 trials each)\n");
    const int length = 33;
    const auto config = channelConfig(kMonoToneFastest, kDirectStartBin, length);
    const float micSelfNoise = decibelsToAmplitude(-75.0f);
    const std::vector<Scenario> scenarios = {
        {"classroom babble -20 dBFS + fan hum", 0.0f, [&](std::vector<float> & audio, float rate, uint32_t seed) {
            addLowFrequencyBabble(audio, decibelsToAmplitude(-20.0f), rate, seed);
            addFanHum(audio, decibelsToAmplitude(-30.0f), rate);
            addWhiteNoise(audio, micSelfNoise, seed + 1);
        }, 100},
        {"clicks / wrapper crinkles", 0.0f, [&](std::vector<float> & audio, float rate, uint32_t seed) {
            addClicks(audio, rate, seed);
            addWhiteNoise(audio, micSelfNoise, seed + 1);
        }, 90},
        {"20 dB attenuation + babble", 20.0f, [&](std::vector<float> & audio, float rate, uint32_t seed) {
            addLowFrequencyBabble(audio, decibelsToAmplitude(-20.0f), rate, seed);
            addWhiteNoise(audio, micSelfNoise, seed + 1);
        }, 100},
        {"30 dB attenuation + babble", 30.0f, [&](std::vector<float> & audio, float rate, uint32_t seed) {
            addLowFrequencyBabble(audio, decibelsToAmplitude(-20.0f), rate, seed);
            addWhiteNoise(audio, micSelfNoise, seed + 1);
        }, 90},
        {"40 dB attenuation + babble", 40.0f, [&](std::vector<float> & audio, float rate, uint32_t seed) {
            addLowFrequencyBabble(audio, decibelsToAmplitude(-20.0f), rate, seed);
            addWhiteNoise(audio, micSelfNoise, seed + 1);
        }, 0},
        {"40 dB attenuation + loud room (babble -12 dBFS, clicks)", 40.0f, [&](std::vector<float> & audio, float rate, uint32_t seed) {
            addLowFrequencyBabble(audio, decibelsToAmplitude(-12.0f), rate, seed);
            addClicks(audio, rate, seed + 2);
            addWhiteNoise(audio, micSelfNoise, seed + 1);
        }, 0},
    };

    for (float rate : {48000.0f, 44100.0f}) {
        for (const auto & scenario : scenarios) {
            int successes = 0;
            int wrong = 0;
            float snrSum = 0.0f;
            const int trials = 10;
            for (int trial = 0; trial < trials; ++trial) {
                const auto payload = payloadOfLength(length, 5000 + trial);
                auto signal = encodeToFloat(config, payload, 0.6f, rate);
                scale(signal, decibelsToAmplitude(-scenario.attenuationDb));
                std::vector<float> audio = silence(0.2f + 0.05f * trial, rate);
                append(audio, signal);
                append(audio, silence(0.5f, rate));
                scenario.impair(audio, rate, 9000 + trial);
                clip(audio);
                const auto decodes = runReceiver({config}, audio, rate, 100 + trial);
                if (countMatching(decodes, 0, payload) >= 1) {
                    ++successes;
                    snrSum += decodes.front().snrDb;
                }
                wrong += countWrong(decodes, {payload});
            }
            const int successPercent = successes * 100 / trials;
            std::printf("  %-55s %5.0f Hz: %3d%% decoded, wrong %d, mean snr %.1f dB\n",
                scenario.name.c_str(), rate, successPercent, wrong, successes > 0 ? snrSum / successes : 0.0f);
            expect(wrong == 0, scenario.name + ": zero wrong payloads");
            expect(successPercent >= scenario.minimumSuccessPercent, scenario.name + ": success rate threshold");
        }
    }
}

void testClockDrift() {
    std::printf("clock drift\n");
    const int length = 33;
    const auto config = channelConfig(kMonoToneFastest, kDirectStartBin, length);
    const auto payload = payloadOfLength(length, 77);
    for (float driftPpm : {-1000.0f, -300.0f, 300.0f, 1000.0f}) {
        const float transmitterRate = 48000.0f * (1.0f + driftPpm / 1e6f);
        std::vector<float> audio = silence(0.3f, 48000.0f);
        append(audio, encodeToFloat(config, payload, 0.6f, transmitterRate));
        append(audio, silence(0.5f, 48000.0f));
        addWhiteNoise(audio, decibelsToAmplitude(-75.0f), 3);
        const auto decodes = runReceiver({config}, audio, 48000.0f, 11);
        std::printf("  %+.0f ppm: %d decode(s)\n", driftPpm, countMatching(decodes, 0, payload));
        expect(countMatching(decodes, 0, payload) == 1, "decodes with sample-rate offset");
        expect(countWrong(decodes, {payload}) == 0, "no wrong payload with sample-rate offset");
    }
}

void testSimultaneousBands() {
    std::printf("simultaneous direct + relay bands\n");
    const int length = 9;
    const auto direct = channelConfig(kMonoToneFastest, kDirectStartBin, length);
    const auto relay = channelConfig(kMonoToneFastest, kRelayStartBin, length);
    const auto directPayload = payloadOfLength(length, 1);
    const auto relayPayload = payloadOfLength(length, 2);
    auto directAudio = encodeToFloat(direct, directPayload, 0.4f, 48000.0f);
    auto relayAudio = encodeToFloat(relay, relayPayload, 0.4f, 48000.0f);
    std::vector<float> audio = silence(0.3f, 48000.0f);
    const size_t start = audio.size();
    audio.resize(start + std::max(directAudio.size(), relayAudio.size()) + (size_t) (0.5f * 48000.0f), 0.0f);
    for (size_t index = 0; index < directAudio.size(); ++index) {
        audio[start + index] += directAudio[index];
    }
    const size_t relayOffset = start + 4000;
    for (size_t index = 0; index < relayAudio.size() && relayOffset + index < audio.size(); ++index) {
        audio[relayOffset + index] += relayAudio[index];
    }
    addWhiteNoise(audio, decibelsToAmplitude(-75.0f), 5);
    const auto decodes = runReceiver({direct, relay}, audio, 48000.0f, 13);
    expect(countMatching(decodes, 0, directPayload) == 1, "direct band decodes its payload");
    expect(countMatching(decodes, 1, relayPayload) == 1, "relay band decodes its payload");
    expect(countMatching(decodes, 0, relayPayload) == 0, "relay payload never appears on direct band");
    expect(countMatching(decodes, 1, directPayload) == 0, "direct payload never appears on relay band");
    std::printf("  decodes: %zu\n", decodes.size());
}

void testRepeatedLoopEmitsOncePerRepetition() {
    std::printf("looped broadcast\n");
    const int length = 9;
    const auto config = channelConfig(kMonoToneFastest, kDirectStartBin, length);
    const auto payload = payloadOfLength(length, 3);
    const auto message = encodeToFloat(config, payload, 0.6f, 48000.0f);
    std::vector<float> audio = silence(0.2f, 48000.0f);
    for (int repetition = 0; repetition < 3; ++repetition) {
        append(audio, message);
        append(audio, silence(0.3f, 48000.0f));
    }
    addWhiteNoise(audio, decibelsToAmplitude(-75.0f), 8);
    const auto decodes = runReceiver({config}, audio, 48000.0f, 17);
    std::printf("  3 repetitions -> %d decode(s)\n", countMatching(decodes, 0, payload));
    expect(countMatching(decodes, 0, payload) == 3, "one decode per repetition");
}

void testNoiseNeverDecodes() {
    std::printf("noise-only input (no false decodes)\n");
    std::vector<sl_channel_config> channels;
    for (int length : {9, 33, 40}) {
        channels.push_back(channelConfig(kMonoToneFastest, kDirectStartBin, length));
        channels.push_back(channelConfig(kMonoToneFastest, kRelayStartBin, length));
    }
    const float rate = 48000.0f;
    std::vector<float> audio = silence(120.0f, rate);
    addWhiteNoise(audio, decibelsToAmplitude(-30.0f), 21);
    addLowFrequencyBabble(audio, decibelsToAmplitude(-15.0f), rate, 22);
    addClicks(audio, rate, 23);
    std::mt19937 generator(24);
    std::uniform_int_distribution<int> binDistribution(kDirectStartBin, kRelayStartBin + 15);
    const float hzPerBin = rate / 1024.0f;
    for (size_t start = 0; start + 2048 < audio.size(); start += 2048) {
        const float frequency = binDistribution(generator) * hzPerBin;
        for (size_t index = 0; index < 2048; ++index) {
            audio[start + index] += 0.3f * std::sin(2.0f * kPi * frequency * index / rate);
        }
    }
    clip(audio);
    const auto decodes = runReceiver(channels, audio, rate, 31);
    std::printf("  120 s of noise + random in-band tones on 6 channels -> %zu decode(s)\n", decodes.size());
    expect(decodes.empty(), "noise and random tones never produce a payload");
}

void testCorruptedMessageNeverMisdecodes() {
    std::printf("corrupted messages (never a wrong payload)\n");
    const int length = 33;
    const auto config = channelConfig(kMonoToneFastest, kDirectStartBin, length);
    int wrong = 0;
    int decoded = 0;
    const int trials = 40;
    for (int trial = 0; trial < trials; ++trial) {
        const auto payload = payloadOfLength(length, 600 + trial);
        auto message = encodeToFloat(config, payload, 0.6f, 48000.0f);
        std::mt19937 generator(700 + trial);
        std::uniform_int_distribution<size_t> position(0, message.size() - 1);
        std::uniform_real_distribution<float> uniform(-1.0f, 1.0f);
        const int damagedSegments = 1 + trial % 6;
        for (int segment = 0; segment < damagedSegments; ++segment) {
            const size_t start = position(generator);
            const float hzPerBin = 48000.0f / 1024.0f;
            const float frequency = (kDirectStartBin + (int) (generator() % 16)) * hzPerBin;
            for (size_t index = start; index < std::min(message.size(), start + 3072); ++index) {
                message[index] = 0.6f * std::sin(2.0f * kPi * frequency * index / 48000.0f) + 0.1f * uniform(generator);
            }
        }
        std::vector<float> audio = silence(0.3f, 48000.0f);
        append(audio, message);
        append(audio, silence(0.5f, 48000.0f));
        const auto decodes = runReceiver({config}, audio, 48000.0f, 800 + trial);
        decoded += countMatching(decodes, 0, payload) > 0 ? 1 : 0;
        wrong += countWrong(decodes, {payload});
    }
    std::printf("  %d trials with 1-6 overwritten segments: %d recovered by error correction, %d wrong\n", trials, decoded, wrong);
    expect(wrong == 0, "corrupted messages never yield a wrong payload");
}

void testLevelMeter() {
    std::printf("level meter\n");
    const float rate = 48000.0f;
    const auto config = channelConfig(kMonoToneFastest, kDirectStartBin, 9);
    sl_receiver * receiver = sl_receiver_create(rate, &config, 1);
    const float hzPerBin = rate / 1024.0f;
    const float frequency = (kDirectStartBin + 5) * hzPerBin;
    std::vector<float> audio((size_t) (0.5f * rate));
    for (size_t index = 0; index < audio.size(); ++index) {
        audio[index] = 0.5f * std::sin(2.0f * kPi * frequency * index / rate);
    }
    addWhiteNoise(audio, decibelsToAmplitude(-70.0f), 41);
    sl_receiver_process(receiver, audio.data(), (int) audio.size());
    sl_levels levels;
    const int hasLevels = sl_receiver_take_levels(receiver, 0, &levels);
    const float overall = sl_receiver_take_overall_dbfs(receiver);
    std::printf("  0.5 amplitude tone: signal %.1f dBFS, noise floor %.1f dBFS, snr %.1f dB, overall %.1f dBFS\n",
        levels.signal_dbfs, levels.noise_floor_dbfs, levels.snr_db, overall);
    expect(hasLevels == 1, "levels available after audio");
    expect(std::fabs(levels.signal_dbfs - (-6.0f)) < 1.0f, "half-scale tone reads about -6 dBFS");
    expect(std::fabs(overall - (-6.0f)) < 1.0f, "overall level of half-scale tone reads about -6 dBFS");
    expect(levels.snr_db > 40.0f, "clean tone has high snr");
    expect(sl_receiver_take_levels(receiver, 0, &levels) == 0, "levels are consumed once");

    std::vector<float> quiet((size_t) (0.5f * rate), 0.0f);
    addWhiteNoise(quiet, decibelsToAmplitude(-60.0f), 42);
    sl_receiver_process(receiver, quiet.data(), (int) quiet.size());
    sl_receiver_take_levels(receiver, 0, &levels);
    std::printf("  noise only: signal %.1f dBFS, noise floor %.1f dBFS, snr %.1f dB (baseline)\n",
        levels.signal_dbfs, levels.noise_floor_dbfs, levels.snr_db);
    sl_receiver_destroy(receiver);

    const auto relayConfig = channelConfig(kMonoToneFastest, kRelayStartBin, 9);
    for (float inputRate : {44100.0f, 48000.0f}) {
        sl_receiver * resampling = sl_receiver_create(inputRate, &relayConfig, 1);
        const float topFrequency = (kRelayStartBin + 15) * hzPerBin;
        std::vector<float> tone((size_t) (0.5f * inputRate));
        for (size_t index = 0; index < tone.size(); ++index) {
            tone[index] = 0.5f * std::sin(2.0f * kPi * topFrequency * index / inputRate);
        }
        sl_receiver_process(resampling, tone.data(), (int) tone.size());
        sl_receiver_take_levels(resampling, 0, &levels);
        std::printf("  %.0f Hz tone captured at %.0f Hz: signal %.1f dBFS\n", topFrequency, inputRate, levels.signal_dbfs);
        expect(std::fabs(levels.signal_dbfs - (-6.0f)) < 1.0f, "top of relay band survives input resampling");
        sl_receiver_destroy(resampling);
    }
}

}

void testReedSolomonFuzz() {
    std::printf("reed-solomon fuzz (uncorrectable inputs must fail cleanly)\n");
    std::mt19937 generator(1234);
    int iterations = 0;
    int recoveredWithinCapacity = 0;
    int withinCapacity = 0;
    for (int messageLength : {11, 13, 37, 44, 64}) {
        const int eccLength = messageLength < 4 ? 2 : std::max(4, 2 * (messageLength / 5));
        std::vector<uint8_t> work(RS::ReedSolomon::getWorkSize_bytes(messageLength, eccLength));
        for (int trial = 0; trial < 4000; ++trial) {
            if (trial % 2 == 0) {
                std::fill(work.begin(), work.end(), 0);
            }
            RS::ReedSolomon codec((uint8_t) messageLength, (uint8_t) eccLength, work.data());
            std::vector<uint8_t> message(messageLength);
            for (auto & byte : message) byte = (uint8_t) (generator() & 0xFF);
            std::vector<uint8_t> encoded(messageLength + eccLength);
            codec.Encode(message.data(), encoded.data());
            const int corruptions = (int) (generator() % (messageLength + eccLength + 1));
            for (int corruption = 0; corruption < corruptions; ++corruption) {
                encoded[generator() % encoded.size()] = (uint8_t) (generator() & 0xFF);
            }
            if (trial % 5 == 0) {
                for (auto & byte : encoded) byte = (uint8_t) (generator() & 0xFF);
            }
            std::vector<uint8_t> decoded(messageLength);
            const int result = codec.Decode(encoded.data(), decoded.data());
            if (corruptions <= eccLength / 2 && trial % 5 != 0) {
                ++withinCapacity;
                if (result == 0 && decoded == message) ++recoveredWithinCapacity;
            }
            ++iterations;
        }
    }
    std::printf("  %d decodes without crash; %d/%d within capacity recovered\n", iterations, recoveredWithinCapacity, withinCapacity);
    expect(recoveredWithinCapacity == withinCapacity, "codewords within correction capacity are recovered");
}

void testListeningOnAllLengths() {
    std::printf("listening on all lengths while one length is broadcast\n");
    const std::vector<int> lengths = {9, 33, 40};
    std::vector<sl_channel_config> channels;
    for (int length : lengths) channels.push_back(channelConfig(kMonoToneFastest, kDirectStartBin, length));
    for (int length : lengths) channels.push_back(channelConfig(kMonoToneFastest, kRelayStartBin, length));
    for (size_t lengthIndex = 0; lengthIndex < lengths.size(); ++lengthIndex) {
        for (float rate : {48000.0f, 44100.0f}) {
            const int length = lengths[lengthIndex];
            const auto config = channelConfig(kMonoToneFastest, kDirectStartBin, length);
            const auto payload = payloadOfLength(length, 4000 + length);
            const auto message = encodeToFloat(config, payload, 0.6f, rate);
            std::vector<float> audio = silence(0.2f, rate);
            for (int repetition = 0; repetition < 4; ++repetition) {
                append(audio, message);
                append(audio, silence(0.3f, rate));
            }
            addWhiteNoise(audio, decibelsToAmplitude(-70.0f), 900 + length);
            const auto decodes = runReceiver(channels, audio, rate, 77);
            const int matches = countMatching(decodes, (int) lengthIndex, payload);
            std::printf("  %2d-byte broadcast at %.0f Hz -> %d correct, %zu total\n", length, rate, matches, decodes.size());
            expect(matches == 4, "every repetition decodes on the matching length");
            expect((int) decodes.size() == matches, "other lengths and the relay band stay silent");
        }
    }
}

int main() {
    testBandGeometry();
    testInvalidConfigs();
    testCleanLoopback();
    testLevelMeter();
    testRepeatedLoopEmitsOncePerRepetition();
    testSimultaneousBands();
    testClockDrift();
    testRobustness();
    testCorruptedMessageNeverMisdecodes();
    testNoiseNeverDecodes();
    testListeningOnAllLengths();
    testReedSolomonFuzz();
    std::printf(failures == 0 ? "\nALL PASSED\n" : "\n%d FAILURE(S)\n", failures);
    return failures == 0 ? 0 : 1;
}
