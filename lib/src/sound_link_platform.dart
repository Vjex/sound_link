import 'dart:async';

import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'sound_link_channel.dart';
import 'sound_link_models.dart';

abstract class SoundLinkPlatform extends PlatformInterface {
  SoundLinkPlatform() : super(token: _token);

  static final Object _token = Object();

  static SoundLinkPlatform _instance = MethodChannelSoundLink();

  static SoundLinkPlatform get instance => _instance;

  static set instance(SoundLinkPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<Map<Object?, Object?>> checkCapabilities();

  Future<Map<Object?, Object?>> checkReadiness();

  Future<double> setMediaVolume(double fraction);

  Stream<Map<Object?, Object?>> broadcastEvents();

  Future<Map<Object?, Object?>> startBroadcast({
    required SoundLinkChannel channel,
    required Uint8List payload,
    required double volume,
    required Duration gap,
  });

  Future<Map<Object?, Object?>> updateBroadcastPayload(Uint8List payload);

  Future<void> stopBroadcast();

  Stream<Map<Object?, Object?>> listen({
    required List<SoundLinkChannel> channels,
    required Duration levelInterval,
    required SoundLinkAndroidAudioSource androidAudioSource,
  });
}

class MethodChannelSoundLink extends SoundLinkPlatform {
  final MethodChannel _methods = const MethodChannel('sound_link/methods');
  final EventChannel _events = const EventChannel('sound_link/events');
  final EventChannel _broadcastEvents = const EventChannel('sound_link/broadcast_events');

  @override
  Future<Map<Object?, Object?>> checkCapabilities() async =>
      await _invoke<Map<Object?, Object?>>('checkCapabilities') ?? const <Object?, Object?>{};

  @override
  Future<Map<Object?, Object?>> checkReadiness() async =>
      await _invoke<Map<Object?, Object?>>('checkReadiness') ?? const <Object?, Object?>{};

  @override
  Future<double> setMediaVolume(double fraction) async =>
      await _invoke<double>('setMediaVolume', <String, Object?>{'fraction': fraction}) ?? 0;

  @override
  Stream<Map<Object?, Object?>> broadcastEvents() =>
      _broadcastEvents.receiveBroadcastStream().map((event) => event as Map<Object?, Object?>);

  @override
  Future<Map<Object?, Object?>> startBroadcast({
    required SoundLinkChannel channel,
    required Uint8List payload,
    required double volume,
    required Duration gap,
  }) async =>
      await _invoke<Map<Object?, Object?>>('startBroadcast', <String, Object?>{
        'channel': channel.toMap(),
        'payload': payload,
        'volume': volume,
        'gapMilliseconds': gap.inMilliseconds,
      }) ??
      const <Object?, Object?>{};

  @override
  Future<Map<Object?, Object?>> updateBroadcastPayload(Uint8List payload) async =>
      await _invoke<Map<Object?, Object?>>('updateBroadcastPayload', <String, Object?>{'payload': payload}) ??
      const <Object?, Object?>{};

  @override
  Future<void> stopBroadcast() => _invoke<void>('stopBroadcast');

  @override
  Stream<Map<Object?, Object?>> listen({
    required List<SoundLinkChannel> channels,
    required Duration levelInterval,
    required SoundLinkAndroidAudioSource androidAudioSource,
  }) {
    final arguments = <String, Object?>{
      'channels': channels.map((channel) => channel.toMap()).toList(),
      'levelIntervalMilliseconds': levelInterval.inMilliseconds,
      'androidAudioSource': androidAudioSource.name,
    };
    return _events
        .receiveBroadcastStream(arguments)
        .map((event) => event as Map<Object?, Object?>)
        .handleError((Object error, StackTrace stackTrace) {
      if (error is PlatformException) {
        Error.throwWithStackTrace(SoundLinkException(error.code, error.message ?? error.code), stackTrace);
      }
      Error.throwWithStackTrace(error, stackTrace);
    });
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw SoundLinkException(error.code, error.message ?? error.code);
    }
  }
}
