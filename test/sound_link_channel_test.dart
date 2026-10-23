import 'package:flutter_test/flutter_test.dart';
import 'package:sound_link/sound_link.dart';

void main() {
  group('SoundLinkChannel geometry', () {
    test('mono-tone at 18.5 kHz occupies 16 bins below 19.5 kHz', () {
      final channel = SoundLinkChannel(
        id: 'direct',
        protocol: SoundLinkProtocol.monoToneFastest,
        startFrequencyHz: 18500,
        payloadLength: 9,
      );
      expect(channel.startBin, 395);
      expect(channel.bandStartHz, closeTo(18515.6, 0.1));
      expect(channel.bandEndHz, closeTo(19218.8, 0.1));
    });

    test('dual-tone occupies 32 bins', () {
      final channel = SoundLinkChannel(
        id: 'direct',
        protocol: SoundLinkProtocol.dualToneFastest,
        startFrequencyHz: 18500,
      );
      expect(channel.bandEndHz, closeTo(19968.8, 0.1));
    });

    test('overlap detection', () {
      final direct = SoundLinkChannel(
          id: 'direct', protocol: SoundLinkProtocol.monoToneFastest, startFrequencyHz: 18500, payloadLength: 9);
      final relay = SoundLinkChannel(
          id: 'relay', protocol: SoundLinkProtocol.monoToneFastest, startFrequencyHz: 19600, payloadLength: 9);
      final clash = SoundLinkChannel(
          id: 'clash', protocol: SoundLinkProtocol.monoToneFastest, startFrequencyHz: 19000, payloadLength: 9);
      expect(direct.overlaps(relay), isFalse);
      expect(direct.overlaps(clash), isTrue);
    });
  });

  group('SoundLinkChannel airtime matches the native core', () {
    final monoToneFrames = <int, int>{7: 90, 9: 102, 31: 294, 33: 306, 40: 360};
    monoToneFrames.forEach((length, frames) {
      test('mono-tone fastest $length bytes = $frames frames', () {
        final channel = SoundLinkChannel(
          id: 'direct',
          protocol: SoundLinkProtocol.monoToneFastest,
          startFrequencyHz: 18500,
          payloadLength: length,
        );
        expect(channel.messageFrames(length), frames);
      });
    });

    final dualToneFrames = <int, int>{7: 86, 31: 188, 40: 221};
    dualToneFrames.forEach((length, frames) {
      test('dual-tone fastest $length bytes = $frames frames', () {
        final channel = SoundLinkChannel(
          id: 'direct',
          protocol: SoundLinkProtocol.dualToneFastest,
          startFrequencyHz: 18500,
        );
        expect(channel.messageFrames(length), frames);
      });
    });

    test('duration converts frames at 48 kHz / 1024', () {
      final channel = SoundLinkChannel(
        id: 'direct',
        protocol: SoundLinkProtocol.monoToneFastest,
        startFrequencyHz: 18500,
        payloadLength: 7,
      );
      expect(channel.messageDuration().inMilliseconds, 1920);
    });
  });

  group('SoundLinkChannel validation', () {
    test('mono-tone needs a fixed length', () {
      expect(
        () => SoundLinkChannel(id: 'direct', protocol: SoundLinkProtocol.monoToneFastest, startFrequencyHz: 18500),
        throwsArgumentError,
      );
    });

    test('fixed length is limited to 60 bytes with checksum', () {
      expect(
        () => SoundLinkChannel(
          id: 'direct',
          protocol: SoundLinkProtocol.monoToneFastest,
          startFrequencyHz: 18500,
          payloadLength: 61,
        ),
        throwsRangeError,
      );
    });

    test('band must stay below Nyquist', () {
      expect(
        () => SoundLinkChannel(
          id: 'direct',
          protocol: SoundLinkProtocol.monoToneFastest,
          startFrequencyHz: 23500,
          payloadLength: 9,
        ),
        throwsRangeError,
      );
    });
  });
}
