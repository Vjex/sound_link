#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SLChannelConfig : NSObject

@property (nonatomic) int protocolId;
@property (nonatomic) int startBin;
@property (nonatomic) int payloadLength;
@property (nonatomic) BOOL checksum;

- (instancetype)initWithProtocolId:(int)protocolId
                          startBin:(int)startBin
                     payloadLength:(int)payloadLength
                          checksum:(BOOL)checksum;

@end

@interface SLDecodedPayload : NSObject

@property (nonatomic, readonly) NSInteger channelIndex;
@property (nonatomic, readonly) NSData *payload;
@property (nonatomic, readonly) float snrDb;
@property (nonatomic, readonly) float signalDbfs;
@property (nonatomic, readonly) float noiseFloorDbfs;

@end

@interface SLCoreBridge : NSObject

+ (nullable NSData *)encodeChannel:(SLChannelConfig *)channel
                           payload:(NSData *)payload
                            volume:(float)volume
                  outputSampleRate:(double)outputSampleRate;

@end

@interface SLCoreReceiver : NSObject

- (nullable instancetype)initWithInputSampleRate:(double)inputSampleRate
                                        channels:(NSArray<SLChannelConfig *> *)channels;
- (NSInteger)processSamples:(const float *)samples count:(NSInteger)count;
- (nullable SLDecodedPayload *)takeDecoded;
- (nullable NSArray<NSNumber *> *)takeLevelsForChannel:(NSInteger)channelIndex;
- (float)takeOverallDbfs;

@end

NS_ASSUME_NONNULL_END
