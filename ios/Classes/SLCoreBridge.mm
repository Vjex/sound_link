#import "SLCoreBridge.h"

#include <vector>

#include "sound_link_core.h"

static sl_channel_config SLMakeConfig(SLChannelConfig *channel) {
    sl_channel_config config;
    config.protocol_id = channel.protocolId;
    config.start_bin = channel.startBin;
    config.payload_length = channel.payloadLength;
    config.checksum = channel.checksum ? 1 : 0;
    return config;
}

@implementation SLChannelConfig

- (instancetype)initWithProtocolId:(int)protocolId
                          startBin:(int)startBin
                     payloadLength:(int)payloadLength
                          checksum:(BOOL)checksum {
    self = [super init];
    if (self) {
        _protocolId = protocolId;
        _startBin = startBin;
        _payloadLength = payloadLength;
        _checksum = checksum;
    }
    return self;
}

@end

@interface SLDecodedPayload ()

- (instancetype)initWithDecoded:(const sl_decoded &)decoded;

@end

@implementation SLDecodedPayload

- (instancetype)initWithDecoded:(const sl_decoded &)decoded {
    self = [super init];
    if (self) {
        _channelIndex = decoded.channel_index;
        _payload = [NSData dataWithBytes:decoded.payload length:decoded.payload_length];
        _snrDb = decoded.snr_db;
        _signalDbfs = decoded.signal_dbfs;
        _noiseFloorDbfs = decoded.noise_floor_dbfs;
    }
    return self;
}

@end

@implementation SLCoreBridge

+ (NSData *)encodeChannel:(SLChannelConfig *)channel
                  payload:(NSData *)payload
                   volume:(float)volume
         outputSampleRate:(double)outputSampleRate {
    const sl_channel_config config = SLMakeConfig(channel);
    const uint8_t *bytes = (const uint8_t *) payload.bytes;
    const int length = (int) payload.length;
    const int capacity = sl_encode(&config, bytes, length, volume, (float) outputSampleRate, nullptr, 0);
    if (capacity <= 0) {
        return nil;
    }
    std::vector<int16_t> samples(capacity);
    const int written = sl_encode(&config, bytes, length, volume, (float) outputSampleRate, samples.data(), capacity);
    if (written <= 0) {
        return nil;
    }
    return [NSData dataWithBytes:samples.data() length:written * sizeof(int16_t)];
}

@end

@implementation SLCoreReceiver {
    sl_receiver *_receiver;
}

- (instancetype)initWithInputSampleRate:(double)inputSampleRate channels:(NSArray<SLChannelConfig *> *)channels {
    self = [super init];
    if (self) {
        std::vector<sl_channel_config> configs;
        for (SLChannelConfig *channel in channels) {
            configs.push_back(SLMakeConfig(channel));
        }
        _receiver = sl_receiver_create((float) inputSampleRate, configs.data(), (int) configs.size());
        if (_receiver == nullptr) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    sl_receiver_destroy(_receiver);
}

- (NSInteger)processSamples:(const float *)samples count:(NSInteger)count {
    return sl_receiver_process(_receiver, samples, (int) count);
}

- (SLDecodedPayload *)takeDecoded {
    sl_decoded decoded;
    if (!sl_receiver_take_decoded(_receiver, &decoded)) {
        return nil;
    }
    return [[SLDecodedPayload alloc] initWithDecoded:decoded];
}

- (NSArray<NSNumber *> *)takeLevelsForChannel:(NSInteger)channelIndex {
    sl_levels levels;
    if (!sl_receiver_take_levels(_receiver, (int) channelIndex, &levels)) {
        return nil;
    }
    return @[@(levels.signal_dbfs), @(levels.noise_floor_dbfs), @(levels.snr_db)];
}

- (float)takeOverallDbfs {
    return sl_receiver_take_overall_dbfs(_receiver);
}

@end
