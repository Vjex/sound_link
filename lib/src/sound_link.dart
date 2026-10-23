import 'dart:async';
import 'dart:typed_data';

import 'sound_link_channel.dart';
import 'sound_link_events.dart';
import 'sound_link_models.dart';
import 'sound_link_platform.dart';

class SoundLink {
  SoundLink({SoundLinkPlatform? platform}) : _platform = platform ?? SoundLinkPlatform.instance;

  final SoundLinkPlatform _platform;
  SoundLinkChannel? _broadcastChannel;

  SoundLinkChannel? get broadcastChannel => _broadcastChannel;

  Future<SoundLinkCapabilities> checkCapabilities() async =>
      SoundLinkCapabilities.fromMap(await _platform.checkCapabilities());

  Future<SoundLinkReadiness> checkReadiness() async => SoundLinkReadiness.fromMap(await _platform.checkReadiness());

  Future<double> setMediaVolume(double fraction) {
    if (fraction < 0 || fraction > 1) {
      throw RangeError.range(fraction, 0, 1, 'fraction');
    }
    return _platform.setMediaVolume(fraction);
  }

  Stream<SoundLinkBroadcastEvent> broadcastEvents() => _platform.broadcastEvents().map(
        (event) => SoundLinkBroadcastEvent(
          status: SoundLinkBroadcastStatus.values.byName(event['status'] as String),
          outputRoute: event['outputRoute'] as String? ?? 'unknown',
          receivedAt: DateTime.fromMillisecondsSinceEpoch((event['timestampMilliseconds'] as num).toInt()),
        ),
      );

  Future<SoundLinkBroadcastInfo> startBroadcast({
    required SoundLinkChannel channel,
    required Uint8List payload,
    double volume = 0.6,
    Duration gap = const Duration(milliseconds: 300),
  }) async {
    _validatePayload(channel, payload);
    if (volume < 0 || volume > 1) {
      throw RangeError.range(volume, 0, 1, 'volume');
    }
    if (gap.isNegative) {
      throw ArgumentError.value(gap, 'gap', 'must not be negative');
    }
    final info = SoundLinkBroadcastInfo.fromMap(
      await _platform.startBroadcast(channel: channel, payload: payload, volume: volume, gap: gap),
    );
    _broadcastChannel = channel;
    return info;
  }

  Future<SoundLinkBroadcastInfo> updateBroadcastPayload(Uint8List payload) async {
    final channel = _broadcastChannel;
    if (channel == null) {
      throw const SoundLinkException(SoundLinkException.notBroadcasting, 'startBroadcast must be called first');
    }
    _validatePayload(channel, payload);
    return SoundLinkBroadcastInfo.fromMap(await _platform.updateBroadcastPayload(payload));
  }

  Future<void> stopBroadcast() async {
    _broadcastChannel = null;
    await _platform.stopBroadcast();
  }

  Stream<SoundLinkEvent> listen({
    required List<SoundLinkChannel> channels,
    Duration levelInterval = const Duration(milliseconds: 100),
    SoundLinkAndroidAudioSource androidAudioSource = SoundLinkAndroidAudioSource.automatic,
  }) {
    if (channels.isEmpty) {
      throw ArgumentError.value(channels, 'channels', 'must not be empty');
    }
    final ids = channels.map((channel) => channel.id).toSet();
    if (ids.length != channels.length) {
      throw ArgumentError.value(channels, 'channels', 'ids must be unique');
    }
    return _platform
        .listen(channels: channels, levelInterval: levelInterval, androidAudioSource: androidAudioSource)
        .map((event) => _toEvent(event, channels))
        .where((event) => event != null)
        .cast<SoundLinkEvent>();
  }

  void _validatePayload(SoundLinkChannel channel, Uint8List payload) {
    final expectedLength = channel.payloadLength;
    if (expectedLength != null && payload.length != expectedLength) {
      throw ArgumentError.value(payload.length, 'payload.length', 'channel ${channel.id} expects $expectedLength bytes');
    }
    if (payload.isEmpty || payload.length > channel.maxPayloadLength) {
      throw RangeError.range(payload.length, 1, channel.maxPayloadLength, 'payload.length');
    }
  }

  SoundLinkEvent? _toEvent(Map<Object?, Object?> event, List<SoundLinkChannel> channels) {
    final receivedAt = DateTime.fromMillisecondsSinceEpoch((event['timestampMilliseconds'] as num).toInt());
    switch (event['type']) {
      case 'decoded':
        return SoundLinkDecoded(
          receivedAt: receivedAt,
          channel: channels[(event['channelIndex'] as num).toInt()],
          payload: event['payload'] as Uint8List,
          snrDb: (event['snrDb'] as num).toDouble(),
          signalDbfs: (event['signalDbfs'] as num).toDouble(),
          noiseFloorDbfs: (event['noiseFloorDbfs'] as num).toDouble(),
        );
      case 'levels':
        final channelLevels = (event['channels'] as List<Object?>).cast<Map<Object?, Object?>>();
        return SoundLinkLevels(
          receivedAt: receivedAt,
          overallDbfs: (event['overallDbfs'] as num).toDouble(),
          processingLoad: (event['processingLoad'] as num?)?.toDouble() ?? 0,
          channels: [
            for (final levels in channelLevels)
              SoundLinkChannelLevels(
                channel: channels[(levels['channelIndex'] as num).toInt()],
                signalDbfs: (levels['signalDbfs'] as num).toDouble(),
                noiseFloorDbfs: (levels['noiseFloorDbfs'] as num).toDouble(),
                snrDb: (levels['snrDb'] as num).toDouble(),
              ),
          ],
        );
      case 'state':
        return SoundLinkListenerState(
          receivedAt: receivedAt,
          status: SoundLinkListenerStatus.values.byName(event['status'] as String),
          sampleRate: (event['sampleRate'] as num?)?.toDouble() ?? 0,
          audioSource: event['audioSource'] as String? ?? 'unknown',
          inputRoute: event['inputRoute'] as String? ?? 'unknown',
        );
      default:
        return null;
    }
  }
}
