import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sound_link/sound_link.dart';

void main() => runApp(const SoundLinkExampleApp());

class SoundLinkExampleApp extends StatelessWidget {
  const SoundLinkExampleApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: SoundLinkExamplePage());
}

class SoundLinkExamplePage extends StatefulWidget {
  const SoundLinkExamplePage({super.key});

  @override
  State<SoundLinkExamplePage> createState() => _SoundLinkExamplePageState();
}

class _SoundLinkExamplePageState extends State<SoundLinkExamplePage> {
  static const int payloadLength = 16;

  final SoundLink soundLink = SoundLink();
  final TextEditingController messageController = TextEditingController(text: 'hello sound');
  final SoundLinkChannel channel = SoundLinkChannel(
    id: 'demo',
    protocol: SoundLinkProtocol.monoToneFastest,
    startFrequencyHz: 18500,
    payloadLength: payloadLength,
  );

  StreamSubscription<SoundLinkEvent>? listenSubscription;
  bool isBroadcasting = false;
  String status = 'idle';
  String lastMessage = '-';
  SoundLinkChannelLevels? levels;

  Uint8List paddedPayload() {
    final bytes = utf8.encode(messageController.text);
    final padded = Uint8List(payloadLength);
    padded.setRange(0, bytes.length.clamp(0, payloadLength), bytes);
    return padded;
  }

  Future<void> toggleBroadcast() async {
    try {
      if (isBroadcasting) {
        await soundLink.stopBroadcast();
        setState(() => isBroadcasting = false);
        return;
      }
      final info = await soundLink.startBroadcast(channel: channel, payload: paddedPayload());
      setState(() {
        isBroadcasting = true;
        status = 'broadcasting ${info.messageDuration.inMilliseconds} ms per message via ${info.outputRoute}';
      });
    } on SoundLinkException catch (error) {
      setState(() => status = error.toString());
    }
  }

  void toggleListening() {
    if (listenSubscription != null) {
      listenSubscription!.cancel();
      setState(() => listenSubscription = null);
      return;
    }
    final subscription = soundLink.listen(channels: [channel]).listen(
      (event) {
        setState(() {
          if (event is SoundLinkDecoded) {
            final text = utf8.decode(event.payload, allowMalformed: true).replaceAll('\u0000', '');
            lastMessage = '$text (SNR ${event.snrDb.toStringAsFixed(1)} dB)';
          } else if (event is SoundLinkLevels) {
            levels = event.channels.first;
          } else if (event is SoundLinkListenerState) {
            status = '${event.status.name} · ${event.audioSource} · ${event.sampleRate.toStringAsFixed(0)} Hz';
          }
        });
      },
      onError: (Object error) => setState(() => status = error.toString()),
    );
    setState(() => listenSubscription = subscription);
  }

  @override
  void dispose() {
    listenSubscription?.cancel();
    soundLink.stopBroadcast();
    messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentLevels = levels;
    return Scaffold(
      appBar: AppBar(title: const Text('sound_link')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Channel: $channel'),
          const SizedBox(height: 12),
          TextField(
            controller: messageController,
            maxLength: payloadLength,
            decoration: const InputDecoration(labelText: 'Message'),
          ),
          ElevatedButton(onPressed: toggleBroadcast, child: Text(isBroadcasting ? 'Stop broadcast' : 'Broadcast')),
          ElevatedButton(onPressed: toggleListening, child: Text(listenSubscription != null ? 'Stop listening' : 'Listen')),
          const SizedBox(height: 12),
          Text('Status: $status'),
          Text('Last message: $lastMessage'),
          if (currentLevels != null)
            Text(
              'Signal ${currentLevels.signalDbfs.toStringAsFixed(1)} dBFS · '
              'noise ${currentLevels.noiseFloorDbfs.toStringAsFixed(1)} dBFS · '
              'SNR ${currentLevels.snrDb.toStringAsFixed(1)} dB',
            ),
        ],
      ),
    );
  }
}
