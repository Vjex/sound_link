import 'dart:math' as math;

import 'sound_link_protocol.dart';

class SoundLinkChannel {
  SoundLinkChannel({
    required this.id,
    required this.protocol,
    required this.startFrequencyHz,
    this.payloadLength,
    this.checksum = true,
  }) {
    if (protocol.requiresFixedLength && (payloadLength == null || payloadLength! <= 0)) {
      throw ArgumentError.value(payloadLength, 'payloadLength', '${protocol.name} needs a fixed payloadLength');
    }
    if (payloadLength != null && (payloadLength! <= 0 || payloadLength! > maxPayloadLength)) {
      throw RangeError.range(payloadLength!, 1, maxPayloadLength, 'payloadLength');
    }
    if (startBin < 1 || startBin + protocol.bandBins >= samplesPerFrame ~/ 2) {
      throw RangeError.value(startFrequencyHz, 'startFrequencyHz', 'band must fit below ${operatingSampleRate / 2} Hz');
    }
  }

  static const double operatingSampleRate = 48000;
  static const int samplesPerFrame = 1024;
  static const double hertzPerBin = operatingSampleRate / samplesPerFrame;
  static const int checksumBytes = 4;
  static const int _variableLengthHeaderBytes = 3;
  static const int _markerFrames = 16;
  static const int _maxFixedWireBytes = 64;
  static const int _maxVariableWireBytes = 140;

  final String id;
  final SoundLinkProtocol protocol;
  final double startFrequencyHz;
  final int? payloadLength;
  final bool checksum;

  bool get isFixedLength => payloadLength != null;

  int get startBin => (startFrequencyHz / hertzPerBin).round();

  double get bandStartHz => startBin * hertzPerBin;

  double get bandEndHz => (startBin + protocol.bandBins - 1) * hertzPerBin;

  int get maxPayloadLength =>
      (isFixedLength ? _maxFixedWireBytes : _maxVariableWireBytes) - (checksum ? checksumBytes : 0);

  int messageFrames(int length) {
    final wireBytes = length + (checksum ? checksumBytes : 0);
    if (isFixedLength) {
      final totalBytes = wireBytes + _eccBytes(wireBytes);
      final symbols = (totalBytes + protocol.bytesPerSymbol - 1) ~/ protocol.bytesPerSymbol;
      return protocol.symbolFrameMultiplier * symbols * protocol.framesPerSymbol;
    }
    final totalBytes = wireBytes + _variableLengthHeaderBytes + _eccBytes(wireBytes);
    final symbols = (totalBytes + protocol.bytesPerSymbol - 1) ~/ protocol.bytesPerSymbol;
    return _markerFrames + protocol.symbolFrameMultiplier * symbols * protocol.framesPerSymbol + _markerFrames;
  }

  Duration messageDuration([int? length]) {
    final resolvedLength = payloadLength ?? length;
    if (resolvedLength == null) {
      throw ArgumentError('length is required for variable-length channels');
    }
    final frames = messageFrames(resolvedLength);
    return Duration(microseconds: (frames * samplesPerFrame * 1000000 / operatingSampleRate).round());
  }

  bool overlaps(SoundLinkChannel other) =>
      math.max(startBin, other.startBin) <=
      math.min(startBin + protocol.bandBins - 1, other.startBin + other.protocol.bandBins - 1);

  Map<String, Object?> toMap() => <String, Object?>{
        'protocolId': protocol.nativeId,
        'startBin': startBin,
        'payloadLength': payloadLength ?? 0,
        'checksum': checksum,
      };

  static int _eccBytes(int length) => length < 4 ? 2 : math.max(4, 2 * (length ~/ 5));

  @override
  String toString() =>
      'SoundLinkChannel($id, ${protocol.name}, ${bandStartHz.toStringAsFixed(0)}-${bandEndHz.toStringAsFixed(0)} Hz, '
      '${isFixedLength ? '$payloadLength bytes' : 'variable length'})';
}
