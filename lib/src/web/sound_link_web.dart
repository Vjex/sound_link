import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import '../sound_link_channel.dart';
import '../sound_link_models.dart';
import '../sound_link_platform.dart';

@JS('createSoundLinkCore')
external JSPromise<_SoundLinkCoreModule> _createSoundLinkCore();

extension type _SoundLinkCoreModule._(JSObject _) implements JSObject {
  @JS('HEAPU8')
  external _TypedArray get heapU8;

  @JS('HEAPF32')
  external _TypedArray get heapF32;

  @JS('HEAP16')
  external _TypedArray get heap16;

  @JS('HEAP32')
  external _TypedArray get heap32;

  @JS('_slw_encode')
  external int encode(
    int protocolId,
    int startBin,
    int payloadLength,
    int checksum,
    int payloadPointer,
    int length,
    double volume,
    double outputSampleRate,
    int outputPointerPointer,
  );

  @JS('_slw_receiver_create')
  external int receiverCreate(double inputSampleRate, int flattenedPointer, int channelCount);

  @JS('_slw_receiver_destroy')
  external void receiverDestroy(int receiver);

  @JS('_slw_receiver_process')
  external int receiverProcess(int receiver, int samplesPointer, int count);

  @JS('_slw_receiver_take_decoded')
  external int receiverTakeDecoded(int receiver, int packedPointer);

  @JS('_slw_receiver_take_levels')
  external int receiverTakeLevels(int receiver, int channelIndex, int outputPointer);

  @JS('_slw_receiver_take_overall_dbfs')
  external double receiverTakeOverallDbfs(int receiver);

  @JS('_slw_malloc')
  external int malloc(int bytes);

  @JS('_slw_free')
  external void free(int pointer);
}

extension type _TypedArray._(JSObject _) implements JSObject {
  external void set(JSObject source, int offset);
  external JSObject slice(int begin, int end);
}

const String _coreAssetKey = 'packages/sound_link/assets/web/sound_link_core.js';
const String _captureProcessorName = 'sound-link-capture';
const String _captureProcessorSource = '''
class SoundLinkCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buffer = new Float32Array(2048);
    this.fill = 0;
  }
  process(inputs) {
    const input = inputs[0];
    if (input && input[0]) {
      const channel = input[0];
      for (let index = 0; index < channel.length; index++) {
        this.buffer[this.fill++] = channel[index];
        if (this.fill === this.buffer.length) {
          this.port.postMessage(this.buffer.slice(0));
          this.fill = 0;
        }
      }
    }
    return true;
  }
}
registerProcessor('$_captureProcessorName', SoundLinkCapture);
''';
const int _packedDecodedBytes = 20 + 256;

class SoundLinkWeb extends SoundLinkPlatform {
  static void registerWith(Registrar registrar) {
    SoundLinkPlatform.instance = SoundLinkWeb();
  }

  _SoundLinkCoreModule? _core;
  Future<_SoundLinkCoreModule>? _coreLoading;
  web.AudioContext? _context;
  bool _captureModuleLoaded = false;

  web.AudioBufferSourceNode? _broadcastSource;
  SoundLinkChannel? _broadcastChannel;
  double _broadcastVolume = 0.6;
  int _broadcastGapMilliseconds = 300;
  final StreamController<Map<Object?, Object?>> _broadcastEvents =
      StreamController<Map<Object?, Object?>>.broadcast();

  web.MediaStream? _microphone;
  web.AudioWorkletNode? _captureNode;
  web.GainNode? _silentSink;
  int _receiver = 0;

  @override
  Future<Map<Object?, Object?>> checkCapabilities() async => <Object?, Object?>{
        'platform': 'web',
        'deviceModel': web.window.navigator.userAgent,
        'osVersion': web.window.navigator.platform,
        'outputSampleRate': _context?.sampleRate ?? 0,
        'inputSampleRate': _context?.sampleRate ?? 0,
        'unprocessedMicrophoneSupported': null,
        'microphonePermission': await _microphonePermission(),
        'mediaVolume': 0,
        'outputRoute': 'browser',
        'inputRoute': 'browser',
      };

  @override
  Future<Map<Object?, Object?>> checkReadiness() async => <Object?, Object?>{
        'microphonePermission': await _microphonePermission(),
        'inCall': false,
        'otherAudioPlaying': null,
        'inputRoute': 'unknown',
        'outputRoute': 'unknown',
        'mediaVolume': 0,
        'canSetMediaVolume': false,
      };

  @override
  Future<double> setMediaVolume(double fraction) async =>
      throw const SoundLinkException(SoundLinkException.unsupported, 'Browsers do not allow pages to change the system volume');

  @override
  Stream<Map<Object?, Object?>> broadcastEvents() => _broadcastEvents.stream;

  @override
  Future<Map<Object?, Object?>> startBroadcast({
    required SoundLinkChannel channel,
    required Uint8List payload,
    required double volume,
    required Duration gap,
  }) async {
    await stopBroadcast();
    _broadcastChannel = channel;
    _broadcastVolume = volume;
    _broadcastGapMilliseconds = gap.inMilliseconds;
    return _playLoop(payload);
  }

  @override
  Future<Map<Object?, Object?>> updateBroadcastPayload(Uint8List payload) async {
    if (_broadcastChannel == null) {
      throw const SoundLinkException(SoundLinkException.notBroadcasting, 'No broadcast is running');
    }
    return _playLoop(payload);
  }

  @override
  Future<void> stopBroadcast() async {
    _broadcastSource?.stop();
    _broadcastSource?.disconnect();
    _broadcastSource = null;
    _broadcastChannel = null;
  }

  @override
  Stream<Map<Object?, Object?>> listen({
    required List<SoundLinkChannel> channels,
    required Duration levelInterval,
    required SoundLinkAndroidAudioSource androidAudioSource,
  }) {
    late final StreamController<Map<Object?, Object?>> controller;
    controller = StreamController<Map<Object?, Object?>>(
      onListen: () => _startListening(controller, channels, levelInterval),
      onCancel: _stopListening,
    );
    return controller.stream;
  }

  Future<Map<Object?, Object?>> _playLoop(Uint8List payload) async {
    final channel = _broadcastChannel!;
    final core = await _loadCore();
    final context = await _audioContext();
    final sampleRate = context.sampleRate;
    final samples = _encode(core, channel, payload, _broadcastVolume, sampleRate);
    final gapSamples = (_broadcastGapMilliseconds * sampleRate / 1000).round();
    final buffer = context.createBuffer(1, samples.length + gapSamples, sampleRate);
    final floats = Float32List(samples.length + gapSamples);
    for (var index = 0; index < samples.length; index++) {
      floats[index] = samples[index] / 32768.0;
    }
    buffer.copyToChannel(floats.toJS, 0);
    final source = context.createBufferSource()
      ..buffer = buffer
      ..loop = true;
    source.connect(context.destination);
    _broadcastSource?.stop();
    _broadcastSource?.disconnect();
    source.start();
    _broadcastSource = source;
    return <Object?, Object?>{
      'sampleRate': sampleRate,
      'messageSamples': samples.length,
      'loopSamples': samples.length + gapSamples,
      'outputRoute': 'browser',
    };
  }

  Int16List _encode(_SoundLinkCoreModule core, SoundLinkChannel channel, Uint8List payload, double volume, double sampleRate) {
    final payloadPointer = core.malloc(payload.length);
    final outputPointerPointer = core.malloc(4);
    try {
      core.heapU8.set(payload.toJS, payloadPointer);
      final map = channel.toMap();
      final count = core.encode(
        map['protocolId']! as int,
        map['startBin']! as int,
        map['payloadLength']! as int,
        (map['checksum']! as bool) ? 1 : 0,
        payloadPointer,
        payload.length,
        volume,
        sampleRate,
        outputPointerPointer,
      );
      if (count <= 0) {
        throw SoundLinkException(SoundLinkException.encodeFailed, 'Payload could not be encoded ($count)');
      }
      final outputPointer = (core.heap32.slice(outputPointerPointer >> 2, (outputPointerPointer >> 2) + 1) as JSInt32Array).toDart[0];
      final samples = Int16List.fromList(
        (core.heap16.slice(outputPointer >> 1, (outputPointer >> 1) + count) as JSInt16Array).toDart,
      );
      core.free(outputPointer);
      return samples;
    } finally {
      core.free(payloadPointer);
      core.free(outputPointerPointer);
    }
  }

  Future<void> _startListening(
    StreamController<Map<Object?, Object?>> controller,
    List<SoundLinkChannel> channels,
    Duration levelInterval,
  ) async {
    try {
      final mediaDevices = web.window.navigator.getProperty<JSObject?>('mediaDevices'.toJS);
      if (mediaDevices == null) {
        throw const SoundLinkException(
          SoundLinkException.microphoneUnavailable,
          'The microphone needs a secure (https) page',
        );
      }
      _microphone = await _openMicrophone();
      final core = await _loadCore();
      final context = await _audioContext();
      if (!_captureModuleLoaded) {
        final blob = web.Blob(
          <JSAny>[_captureProcessorSource.toJS].toJS,
          web.BlobPropertyBag(type: 'application/javascript'),
        );
        final moduleUrl = web.URL.createObjectURL(blob);
        await context.audioWorklet.addModule(moduleUrl).toDart;
        web.URL.revokeObjectURL(moduleUrl);
        _captureModuleLoaded = true;
      }

      final sampleRate = context.sampleRate;
      _receiver = _createReceiver(core, channels, sampleRate);
      if (_receiver == 0) {
        throw const SoundLinkException(SoundLinkException.invalidArguments, 'Receiver could not be created');
      }

      final source = context.createMediaStreamSource(_microphone!);
      final captureNode = web.AudioWorkletNode(context, _captureProcessorName);
      final silentSink = context.createGain()..gain.value = 0;
      source.connect(captureNode);
      captureNode.connect(silentSink);
      silentSink.connect(context.destination);
      _captureNode = captureNode;
      _silentSink = silentSink;

      final trackLabel = _microphone!.getAudioTracks().toDart.firstOrNull?.label ?? 'browser';
      controller.add(<Object?, Object?>{
        'type': 'state',
        'timestampMilliseconds': DateTime.now().millisecondsSinceEpoch,
        'status': 'listening',
        'sampleRate': sampleRate,
        'audioSource': 'browser',
        'inputRoute': trackLabel,
      });

      final samplesPointer = core.malloc(2048 * 4);
      final packedPointer = core.malloc(_packedDecodedBytes);
      final levelsPointer = core.malloc(12);
      final receiver = _receiver;
      var lastLevelsAt = DateTime.now();
      var processingMicroseconds = 0;
      var processedSamples = 0;
      var silenceCheckedSamples = 0;
      var heardSound = false;
      var silenceChecked = false;
      final stopwatch = Stopwatch();

      captureNode.port.onmessage = (web.MessageEvent event) {
        if (_receiver != receiver || controller.isClosed) return;
        final block = (event.data! as JSFloat32Array).toDart;
        if (!silenceChecked) {
          for (final sample in block) {
            if (sample != 0) {
              heardSound = true;
              break;
            }
          }
          silenceCheckedSamples += block.length;
          if (silenceCheckedSamples >= sampleRate) {
            silenceChecked = true;
            if (!heardSound) {
              controller.addError(const SoundLinkException(
                SoundLinkException.microphoneSilent,
                'The microphone delivers only silence',
              ));
              return;
            }
          }
        }
        stopwatch
          ..reset()
          ..start();
        core.heapF32.set(block.toJS, samplesPointer >> 2);
        final decodedCount = core.receiverProcess(receiver, samplesPointer, block.length);
        if (decodedCount > 0) {
          while (true) {
            final packedLength = core.receiverTakeDecoded(receiver, packedPointer);
            if (packedLength <= 0) break;
            final packed = (core.heapU8.slice(packedPointer, packedPointer + packedLength) as JSUint8Array).toDart;
            final view = ByteData.sublistView(packed);
            final payloadLength = view.getInt32(16, Endian.little);
            controller.add(<Object?, Object?>{
              'type': 'decoded',
              'timestampMilliseconds': DateTime.now().millisecondsSinceEpoch,
              'channelIndex': view.getInt32(0, Endian.little),
              'snrDb': view.getFloat32(4, Endian.little),
              'signalDbfs': view.getFloat32(8, Endian.little),
              'noiseFloorDbfs': view.getFloat32(12, Endian.little),
              'payload': Uint8List.fromList(packed.sublist(20, 20 + payloadLength)),
            });
          }
        }
        stopwatch.stop();
        processingMicroseconds += stopwatch.elapsedMicroseconds;
        processedSamples += block.length;

        final now = DateTime.now();
        if (now.difference(lastLevelsAt) < levelInterval) return;
        lastLevelsAt = now;
        final channelLevels = <Map<Object?, Object?>>[];
        for (var channelIndex = 0; channelIndex < channels.length; channelIndex++) {
          if (core.receiverTakeLevels(receiver, channelIndex, levelsPointer) == 0) continue;
          final levels = (core.heapF32.slice(levelsPointer >> 2, (levelsPointer >> 2) + 3) as JSFloat32Array).toDart;
          channelLevels.add(<Object?, Object?>{
            'channelIndex': channelIndex,
            'signalDbfs': levels[0],
            'noiseFloorDbfs': levels[1],
            'snrDb': levels[2],
          });
        }
        final audioMicroseconds = processedSamples * 1000000 / sampleRate;
        final processingLoad = audioMicroseconds > 0 ? processingMicroseconds / audioMicroseconds : 0.0;
        processingMicroseconds = 0;
        processedSamples = 0;
        if (channelLevels.isEmpty) return;
        controller.add(<Object?, Object?>{
          'type': 'levels',
          'timestampMilliseconds': now.millisecondsSinceEpoch,
          'overallDbfs': core.receiverTakeOverallDbfs(receiver),
          'processingLoad': processingLoad,
          'channels': channelLevels,
        });
      }.toJS;
    } on SoundLinkException catch (error) {
      controller.addError(error);
      await _stopListening();
    } catch (error) {
      controller.addError(_mapBrowserError(error));
      await _stopListening();
    }
  }

  Future<void> _stopListening() async {
    _captureNode?.port.onmessage = null;
    _captureNode?.disconnect();
    _silentSink?.disconnect();
    _captureNode = null;
    _silentSink = null;
    final microphone = _microphone;
    if (microphone != null) {
      for (final track in microphone.getTracks().toDart) {
        track.stop();
      }
    }
    _microphone = null;
    final core = _core;
    if (core != null && _receiver != 0) {
      core.receiverDestroy(_receiver);
    }
    _receiver = 0;
  }

  int _createReceiver(_SoundLinkCoreModule core, List<SoundLinkChannel> channels, double sampleRate) {
    final flattened = Int32List(channels.length * 4);
    for (var index = 0; index < channels.length; index++) {
      final map = channels[index].toMap();
      flattened[index * 4] = map['protocolId']! as int;
      flattened[index * 4 + 1] = map['startBin']! as int;
      flattened[index * 4 + 2] = map['payloadLength']! as int;
      flattened[index * 4 + 3] = (map['checksum']! as bool) ? 1 : 0;
    }
    final pointer = core.malloc(flattened.lengthInBytes);
    try {
      core.heap32.set(flattened.toJS, pointer >> 2);
      return core.receiverCreate(sampleRate, pointer, channels.length);
    } finally {
      core.free(pointer);
    }
  }

  Future<web.MediaStream> _openMicrophone() async {
    try {
      return await _requestMicrophone();
    } catch (error) {
      throw _mapMicrophoneError(error);
    }
  }

  Future<web.MediaStream> _requestMicrophone() async {
    final constraints = <String, Object?>{
      'audio': <String, Object?>{
        'echoCancellation': false,
        'noiseSuppression': false,
        'autoGainControl': false,
        'channelCount': 1,
      },
    }.jsify()! as web.MediaStreamConstraints;
    return web.window.navigator.mediaDevices.getUserMedia(constraints).toDart;
  }

  SoundLinkException _mapMicrophoneError(Object error) {
    final description = error.toString();
    if (description.contains('by system')) {
      return SoundLinkException(SoundLinkException.microphoneBlockedBySystem, description);
    }
    if (description.contains('NotAllowedError') || description.contains('SecurityError')) {
      return SoundLinkException(SoundLinkException.microphonePermissionDenied, description);
    }
    if (description.contains('NotReadableError') || description.contains('AbortError')) {
      return SoundLinkException(SoundLinkException.microphoneInUse, description);
    }
    return SoundLinkException(SoundLinkException.microphoneUnavailable, description);
  }

  SoundLinkException _mapBrowserError(Object error) =>
      SoundLinkException(SoundLinkException.microphoneUnavailable, error.toString());

  Future<String> _microphonePermission() async {
    try {
      final permissions = web.window.navigator.permissions;
      final status = await permissions
          .query(<String, Object?>{'name': 'microphone'}.jsify()! as JSObject)
          .toDart;
      switch (status.state) {
        case 'granted':
          return 'granted';
        case 'denied':
          return 'denied';
        default:
          return 'undetermined';
      }
    } catch (_) {
      return 'undetermined';
    }
  }

  Future<web.AudioContext> _audioContext() async {
    final context = _context ??= web.AudioContext();
    if (context.state == 'suspended') {
      await context.resume().toDart;
    }
    return context;
  }

  Future<_SoundLinkCoreModule> _loadCore() {
    final loaded = _core;
    if (loaded != null) return Future.value(loaded);
    return _coreLoading ??= () async {
      if (!globalContext.has('createSoundLinkCore')) {
        final script = web.HTMLScriptElement()..src = ui_web.assetManager.getAssetUrl(_coreAssetKey);
        final loadedCompleter = Completer<void>();
        script.onload = ((web.Event _) => loadedCompleter.complete()).toJS;
        script.onerror = ((web.Event _) => loadedCompleter.completeError(
              const SoundLinkException(SoundLinkException.unsupported, 'The sound engine could not be loaded'),
            )).toJS;
        web.document.head!.append(script);
        await loadedCompleter.future;
      }
      final core = await _createSoundLinkCore().toDart;
      _core = core;
      return core;
    }();
  }
}
