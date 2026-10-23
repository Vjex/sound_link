# sound_link

Send and receive small data payloads over near-ultrasonic sound on Android and iOS, and measure how strongly each phone hears them.

- One sender reaches every listener in range at once, with no pairing, network or Bluetooth.
- Near-ultrasonic bands (for example 18.5–19.2 kHz) are inaudible to most people and mostly stay inside a room.
- Every message is protected by Reed–Solomon error correction plus a CRC-32 check, so a damaged message is dropped instead of being decoded wrongly.
- Live signal level, noise floor and SNR per channel, plus the SNR of every decoded message.
- Several channels can be heard at the same time (for example a direct band and a relay band).

The modem is [ggwave](https://github.com/ggerganov/ggwave) (MIT), compiled natively for each platform. Audio capture and playback are native: Android uses `AudioRecord` with the `UNPROCESSED` source where available, and iOS uses `AVAudioEngine` in `.measurement` mode, so the operating system's voice processing does not filter the signal.

## Platform setup

**Android** — minSdk 24. Add to the app's `AndroidManifest.xml` if the app listens:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

Request the permission at runtime before calling `listen` (for example with `permission_handler`).

**iOS** — iOS 13+. Add to `Info.plist` if the app listens:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Listens for data sent over sound. Audio is processed on the device and never recorded or uploaded.</string>
```

Broadcasting needs no permission on either platform.

## Usage

```dart
final soundLink = SoundLink();

final channel = SoundLinkChannel(
  id: 'main',
  protocol: SoundLinkProtocol.monoToneFastest,
  startFrequencyHz: 18500,
  payloadLength: 9,
);

await soundLink.startBroadcast(channel: channel, payload: Uint8List.fromList(utf8.encode('123456789')));
await soundLink.stopBroadcast();

final subscription = soundLink.listen(channels: [channel]).listen((event) {
  if (event is SoundLinkDecoded) {
    print('${event.payload} at ${event.snrDb.toStringAsFixed(1)} dB SNR');
  } else if (event is SoundLinkLevels) {
    print('SNR now ${event.channels.first.snrDb.toStringAsFixed(1)} dB');
  }
});
```

`startBroadcast` loops the message with a configurable gap until `stopBroadcast`. `updateBroadcastPayload` swaps the message at the next loop boundary without a gap.

## Readiness and errors

The package reports facts and error codes; it never shows UI or decides what the user should do.

```dart
final readiness = await soundLink.checkReadiness();
readiness.microphonePermission; // granted / denied / undetermined / restricted
readiness.inCall;               // phone or VoIP call active
readiness.otherAudioPlaying;    // another app is playing sound (null if unknown)
readiness.inputRoute;           // builtIn / wired / bluetooth / other / unknown
readiness.outputRoute;
readiness.mediaVolume;          // 0..1
readiness.canSetMediaVolume;    // false on iOS (Apple does not allow it)

await soundLink.setMediaVolume(0.8); // Android only; throws `unsupported` on iOS
```

While listening or broadcasting, the package asks the OS to pause other apps' audio (Android audio focus, iOS exclusive audio session) and forces the built-in microphone and speaker where the OS allows it.

Errors are `SoundLinkException` with a stable `code`:

| Code | Meaning |
|---|---|
| `microphone_permission_denied` | Microphone permission not granted |
| `microphone_restricted` | Microphone blocked by Screen Time / device management (iOS) |
| `microphone_blocked_by_system` | The page is allowed but the operating system blocks the browser from the microphone (web: macOS / Windows privacy settings) |
| `microphone_in_use` | Another app or the system has priority on the microphone |
| `microphone_silent` | The microphone delivered pure silence for 1 s (Android 12+ privacy toggle, hardware) |
| `microphone_unavailable` | The microphone could not be opened |
| `in_call` | A phone or VoIP call is active |
| `speaker_unavailable` | Playback could not start |
| `unsupported` | Not possible on this platform |
| `invalid_arguments`, `encode_failed`, `not_broadcasting` | Programming errors |

Session changes arrive as events: `SoundLinkListenerState` (`listening`, `interrupted`, `resumed`, `routeChanged`, `focusLost`) while listening, and `soundLink.broadcastEvents()` (`interrupted`, `resumed`, `routeChanged`, `focusLost`, `focusGained`, `stopped`) while broadcasting.

## Choosing a protocol

| Protocol | Width | Length | Notes |
|---|---|---|---|
| `monoTone*` | 16 bins (750 Hz) | fixed (`payloadLength` required) | Fits a 1 kHz near-ultrasonic band |
| `dualTone*` | 32 bins (1.5 kHz) | fixed or variable | About 1.5× faster than mono-tone |
| `ultrasound*` | 96 bins (4.5 kHz) | fixed or variable | ggwave's default starts at 15 kHz, which many people can hear |
| `audible*` | 96 bins (4.5 kHz) | fixed or variable | Audible band |

`Normal` / `Fast` / `Fastest` hold each symbol for 9 / 6 / 3 frames of 21.3 ms. Slower is more robust in reverberant rooms. `SoundLinkChannel.messageDuration()` gives the airtime of one message.

All frequencies sit on a 46.875 Hz grid (48 kHz / 1024). Audio is processed at 48 kHz internally, and devices that run at 44.1 kHz are resampled transparently.

## Reading the levels

Phone microphones are not calibrated, so levels are reported in **dBFS** (relative to the microphone's full scale), not dB SPL. The same sound reads differently on different phone models. **SNR** compares the strongest bin in a channel's band with the band's median bin, and is comparable across devices:

- about 6 dB: nothing is being received (the noise baseline)
- 10–15 dB: weak; decoding becomes unreliable
- 20 dB and above: solid

Pick thresholds (for example when to retry or relay) from SNR, measured on real devices in the real room.

## Testing

```sh
flutter test
sh src/tests/run_tests.sh
```

The native test suite covers loopback at 48 and 44.1 kHz, low-frequency noise, clicks, 20–40 dB attenuation, ±1000 ppm clock drift, two simultaneous bands, and checks that noise and corrupted messages never produce a payload.

## Licence

MIT, © Vishal Verma. Includes ggwave (MIT, © Georgi Gerganov) and its Reed–Solomon implementation (MIT, © Mike Lubinets); see `src/ggwave/`.
