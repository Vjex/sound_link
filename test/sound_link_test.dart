import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sound_link/sound_link.dart';

class FakeSoundLinkPlatform extends SoundLinkPlatform with MockPlatformInterfaceMixin {
  final StreamController<Map<Object?, Object?>> events = StreamController<Map<Object?, Object?>>.broadcast();
  final List<Map<String, Object?>> broadcasts = <Map<String, Object?>>[];
  Map<String, Object?>? listenArguments;
  bool stopped = false;

  @override
  Future<Map<Object?, Object?>> checkCapabilities() async => <Object?, Object?>{
        'platform': 'android',
        'deviceModel': 'Pixel',
        'osVersion': '15',
        'outputSampleRate': 48000,
        'inputSampleRate': 48000,
        'unprocessedMicrophoneSupported': true,
        'microphonePermission': 'granted',
        'mediaVolume': 0.8,
        'outputRoute': 'builtInSpeaker',
        'inputRoute': 'builtInMic',
      };

  @override
  Future<Map<Object?, Object?>> startBroadcast({
    required SoundLinkChannel channel,
    required Uint8List payload,
    required double volume,
    required Duration gap,
  }) async {
    broadcasts.add(<String, Object?>{'channel': channel.toMap(), 'payload': payload, 'volume': volume});
    return <Object?, Object?>{'sampleRate': 48000, 'messageSamples': 96000, 'loopSamples': 110400, 'outputRoute': 'speaker'};
  }

  @override
  Future<Map<Object?, Object?>> updateBroadcastPayload(Uint8List payload) async =>
      <Object?, Object?>{'sampleRate': 48000, 'messageSamples': 96000, 'loopSamples': 110400};

  @override
  Future<void> stopBroadcast() async {
    stopped = true;
  }

  @override
  Future<Map<Object?, Object?>> checkReadiness() async => <Object?, Object?>{
        'microphonePermission': 'restricted',
        'inCall': true,
        'otherAudioPlaying': null,
        'inputRoute': 'builtIn',
        'outputRoute': 'bluetooth',
        'mediaVolume': 0.3,
        'canSetMediaVolume': false,
      };

  double? requestedVolume;

  @override
  Future<double> setMediaVolume(double fraction) async {
    requestedVolume = fraction;
    return fraction;
  }

  final StreamController<Map<Object?, Object?>> broadcastStream = StreamController<Map<Object?, Object?>>.broadcast();

  @override
  Stream<Map<Object?, Object?>> broadcastEvents() => broadcastStream.stream;

  @override
  Stream<Map<Object?, Object?>> listen({
    required List<SoundLinkChannel> channels,
    required Duration levelInterval,
    required SoundLinkAndroidAudioSource androidAudioSource,
  }) {
    listenArguments = <String, Object?>{'channels': channels.length, 'interval': levelInterval};
    return events.stream;
  }
}

void main() {
  late FakeSoundLinkPlatform platform;
  late SoundLink soundLink;
  final direct = SoundLinkChannel(
      id: 'direct', protocol: SoundLinkProtocol.monoToneFastest, startFrequencyHz: 18500, payloadLength: 4);
  final relay = SoundLinkChannel(
      id: 'relay', protocol: SoundLinkProtocol.monoToneFastest, startFrequencyHz: 19600, payloadLength: 4);

  setUp(() {
    platform = FakeSoundLinkPlatform();
    soundLink = SoundLink(platform: platform);
  });

  test('capabilities map', () async {
    final capabilities = await soundLink.checkCapabilities();
    expect(capabilities.unprocessedMicrophoneSupported, isTrue);
    expect(capabilities.microphonePermission, SoundLinkPermission.granted);
    expect(capabilities.mediaVolume, 0.8);
  });

  test('broadcast validates payload length against fixed channel', () async {
    expect(
      () => soundLink.startBroadcast(channel: direct, payload: Uint8List.fromList([1, 2, 3])),
      throwsArgumentError,
    );
    final info = await soundLink.startBroadcast(channel: direct, payload: Uint8List.fromList([1, 2, 3, 4]));
    expect(info.messageDuration, const Duration(seconds: 2));
    expect(info.loopDuration, const Duration(milliseconds: 2300));
    expect(platform.broadcasts.single['volume'], 0.6);
  });

  test('update before start throws', () {
    expect(
      () => soundLink.updateBroadcastPayload(Uint8List.fromList([1, 2, 3, 4])),
      throwsA(isA<SoundLinkException>()),
    );
  });

  test('listen maps native events to typed events', () async {
    final received = <SoundLinkEvent>[];
    final subscription = soundLink.listen(channels: [direct, relay]).listen(received.add);

    platform.events.add(<Object?, Object?>{
      'type': 'state',
      'timestampMilliseconds': 1000,
      'status': 'listening',
      'sampleRate': 48000,
      'audioSource': 'unprocessed',
      'inputRoute': 'builtInMic',
    });
    platform.events.add(<Object?, Object?>{
      'type': 'levels',
      'timestampMilliseconds': 1100,
      'overallDbfs': -40.0,
      'processingLoad': 0.12,
      'channels': [
        <Object?, Object?>{'channelIndex': 0, 'signalDbfs': -30.0, 'noiseFloorDbfs': -70.0, 'snrDb': 40.0},
        <Object?, Object?>{'channelIndex': 1, 'signalDbfs': -80.0, 'noiseFloorDbfs': -85.0, 'snrDb': 5.0},
      ],
    });
    platform.events.add(<Object?, Object?>{
      'type': 'decoded',
      'timestampMilliseconds': 1200,
      'channelIndex': 1,
      'payload': Uint8List.fromList([9, 8, 7, 6]),
      'snrDb': 22.5,
      'signalDbfs': -41.0,
      'noiseFloorDbfs': -63.5,
    });
    platform.events.add(<Object?, Object?>{'type': 'unknown', 'timestampMilliseconds': 1300});
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(3));
    expect((received[0] as SoundLinkListenerState).audioSource, 'unprocessed');
    final levels = received[1] as SoundLinkLevels;
    expect(levels.processingLoad, 0.12);
    expect(levels.channels[0].channel.id, 'direct');
    expect(levels.channels[1].snrDb, 5.0);
    final decoded = received[2] as SoundLinkDecoded;
    expect(decoded.channel.id, 'relay');
    expect(decoded.payload, [9, 8, 7, 6]);
    expect(decoded.snrDb, 22.5);
    await subscription.cancel();
  });

  test('readiness facts map', () async {
    final readiness = await soundLink.checkReadiness();
    expect(readiness.microphonePermission, SoundLinkPermission.restricted);
    expect(readiness.inCall, isTrue);
    expect(readiness.otherAudioPlaying, isNull);
    expect(readiness.outputRoute, SoundLinkAudioRoute.bluetooth);
    expect(readiness.mediaVolume, 0.3);
  });

  test('media volume is validated and forwarded', () async {
    expect(() => soundLink.setMediaVolume(1.5), throwsRangeError);
    expect(await soundLink.setMediaVolume(0.8), 0.8);
    expect(platform.requestedVolume, 0.8);
  });

  test('broadcast events map', () async {
    final received = <SoundLinkBroadcastEvent>[];
    final subscription = soundLink.broadcastEvents().listen(received.add);
    platform.broadcastStream.add(<Object?, Object?>{
      'status': 'focusLost',
      'outputRoute': 'builtInSpeaker',
      'timestampMilliseconds': 1000,
    });
    await Future<void>.delayed(Duration.zero);
    expect(received.single.status, SoundLinkBroadcastStatus.focusLost);
    await subscription.cancel();
  });

  test('listen rejects duplicate channel ids', () {
    expect(() => soundLink.listen(channels: [direct, direct]), throwsArgumentError);
  });
}
