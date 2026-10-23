import AVFoundation
import Flutter
import UIKit

public class SoundLinkPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let audioEngine = SoundLinkAudioEngine()
    private var eventSink: FlutterEventSink?
    private let broadcastEvents = SoundLinkBroadcastEventHandler()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SoundLinkPlugin()
        let methodChannel = FlutterMethodChannel(name: "sound_link/methods", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        let eventChannel = FlutterEventChannel(name: "sound_link/events", binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance)
        let broadcastEventChannel = FlutterEventChannel(name: "sound_link/broadcast_events", binaryMessenger: registrar.messenger())
        broadcastEventChannel.setStreamHandler(instance.broadcastEvents)
        instance.audioEngine.emitBroadcast = { [weak instance] status in
            instance?.broadcastEvents.send(status: status)
        }
        instance.audioEngine.emit = { [weak instance] event in
            instance?.eventSink?(event)
        }
        instance.audioEngine.fail = { [weak instance] error in
            instance?.eventSink?(FlutterError(code: error.code, message: error.message, details: nil))
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any] ?? [:]
        do {
            switch call.method {
            case "checkCapabilities":
                result(audioEngine.capabilities())
            case "checkReadiness":
                result(audioEngine.readiness())
            case "setMediaVolume":
                result(FlutterError(code: "unsupported", message: "iOS does not allow apps to change the system volume", details: nil))
            case "startBroadcast":
                guard let channelMap = arguments["channel"] as? [String: Any],
                      let channel = SoundLinkPlugin.channelConfig(from: channelMap),
                      let payload = arguments["payload"] as? FlutterStandardTypedData,
                      let volume = arguments["volume"] as? Double,
                      let gap = arguments["gapMilliseconds"] as? Int else {
                    throw SoundLinkError(code: "invalid_arguments", message: "startBroadcast arguments are invalid")
                }
                result(try audioEngine.startBroadcast(channel: channel, payload: payload.data, volume: Float(volume), gapMilliseconds: gap))
            case "updateBroadcastPayload":
                guard let payload = arguments["payload"] as? FlutterStandardTypedData else {
                    throw SoundLinkError(code: "invalid_arguments", message: "payload is required")
                }
                audioEngine.updateBroadcast(payload: payload.data) { outcome in
                    switch outcome {
                    case .success(let info):
                        result(info)
                    case .failure(let error):
                        result(FlutterError(code: error.code, message: error.message, details: nil))
                    }
                }
            case "stopBroadcast":
                audioEngine.stopBroadcast()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        } catch let error as SoundLinkError {
            result(FlutterError(code: error.code, message: error.message, details: nil))
        } catch {
            result(FlutterError(code: "invalid_arguments", message: error.localizedDescription, details: nil))
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        let map = arguments as? [String: Any] ?? [:]
        let channels = (map["channels"] as? [[String: Any]] ?? []).compactMap(SoundLinkPlugin.channelConfig(from:))
        guard !channels.isEmpty else {
            return FlutterError(code: "invalid_arguments", message: "At least one channel is required", details: nil)
        }
        let interval = map["levelIntervalMilliseconds"] as? Int ?? 100
        eventSink = events

        let start: () -> Void = { [weak self] in
            guard let self = self, self.eventSink != nil else { return }
            do {
                try self.audioEngine.startListening(channels: channels, levelIntervalMilliseconds: interval)
            } catch let error as SoundLinkError {
                self.eventSink?(FlutterError(code: error.code, message: error.message, details: nil))
            } catch {
                self.eventSink?(FlutterError(code: "microphone_unavailable", message: error.localizedDescription, details: nil))
            }
        }

        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            start()
        case .denied:
            return FlutterError(code: "microphone_permission_denied", message: "Microphone permission is denied", details: nil)
        default:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        start()
                    } else {
                        events(FlutterError(code: "microphone_permission_denied", message: "Microphone permission is denied", details: nil))
                    }
                }
            }
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        audioEngine.stopListening()
        return nil
    }

    private static func channelConfig(from map: [String: Any]) -> SLChannelConfig? {
        guard let protocolId = map["protocolId"] as? Int,
              let startBin = map["startBin"] as? Int,
              let payloadLength = map["payloadLength"] as? Int,
              let checksum = map["checksum"] as? Bool else { return nil }
        return SLChannelConfig(
            protocolId: Int32(protocolId),
            startBin: Int32(startBin),
            payloadLength: Int32(payloadLength),
            checksum: checksum
        )
    }
}

final class SoundLinkBroadcastEventHandler: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    func send(status: String) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { port in port.portType.rawValue }
        sink?([
            "status": status,
            "outputRoute": outputs.joined(separator: ","),
            "timestampMilliseconds": Int(Date().timeIntervalSince1970 * 1000),
        ])
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}
