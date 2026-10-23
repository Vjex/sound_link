enum SoundLinkPermission { granted, denied, undetermined, restricted }

enum SoundLinkAudioRoute { builtIn, wired, bluetooth, other, unknown }

class SoundLinkReadiness {
  const SoundLinkReadiness({
    required this.microphonePermission,
    required this.inCall,
    required this.otherAudioPlaying,
    required this.inputRoute,
    required this.outputRoute,
    required this.mediaVolume,
    required this.canSetMediaVolume,
  });

  factory SoundLinkReadiness.fromMap(Map<Object?, Object?> map) => SoundLinkReadiness(
        microphonePermission:
            SoundLinkPermission.values.byName(map['microphonePermission'] as String? ?? 'undetermined'),
        inCall: map['inCall'] as bool? ?? false,
        otherAudioPlaying: map['otherAudioPlaying'] as bool?,
        inputRoute: SoundLinkAudioRoute.values.byName(map['inputRoute'] as String? ?? 'unknown'),
        outputRoute: SoundLinkAudioRoute.values.byName(map['outputRoute'] as String? ?? 'unknown'),
        mediaVolume: (map['mediaVolume'] as num?)?.toDouble() ?? 0,
        canSetMediaVolume: map['canSetMediaVolume'] as bool? ?? false,
      );

  final SoundLinkPermission microphonePermission;
  final bool inCall;
  final bool? otherAudioPlaying;
  final SoundLinkAudioRoute inputRoute;
  final SoundLinkAudioRoute outputRoute;
  final double mediaVolume;
  final bool canSetMediaVolume;

  Map<String, Object?> toJson() => <String, Object?>{
        'microphonePermission': microphonePermission.name,
        'inCall': inCall,
        'otherAudioPlaying': otherAudioPlaying,
        'inputRoute': inputRoute.name,
        'outputRoute': outputRoute.name,
        'mediaVolume': mediaVolume,
        'canSetMediaVolume': canSetMediaVolume,
      };
}

enum SoundLinkAndroidAudioSource { automatic, unprocessed, voiceRecognition, microphone }

class SoundLinkCapabilities {
  const SoundLinkCapabilities({
    required this.platform,
    required this.deviceModel,
    required this.osVersion,
    required this.outputSampleRate,
    required this.inputSampleRate,
    required this.unprocessedMicrophoneSupported,
    required this.microphonePermission,
    required this.mediaVolume,
    required this.outputRoute,
    required this.inputRoute,
  });

  factory SoundLinkCapabilities.fromMap(Map<Object?, Object?> map) => SoundLinkCapabilities(
        platform: map['platform'] as String? ?? 'unknown',
        deviceModel: map['deviceModel'] as String? ?? 'unknown',
        osVersion: map['osVersion'] as String? ?? 'unknown',
        outputSampleRate: (map['outputSampleRate'] as num?)?.toDouble() ?? 0,
        inputSampleRate: (map['inputSampleRate'] as num?)?.toDouble() ?? 0,
        unprocessedMicrophoneSupported: map['unprocessedMicrophoneSupported'] as bool?,
        microphonePermission: SoundLinkPermission.values.byName(map['microphonePermission'] as String? ?? 'undetermined'),
        mediaVolume: (map['mediaVolume'] as num?)?.toDouble() ?? 0,
        outputRoute: map['outputRoute'] as String? ?? 'unknown',
        inputRoute: map['inputRoute'] as String? ?? 'unknown',
      );

  final String platform;
  final String deviceModel;
  final String osVersion;
  final double outputSampleRate;
  final double inputSampleRate;
  final bool? unprocessedMicrophoneSupported;
  final SoundLinkPermission microphonePermission;
  final double mediaVolume;
  final String outputRoute;
  final String inputRoute;

  Map<String, Object?> toJson() => <String, Object?>{
        'platform': platform,
        'deviceModel': deviceModel,
        'osVersion': osVersion,
        'outputSampleRate': outputSampleRate,
        'inputSampleRate': inputSampleRate,
        'unprocessedMicrophoneSupported': unprocessedMicrophoneSupported,
        'microphonePermission': microphonePermission.name,
        'mediaVolume': mediaVolume,
        'outputRoute': outputRoute,
        'inputRoute': inputRoute,
      };
}

class SoundLinkBroadcastInfo {
  const SoundLinkBroadcastInfo({
    required this.sampleRate,
    required this.messageDuration,
    required this.loopDuration,
    required this.outputRoute,
  });

  factory SoundLinkBroadcastInfo.fromMap(Map<Object?, Object?> map) {
    final sampleRate = (map['sampleRate'] as num).toDouble();
    final messageSamples = (map['messageSamples'] as num).toInt();
    final loopSamples = (map['loopSamples'] as num).toInt();
    return SoundLinkBroadcastInfo(
      sampleRate: sampleRate,
      messageDuration: Duration(microseconds: (messageSamples * 1000000 / sampleRate).round()),
      loopDuration: Duration(microseconds: (loopSamples * 1000000 / sampleRate).round()),
      outputRoute: map['outputRoute'] as String? ?? 'unknown',
    );
  }

  final double sampleRate;
  final Duration messageDuration;
  final Duration loopDuration;
  final String outputRoute;
}

class SoundLinkException implements Exception {
  const SoundLinkException(this.code, this.message);

  static const String microphonePermissionDenied = 'microphone_permission_denied';
  static const String microphoneRestricted = 'microphone_restricted';
  static const String microphoneBlockedBySystem = 'microphone_blocked_by_system';
  static const String microphoneInUse = 'microphone_in_use';
  static const String microphoneSilent = 'microphone_silent';
  static const String microphoneUnavailable = 'microphone_unavailable';
  static const String inCall = 'in_call';
  static const String speakerUnavailable = 'speaker_unavailable';
  static const String unsupported = 'unsupported';
  static const String invalidArguments = 'invalid_arguments';
  static const String encodeFailed = 'encode_failed';
  static const String notBroadcasting = 'not_broadcasting';

  final String code;
  final String message;

  @override
  String toString() => 'SoundLinkException($code): $message';
}
