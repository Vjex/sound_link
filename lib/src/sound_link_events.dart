import 'dart:typed_data';

import 'sound_link_channel.dart';

sealed class SoundLinkEvent {
  const SoundLinkEvent({required this.receivedAt});

  final DateTime receivedAt;
}

class SoundLinkDecoded extends SoundLinkEvent {
  const SoundLinkDecoded({
    required super.receivedAt,
    required this.channel,
    required this.payload,
    required this.snrDb,
    required this.signalDbfs,
    required this.noiseFloorDbfs,
  });

  final SoundLinkChannel channel;
  final Uint8List payload;
  final double snrDb;
  final double signalDbfs;
  final double noiseFloorDbfs;
}

class SoundLinkChannelLevels {
  const SoundLinkChannelLevels({
    required this.channel,
    required this.signalDbfs,
    required this.noiseFloorDbfs,
    required this.snrDb,
  });

  final SoundLinkChannel channel;
  final double signalDbfs;
  final double noiseFloorDbfs;
  final double snrDb;
}

class SoundLinkLevels extends SoundLinkEvent {
  const SoundLinkLevels({
    required super.receivedAt,
    required this.overallDbfs,
    required this.processingLoad,
    required this.channels,
  });

  final double overallDbfs;
  final double processingLoad;
  final List<SoundLinkChannelLevels> channels;
}

enum SoundLinkListenerStatus { listening, interrupted, resumed, routeChanged, focusLost }

enum SoundLinkBroadcastStatus { interrupted, resumed, routeChanged, focusLost, focusGained, stopped }

class SoundLinkBroadcastEvent {
  const SoundLinkBroadcastEvent({required this.status, required this.outputRoute, required this.receivedAt});

  final SoundLinkBroadcastStatus status;
  final String outputRoute;
  final DateTime receivedAt;
}

class SoundLinkListenerState extends SoundLinkEvent {
  const SoundLinkListenerState({
    required super.receivedAt,
    required this.status,
    required this.sampleRate,
    required this.audioSource,
    required this.inputRoute,
  });

  final SoundLinkListenerStatus status;
  final double sampleRate;
  final String audioSource;
  final String inputRoute;
}
