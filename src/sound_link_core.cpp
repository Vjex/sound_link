#include "sound_link_core.h"

#include "ggwave/ggwave.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <vector>

namespace {

constexpr float kOperatingSampleRate = 48000.0f;
constexpr int kSamplesPerFrame = 1024;
constexpr int kChecksumBytes = 4;
constexpr int kVariableLengthHeaderBytes = 3;
constexpr int kMarkerFrames = 16;
constexpr float kMinimumPower = 1e-20f;
constexpr double kPi = 3.14159265358979323846;
constexpr int kResamplerHalfWidth = 64;
constexpr int kResamplerPhases = 512;
constexpr double kResamplerCutoffFraction = 0.975;

std::mutex & protocolTableMutex() {
    static std::mutex mutex;
    return mutex;
}

bool isKnownProtocol(int protocolId) {
    if (protocolId < 0 || protocolId >= GGWAVE_PROTOCOL_COUNT) {
        return false;
    }
    return GGWave::Protocols::kDefault()[protocolId].name != nullptr;
}

const GGWave::Protocol & protocolFor(int protocolId) {
    return GGWave::Protocols::kDefault()[protocolId];
}

bool isMonoTone(const GGWave::Protocol & protocol) {
    return protocol.extra == 2;
}

int eccBytesForLength(int length) {
    return length < 4 ? 2 : std::max(4, 2 * (length / 5));
}

int wireLength(const sl_channel_config & config, int payloadLength) {
    return payloadLength + (config.checksum ? kChecksumBytes : 0);
}

bool isFixedLength(const sl_channel_config & config) {
    return config.payload_length > 0;
}

int bandBins(const sl_channel_config & config) {
    const auto & protocol = protocolFor(config.protocol_id);
    return isMonoTone(protocol) ? 16 : 32 * protocol.bytesPerTx;
}

bool isValidConfig(const sl_channel_config & config) {
    if (!isKnownProtocol(config.protocol_id)) {
        return false;
    }
    const auto & protocol = protocolFor(config.protocol_id);
    if (isMonoTone(protocol) && !isFixedLength(config)) {
        return false;
    }
    if (config.start_bin < 1 || config.start_bin + bandBins(config) >= kSamplesPerFrame / 2) {
        return false;
    }
    if (config.payload_length < 0) {
        return false;
    }
    if (isFixedLength(config)) {
        return wireLength(config, config.payload_length) <= GGWave::kMaxLengthFixed;
    }
    return true;
}

int maxPayloadLength(const sl_channel_config & config) {
    const int limit = isFixedLength(config) ? GGWave::kMaxLengthFixed : GGWave::kMaxLengthVariable;
    return limit - (config.checksum ? kChecksumBytes : 0);
}

int messageFrames(const sl_channel_config & config, int payloadLength) {
    const auto & protocol = protocolFor(config.protocol_id);
    const int wire = wireLength(config, payloadLength);
    if (isFixedLength(config)) {
        const int totalBytes = wire + eccBytesForLength(wire);
        const int transmissions = (totalBytes + protocol.bytesPerTx - 1) / protocol.bytesPerTx;
        return protocol.extra * transmissions * protocol.framesPerTx;
    }
    const int totalBytes = wire + kVariableLengthHeaderBytes + eccBytesForLength(wire);
    const int transmissions = (totalBytes + protocol.bytesPerTx - 1) / protocol.bytesPerTx;
    return kMarkerFrames + protocol.extra * transmissions * protocol.framesPerTx + kMarkerFrames;
}

uint32_t crc32(const uint8_t * data, int length) {
    uint32_t crc = 0xFFFFFFFFu;
    for (int index = 0; index < length; ++index) {
        crc ^= data[index];
        for (int bit = 0; bit < 8; ++bit) {
            const uint32_t mask = 0u - (crc & 1u);
            crc = (crc >> 1) ^ (0xEDB88320u & mask);
        }
    }
    return ~crc;
}

void appendChecksum(std::vector<uint8_t> & bytes) {
    const uint32_t checksum = crc32(bytes.data(), (int) bytes.size());
    bytes.push_back((uint8_t) (checksum >> 24));
    bytes.push_back((uint8_t) (checksum >> 16));
    bytes.push_back((uint8_t) (checksum >> 8));
    bytes.push_back((uint8_t) checksum);
}

bool stripChecksum(const uint8_t * wire, int wireLength, int & payloadLength) {
    if (wireLength <= kChecksumBytes) {
        return false;
    }
    payloadLength = wireLength - kChecksumBytes;
    const uint32_t expected = crc32(wire, payloadLength);
    const uint32_t received =
        ((uint32_t) wire[payloadLength] << 24) |
        ((uint32_t) wire[payloadLength + 1] << 16) |
        ((uint32_t) wire[payloadLength + 2] << 8) |
        (uint32_t) wire[payloadLength + 3];
    return expected == received;
}

std::unique_ptr<GGWave> createInstance(const sl_channel_config & config, int operatingMode, int fixedWireLength) {
    std::lock_guard<std::mutex> lock(protocolTableMutex());

    GGWave::setLogFile(nullptr);

    auto & table = operatingMode == GGWAVE_OPERATING_MODE_TX ? GGWave::Protocols::tx() : GGWave::Protocols::rx();
    const GGWave::Protocols original = table;

    table.only((GGWave::ProtocolId) config.protocol_id);
    table[config.protocol_id].freqStart = (int16_t) config.start_bin;

    GGWave::Parameters parameters = GGWave::getDefaultParameters();
    parameters.payloadLength = fixedWireLength;
    parameters.sampleRateInp = kOperatingSampleRate;
    parameters.sampleRateOut = kOperatingSampleRate;
    parameters.sampleRate = kOperatingSampleRate;
    parameters.samplesPerFrame = kSamplesPerFrame;
    parameters.sampleFormatInp = GGWAVE_SAMPLE_FORMAT_F32;
    parameters.sampleFormatOut = GGWAVE_SAMPLE_FORMAT_I16;
    parameters.operatingMode = operatingMode;

    auto instance = std::make_unique<GGWave>(parameters);

    table = original;

    return instance;
}

class StreamingResampler {
public:
    StreamingResampler(double inputRate, double outputRate)
        : m_step(inputRate / outputRate) {
        const double cutoff = kResamplerCutoffFraction * 0.5 * std::min(inputRate, outputRate) / inputRate;
        m_table.assign((size_t) (kResamplerPhases + 1) * 2 * kResamplerHalfWidth, 0.0f);
        for (int phase = 0; phase <= kResamplerPhases; ++phase) {
            const double fraction = (double) phase / kResamplerPhases;
            for (int tap = 0; tap < 2 * kResamplerHalfWidth; ++tap) {
                const double distance = (tap - kResamplerHalfWidth + 1) - fraction;
                const double argument = 2.0 * cutoff * distance;
                const double sinc = std::fabs(argument) < 1e-12 ? 1.0 : std::sin(kPi * argument) / (kPi * argument);
                const double position = (distance + kResamplerHalfWidth) / (2.0 * kResamplerHalfWidth);
                const double window = position <= 0.0 || position >= 1.0 ? 0.0
                    : 0.42 - 0.5 * std::cos(2.0 * kPi * position) + 0.08 * std::cos(4.0 * kPi * position);
                m_table[(size_t) phase * 2 * kResamplerHalfWidth + tap] = (float) (2.0 * cutoff * sinc * window);
            }
        }
        m_history.assign(2 * kResamplerHalfWidth, 0.0f);
        m_position = 2 * kResamplerHalfWidth;
    }

    void process(const float * input, int count, std::vector<float> & output) {
        m_history.insert(m_history.end(), input, input + count);
        while (m_position + kResamplerHalfWidth < (double) m_history.size()) {
            const int base = (int) std::floor(m_position);
            const double fraction = m_position - base;
            const double scaledPhase = fraction * kResamplerPhases;
            const int phase = std::min(kResamplerPhases - 1, (int) scaledPhase);
            const float blend = (float) (scaledPhase - phase);
            const float * lower = &m_table[(size_t) phase * 2 * kResamplerHalfWidth];
            const float * upper = &m_table[(size_t) (phase + 1) * 2 * kResamplerHalfWidth];
            const int first = base - kResamplerHalfWidth + 1;
            float sum = 0.0f;
            for (int tap = 0; tap < 2 * kResamplerHalfWidth; ++tap) {
                const float coefficient = lower[tap] + blend * (upper[tap] - lower[tap]);
                sum += m_history[first + tap] * coefficient;
            }
            output.push_back(sum);
            m_position += m_step;
        }
        const int discard = std::max(0, (int) std::floor(m_position) - kResamplerHalfWidth + 1);
        if (discard > 0) {
            m_history.erase(m_history.begin(), m_history.begin() + discard);
            m_position -= discard;
        }
    }

    void flush(std::vector<float> & output) {
        const std::vector<float> padding(2 * kResamplerHalfWidth, 0.0f);
        process(padding.data(), (int) padding.size(), output);
    }

private:
    double m_step;
    double m_position;
    std::vector<float> m_table;
    std::vector<float> m_history;
};

float powerToDbfs(float power) {
    const float fullScaleAmplitude = kSamplesPerFrame / 4.0f;
    return 10.0f * std::log10(std::max(power, kMinimumPower) / (fullScaleAmplitude * fullScaleAmplitude));
}

float median(std::vector<float> values) {
    if (values.empty()) {
        return 0.0f;
    }
    const size_t middle = values.size() / 2;
    std::nth_element(values.begin(), values.begin() + middle, values.end());
    return values[middle];
}

struct FrameLevels {
    float signalDbfs;
    float noiseFloorDbfs;
    float snrDb;
};

struct Channel {
    sl_channel_config config;
    std::unique_ptr<GGWave> ggwave;
    int historyCapacity = 1;
    std::deque<FrameLevels> history;
    std::vector<float> pendingSignalDbfs;
    std::vector<float> pendingNoiseFloorDbfs;
    std::vector<float> pendingSnrDb;
    std::vector<uint8_t> lastPayload;
    long long lastDecodeFrame = -1;
};

}

struct sl_receiver {
    std::unique_ptr<StreamingResampler> resampler;
    std::vector<float> resampled;
    std::vector<Channel> channels;
    std::vector<float> frame;
    int frameFill = 0;
    long long frameCounter = 0;
    std::vector<float> window;
    std::vector<float> fftBuffer;
    std::vector<int> fftWorkInt;
    std::vector<float> fftWorkFloat;
    std::vector<float> binPower;
    std::vector<float> bandPowers;
    std::deque<sl_decoded> decoded;
    bool hasPendingOverall = false;
    float pendingOverallDbfs = -200.0f;
};

namespace {

void meterFrame(sl_receiver & receiver) {
    for (int index = 0; index < kSamplesPerFrame; ++index) {
        receiver.fftBuffer[index] = receiver.frame[index] * receiver.window[index];
    }
    std::fill(receiver.fftBuffer.begin() + kSamplesPerFrame, receiver.fftBuffer.end(), 0.0f);
    GGWave::computeFFTR(
        receiver.fftBuffer.data(),
        receiver.fftBuffer.data() + kSamplesPerFrame,
        kSamplesPerFrame,
        receiver.fftWorkInt.data(),
        receiver.fftWorkFloat.data());

    const float * spectrum = receiver.fftBuffer.data() + kSamplesPerFrame;
    for (int bin = 1; bin < kSamplesPerFrame / 2; ++bin) {
        const float real = spectrum[2 * bin];
        const float imaginary = spectrum[2 * bin + 1];
        receiver.binPower[bin] = real * real + imaginary * imaginary;
    }

    double sumOfSquares = 0.0;
    for (int index = 0; index < kSamplesPerFrame; ++index) {
        sumOfSquares += (double) receiver.frame[index] * receiver.frame[index];
    }
    const float rms = (float) std::sqrt(sumOfSquares / kSamplesPerFrame);
    const float overallDbfs = 20.0f * std::log10(std::max(rms * std::sqrt(2.0f), 1e-10f));
    receiver.pendingOverallDbfs = receiver.hasPendingOverall
        ? std::max(receiver.pendingOverallDbfs, overallDbfs)
        : overallDbfs;
    receiver.hasPendingOverall = true;

    for (auto & channel : receiver.channels) {
        const int firstBin = channel.config.start_bin;
        const int lastBin = channel.config.start_bin + bandBins(channel.config) - 1;
        receiver.bandPowers.assign(receiver.binPower.begin() + firstBin, receiver.binPower.begin() + lastBin + 1);
        const float peakPower = *std::max_element(receiver.bandPowers.begin(), receiver.bandPowers.end());
        const float noisePower = median(receiver.bandPowers);

        FrameLevels levels;
        levels.signalDbfs = powerToDbfs(peakPower);
        levels.noiseFloorDbfs = powerToDbfs(noisePower);
        levels.snrDb = levels.signalDbfs - levels.noiseFloorDbfs;

        channel.history.push_back(levels);
        while ((int) channel.history.size() > channel.historyCapacity) {
            channel.history.pop_front();
        }

        channel.pendingSignalDbfs.push_back(levels.signalDbfs);
        channel.pendingNoiseFloorDbfs.push_back(levels.noiseFloorDbfs);
        channel.pendingSnrDb.push_back(levels.snrDb);
    }
}

void decodeFrame(sl_receiver & receiver) {
    for (int channelIndex = 0; channelIndex < (int) receiver.channels.size(); ++channelIndex) {
        auto & channel = receiver.channels[channelIndex];
        channel.ggwave->decode(receiver.frame.data(), kSamplesPerFrame * sizeof(float));

        GGWave::TxRxData received;
        const int receivedLength = channel.ggwave->rxTakeData(received);
        if (receivedLength <= 0) {
            continue;
        }

        std::vector<uint8_t> wire(received.data(), received.data() + receivedLength);
        int payloadLength = receivedLength;
        if (channel.config.checksum && !stripChecksum(wire.data(), receivedLength, payloadLength)) {
            continue;
        }
        if (payloadLength > SL_MAX_PAYLOAD_BYTES) {
            continue;
        }
        wire.resize(payloadLength);

        const int frames = messageFrames(channel.config, payloadLength);
        const bool isDuplicate =
            channel.lastDecodeFrame >= 0 &&
            receiver.frameCounter - channel.lastDecodeFrame < std::max(1, frames / 2) &&
            wire == channel.lastPayload;
        channel.lastDecodeFrame = receiver.frameCounter;
        if (isDuplicate) {
            continue;
        }
        channel.lastPayload = wire;

        std::vector<float> signals;
        std::vector<float> noises;
        std::vector<float> ratios;
        const int historyStart = std::max(0, (int) channel.history.size() - frames);
        for (int historyIndex = historyStart; historyIndex < (int) channel.history.size(); ++historyIndex) {
            const auto & levels = channel.history[historyIndex];
            signals.push_back(levels.signalDbfs);
            noises.push_back(levels.noiseFloorDbfs);
            ratios.push_back(levels.snrDb);
        }

        sl_decoded event;
        std::memset(&event, 0, sizeof(event));
        event.channel_index = channelIndex;
        event.payload_length = payloadLength;
        std::memcpy(event.payload, wire.data(), payloadLength);
        event.snr_db = median(ratios);
        event.signal_dbfs = median(signals);
        event.noise_floor_dbfs = median(noises);
        receiver.decoded.push_back(event);
    }
}

void consumeOperatingRateSamples(sl_receiver & receiver, const float * samples, int count) {
    int consumed = 0;
    while (consumed < count) {
        const int copied = std::min(kSamplesPerFrame - receiver.frameFill, count - consumed);
        std::memcpy(receiver.frame.data() + receiver.frameFill, samples + consumed, copied * sizeof(float));
        receiver.frameFill += copied;
        consumed += copied;

        if (receiver.frameFill == kSamplesPerFrame) {
            meterFrame(receiver);
            decodeFrame(receiver);
            receiver.frameFill = 0;
            receiver.frameCounter += 1;
        }
    }
}

}

extern "C" {

float sl_operating_sample_rate(void) {
    return kOperatingSampleRate;
}

int sl_samples_per_frame(void) {
    return kSamplesPerFrame;
}

int sl_band_bins(const sl_channel_config * config) {
    if (config == nullptr || !isKnownProtocol(config->protocol_id)) {
        return -1;
    }
    return bandBins(*config);
}

int sl_message_frames(const sl_channel_config * config, int payload_length) {
    if (config == nullptr || !isValidConfig(*config)) {
        return -1;
    }
    const int length = isFixedLength(*config) ? config->payload_length : payload_length;
    if (length <= 0 || length > maxPayloadLength(*config)) {
        return -1;
    }
    return messageFrames(*config, length);
}

int sl_max_payload_length(const sl_channel_config * config) {
    if (config == nullptr || !isKnownProtocol(config->protocol_id)) {
        return -1;
    }
    return maxPayloadLength(*config);
}

int sl_encode(
        const sl_channel_config * config,
        const uint8_t * payload,
        int payload_length,
        float volume,
        float output_sample_rate,
        int16_t * output,
        int output_capacity) {
    if (config == nullptr || payload == nullptr || !isValidConfig(*config)) {
        return -1;
    }
    if (payload_length <= 0 || payload_length > maxPayloadLength(*config)) {
        return -2;
    }
    if (isFixedLength(*config) && payload_length != config->payload_length) {
        return -2;
    }
    if (output_sample_rate < 2.0f * 20500.0f || output_sample_rate > GGWave::kSampleRateMax) {
        return -3;
    }

    std::vector<uint8_t> wire(payload, payload + payload_length);
    if (config->checksum) {
        appendChecksum(wire);
    }

    const int fixedWireLength = isFixedLength(*config) ? (int) wire.size() : -1;
    auto instance = createInstance(*config, GGWAVE_OPERATING_MODE_TX, fixedWireLength);

    const float clampedVolume = std::min(std::max(volume, 0.0f), 0.99f);
    const int ggwaveVolume = (int) std::lround(clampedVolume * 100.0f);
    if (!instance->init((int) wire.size(), (const char *) wire.data(), (GGWave::TxProtocolId) config->protocol_id, ggwaveVolume)) {
        return -4;
    }

    const int operatingSamples = (int) instance->encodeSize_samples();
    const bool needsResampling = output_sample_rate != kOperatingSampleRate;
    const int upperBound = needsResampling
        ? (int) std::ceil(operatingSamples * output_sample_rate / kOperatingSampleRate) + 2 * kResamplerHalfWidth + 2
        : operatingSamples;
    if (output == nullptr) {
        return upperBound;
    }

    const uint32_t bytes = instance->encode();
    const int samples = (int) (bytes / sizeof(int16_t));
    if (samples <= 0) {
        return -4;
    }
    const int16_t * waveform = (const int16_t *) instance->txWaveform();

    if (!needsResampling) {
        if (samples > output_capacity) {
            return -5;
        }
        std::memcpy(output, waveform, samples * sizeof(int16_t));
        return samples;
    }

    std::vector<float> operating(samples);
    for (int index = 0; index < samples; ++index) {
        operating[index] = waveform[index] / 32768.0f;
    }
    StreamingResampler resampler(kOperatingSampleRate, output_sample_rate);
    std::vector<float> converted;
    converted.reserve(upperBound);
    resampler.process(operating.data(), samples, converted);
    resampler.flush(converted);
    const int expected = (int) std::lround(samples * output_sample_rate / kOperatingSampleRate);
    const int count = std::min(expected, (int) converted.size());
    if (count <= 0 || count > output_capacity) {
        return -5;
    }
    for (int index = 0; index < count; ++index) {
        const float value = std::max(-1.0f, std::min(32767.0f / 32768.0f, converted[index]));
        output[index] = (int16_t) std::lround(value * 32768.0f);
    }
    return count;
}

sl_receiver * sl_receiver_create(
        float input_sample_rate,
        const sl_channel_config * channels,
        int channel_count) {
    if (channels == nullptr || channel_count <= 0) {
        return nullptr;
    }
    if (input_sample_rate < 2.0f * 20500.0f || input_sample_rate > GGWave::kSampleRateMax) {
        return nullptr;
    }

    auto receiver = std::make_unique<sl_receiver>();
    if (input_sample_rate != kOperatingSampleRate) {
        receiver->resampler = std::make_unique<StreamingResampler>(input_sample_rate, kOperatingSampleRate);
    }
    receiver->frame.assign(kSamplesPerFrame, 0.0f);
    receiver->fftBuffer.assign(3 * kSamplesPerFrame, 0.0f);
    receiver->fftWorkInt.assign(2 * kSamplesPerFrame, 0);
    receiver->fftWorkFloat.assign(kSamplesPerFrame, 0.0f);
    receiver->binPower.assign(kSamplesPerFrame / 2, 0.0f);
    receiver->window.assign(kSamplesPerFrame, 0.0f);
    for (int index = 0; index < kSamplesPerFrame; ++index) {
        receiver->window[index] = (float) (0.5 - 0.5 * std::cos(2.0 * kPi * index / kSamplesPerFrame));
    }

    for (int index = 0; index < channel_count; ++index) {
        const auto & config = channels[index];
        if (!isValidConfig(config)) {
            return nullptr;
        }

        Channel channel;
        channel.config = config;
        const int fixedWireLength = isFixedLength(config) ? wireLength(config, config.payload_length) : -1;
        channel.ggwave = createInstance(config, GGWAVE_OPERATING_MODE_RX, fixedWireLength);
        const int longestPayload = isFixedLength(config) ? config.payload_length : maxPayloadLength(config);
        channel.historyCapacity = std::max(1, messageFrames(config, longestPayload));
        receiver->channels.push_back(std::move(channel));
    }

    return receiver.release();
}

void sl_receiver_destroy(sl_receiver * receiver) {
    delete receiver;
}

int sl_receiver_process(sl_receiver * receiver, const float * samples, int sample_count) {
    if (receiver == nullptr || samples == nullptr || sample_count < 0) {
        return -1;
    }
    const size_t decodedBefore = receiver->decoded.size();
    if (receiver->resampler) {
        receiver->resampled.clear();
        receiver->resampler->process(samples, sample_count, receiver->resampled);
        consumeOperatingRateSamples(*receiver, receiver->resampled.data(), (int) receiver->resampled.size());
    } else {
        consumeOperatingRateSamples(*receiver, samples, sample_count);
    }
    return (int) (receiver->decoded.size() - decodedBefore);
}

int sl_receiver_take_decoded(sl_receiver * receiver, sl_decoded * output) {
    if (receiver == nullptr || output == nullptr || receiver->decoded.empty()) {
        return 0;
    }
    *output = receiver->decoded.front();
    receiver->decoded.pop_front();
    return 1;
}

int sl_receiver_take_levels(sl_receiver * receiver, int channel_index, sl_levels * output) {
    if (receiver == nullptr || output == nullptr) {
        return 0;
    }
    if (channel_index < 0 || channel_index >= (int) receiver->channels.size()) {
        return 0;
    }
    auto & channel = receiver->channels[channel_index];
    if (channel.pendingSnrDb.empty()) {
        return 0;
    }
    output->signal_dbfs = median(channel.pendingSignalDbfs);
    output->noise_floor_dbfs = median(channel.pendingNoiseFloorDbfs);
    output->snr_db = median(channel.pendingSnrDb);
    channel.pendingSignalDbfs.clear();
    channel.pendingNoiseFloorDbfs.clear();
    channel.pendingSnrDb.clear();
    return 1;
}

float sl_receiver_take_overall_dbfs(sl_receiver * receiver) {
    if (receiver == nullptr || !receiver->hasPendingOverall) {
        return -200.0f;
    }
    receiver->hasPendingOverall = false;
    return receiver->pendingOverallDbfs;
}

}
