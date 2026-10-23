import AVFoundation
import CallKit
import Foundation

struct SoundLinkError: Error {
    let code: String
    let message: String
}

final class SoundLinkAudioEngine {
    private struct BroadcastState {
        let channel: SLChannelConfig
        let volume: Float
        let gapMilliseconds: Int
        var payload: Data
    }

    private struct ListenState {
        let channels: [SLChannelConfig]
        let levelIntervalMilliseconds: Int
    }

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var receiver: SLCoreReceiver?
    private var broadcast: BroadcastState?
    private var listen: ListenState?
    private var outputSampleRate: Double = 48000
    private var inputSampleRate: Double = 48000
    private var lastLevelsUptime: TimeInterval = 0
    private var processingSeconds: Double = 0
    private var processedSeconds: Double = 0
    private var tapInstalled = false
    private var lastMessageSamples = 0
    private var lastLoopSamples = 0
    private var observers: [NSObjectProtocol] = []
    private let encodingQueue = DispatchQueue(label: "sound_link.encode", qos: .userInitiated)

    var emit: (([String: Any]) -> Void)?
    var fail: ((SoundLinkError) -> Void)?
    var emitBroadcast: ((String) -> Void)?
    private let callObserver = CXCallObserver()
    private var silenceCheckSeconds: Double = 0
    private var heardSound = false
    private var silenceChecked = false

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            try? self?.rebuild()
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func startBroadcast(channel: SLChannelConfig, payload: Data, volume: Float, gapMilliseconds: Int) throws -> [String: Any] {
        broadcast = BroadcastState(channel: channel, volume: volume, gapMilliseconds: gapMilliseconds, payload: payload)
        do {
            try rebuild()
        } catch {
            broadcast = nil
            try? rebuild()
            throw error
        }
        return try broadcastInfo()
    }

    func updateBroadcast(payload: Data, completion: @escaping (Result<[String: Any], SoundLinkError>) -> Void) {
        guard var state = broadcast, player != nil else {
            completion(.failure(SoundLinkError(code: "not_broadcasting", message: "No broadcast is running")))
            return
        }
        state.payload = payload
        let sampleRate = outputSampleRate
        encodingQueue.async { [weak self] in
            let built = Result { try SoundLinkAudioEngine.makeLoopBuffer(for: state, sampleRate: sampleRate) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch built {
                case .success(let loop):
                    guard let player = self.player, self.broadcast != nil, self.outputSampleRate == sampleRate else {
                        completion(.failure(SoundLinkError(code: "not_broadcasting", message: "Broadcast changed while encoding")))
                        return
                    }
                    self.broadcast = state
                    self.lastMessageSamples = loop.messageSamples
                    self.lastLoopSamples = loop.totalSamples
                    player.scheduleBuffer(loop.buffer, at: nil, options: [.loops, .interruptsAtLoop], completionHandler: nil)
                    completion(Result { try self.broadcastInfo() }.mapError { error in
                        error as? SoundLinkError ?? SoundLinkError(code: "encode_failed", message: error.localizedDescription)
                    })
                case .failure(let error):
                    completion(.failure(error as? SoundLinkError ?? SoundLinkError(code: "encode_failed", message: error.localizedDescription)))
                }
            }
        }
    }

    func stopBroadcast() {
        guard broadcast != nil else { return }
        broadcast = nil
        try? rebuild()
    }

    func startListening(channels: [SLChannelConfig], levelIntervalMilliseconds: Int) throws {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
            throw SoundLinkError(code: "microphone_restricted", message: "Microphone access is restricted on this device")
        }
        if isInCall() {
            throw SoundLinkError(code: "in_call", message: "A phone or VoIP call is using the microphone")
        }
        silenceCheckSeconds = 0
        heardSound = false
        silenceChecked = false
        listen = ListenState(channels: channels, levelIntervalMilliseconds: levelIntervalMilliseconds)
        do {
            try rebuild()
        } catch {
            listen = nil
            try? rebuild()
            throw error
        }
        emitState("listening")
    }

    func stopListening() {
        guard listen != nil else { return }
        listen = nil
        try? rebuild()
    }

    func capabilities() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        return [
            "platform": "ios",
            "deviceModel": SoundLinkAudioEngine.machineIdentifier(),
            "osVersion": "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "outputSampleRate": session.sampleRate,
            "inputSampleRate": session.sampleRate,
            "microphonePermission": SoundLinkAudioEngine.microphonePermission(),
            "mediaVolume": Double(session.outputVolume),
            "outputRoute": session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","),
            "inputRoute": session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ","),
        ]
    }

    func readiness() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        return [
            "microphonePermission": SoundLinkAudioEngine.readinessPermission(),
            "inCall": isInCall(),
            "otherAudioPlaying": session.isOtherAudioPlaying,
            "inputRoute": SoundLinkAudioEngine.routeKind(session.currentRoute.inputs),
            "outputRoute": SoundLinkAudioEngine.routeKind(session.currentRoute.outputs),
            "mediaVolume": Double(session.outputVolume),
            "canSetMediaVolume": false,
        ]
    }

    func isInCall() -> Bool {
        callObserver.calls.contains { call in !call.hasEnded }
    }

    private static func readinessPermission() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "undetermined"
        }
    }

    private static func routeKind(_ ports: [AVAudioSessionPortDescription]) -> String {
        let types = ports.map { port in port.portType }
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        let wired: Set<AVAudioSession.Port> = [.headphones, .headsetMic, .usbAudio, .lineOut, .lineIn]
        let builtIn: Set<AVAudioSession.Port> = [.builtInSpeaker, .builtInReceiver, .builtInMic]
        if types.contains(where: { bluetooth.contains($0) }) { return "bluetooth" }
        if types.contains(where: { wired.contains($0) }) { return "wired" }
        if types.contains(where: { builtIn.contains($0) }) { return "builtIn" }
        return types.isEmpty ? "unknown" : "other"
    }

    static func microphonePermission() -> String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        default: return "undetermined"
        }
    }

    private func rebuild() throws {
        tearDownEngine()
        let session = AVAudioSession.sharedInstance()

        guard broadcast != nil || listen != nil else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        if listen != nil {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try? session.setPreferredSampleRate(48000)
            try session.setActive(true)
            try? session.overrideOutputAudioPort(.speaker)
            if let builtInMicrophone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtInMicrophone)
            }
        } else {
            try session.setCategory(.playback, mode: .default, options: [])
            try? session.setPreferredSampleRate(48000)
            try session.setActive(true)
        }

        let audioEngine = AVAudioEngine()
        outputSampleRate = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        if outputSampleRate <= 0 {
            outputSampleRate = session.sampleRate
        }

        var playerNode: AVAudioPlayerNode?
        var initialBuffer: AVAudioPCMBuffer?
        if let state = broadcast {
            let node = AVAudioPlayerNode()
            audioEngine.attach(node)
            let buffer = try loopBuffer(for: state)
            audioEngine.connect(node, to: audioEngine.mainMixerNode, format: buffer.format)
            playerNode = node
            initialBuffer = buffer
        }

        if let state = listen {
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw SoundLinkError(code: "microphone_unavailable", message: "No microphone input is available")
            }
            guard let coreReceiver = SLCoreReceiver(inputSampleRate: inputFormat.sampleRate, channels: state.channels) else {
                throw SoundLinkError(code: "invalid_arguments", message: "Receiver could not be created for these channels")
            }
            inputSampleRate = inputFormat.sampleRate
            receiver = coreReceiver
            lastLevelsUptime = ProcessInfo.processInfo.systemUptime
            let channelCount = state.channels.count
            let interval = Double(state.levelIntervalMilliseconds) / 1000.0
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.process(buffer: buffer, receiver: coreReceiver, channelCount: channelCount, interval: interval)
            }
            tapInstalled = true
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw SoundLinkError(code: listen != nil ? "microphone_unavailable" : "speaker_unavailable",
                                 message: error.localizedDescription)
        }

        if let node = playerNode, let buffer = initialBuffer {
            node.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            node.play()
        }

        engine = audioEngine
        player = playerNode
    }

    private func tearDownEngine() {
        if let audioEngine = engine {
            if tapInstalled {
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            player?.stop()
            audioEngine.stop()
        }
        tapInstalled = false
        engine = nil
        player = nil
        receiver = nil
    }

    private func loopBuffer(for state: BroadcastState) throws -> AVAudioPCMBuffer {
        let loop = try SoundLinkAudioEngine.makeLoopBuffer(for: state, sampleRate: outputSampleRate)
        lastMessageSamples = loop.messageSamples
        lastLoopSamples = loop.totalSamples
        return loop.buffer
    }

    private static func makeLoopBuffer(
        for state: BroadcastState, sampleRate outputSampleRate: Double
    ) throws -> (buffer: AVAudioPCMBuffer, messageSamples: Int, totalSamples: Int) {
        guard let encoded = SLCoreBridge.encodeChannel(
            state.channel, payload: state.payload, volume: state.volume, outputSampleRate: outputSampleRate
        ) else {
            throw SoundLinkError(code: "encode_failed", message: "Payload could not be encoded for this channel")
        }
        let messageSamples = encoded.count / MemoryLayout<Int16>.size
        let gapSamples = max(0, state.gapMilliseconds) * Int(outputSampleRate) / 1000
        let totalSamples = messageSamples + gapSamples
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalSamples)),
              let destination = buffer.floatChannelData?[0] else {
            throw SoundLinkError(code: "speaker_unavailable", message: "Playback buffer could not be created")
        }
        encoded.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<messageSamples {
                destination[index] = Float(samples[index]) / 32768.0
            }
        }
        for index in messageSamples..<totalSamples {
            destination[index] = 0
        }
        buffer.frameLength = AVAudioFrameCount(totalSamples)
        return (buffer, messageSamples, totalSamples)
    }

    private func broadcastInfo() throws -> [String: Any] {
        guard broadcast != nil else {
            throw SoundLinkError(code: "not_broadcasting", message: "No broadcast is running")
        }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }
        return [
            "sampleRate": outputSampleRate,
            "messageSamples": lastMessageSamples,
            "loopSamples": lastLoopSamples,
            "outputRoute": outputs.joined(separator: ","),
        ]
    }

    private func process(buffer: AVAudioPCMBuffer, receiver coreReceiver: SLCoreReceiver, channelCount: Int, interval: Double) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        var events: [[String: Any]] = []
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let processingStartedAt = DispatchTime.now().uptimeNanoseconds
        let decodedCount = coreReceiver.processSamples(samples, count: Int(buffer.frameLength))
        processingSeconds += Double(DispatchTime.now().uptimeNanoseconds - processingStartedAt) / 1_000_000_000
        processedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        if !silenceChecked {
            for index in 0..<Int(buffer.frameLength) where samples[index] != 0 {
                heardSound = true
                break
            }
            silenceCheckSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            if silenceCheckSeconds >= 1 {
                silenceChecked = true
                if !heardSound {
                    DispatchQueue.main.async { [weak self] in
                        self?.fail?(SoundLinkError(code: "microphone_silent", message: "The microphone delivers only silence"))
                    }
                }
            }
        }
        if decodedCount > 0 {
            while let decoded = coreReceiver.takeDecoded() {
                events.append([
                    "type": "decoded",
                    "timestampMilliseconds": timestamp,
                    "channelIndex": decoded.channelIndex,
                    "payload": decoded.payload,
                    "snrDb": Double(decoded.snrDb),
                    "signalDbfs": Double(decoded.signalDbfs),
                    "noiseFloorDbfs": Double(decoded.noiseFloorDbfs),
                ])
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelsUptime >= interval {
            lastLevelsUptime = now
            var channelLevels: [[String: Any]] = []
            for channelIndex in 0..<channelCount {
                if let levels = coreReceiver.takeLevels(forChannel: channelIndex) {
                    channelLevels.append([
                        "channelIndex": channelIndex,
                        "signalDbfs": levels[0].doubleValue,
                        "noiseFloorDbfs": levels[1].doubleValue,
                        "snrDb": levels[2].doubleValue,
                    ])
                }
            }
            let processingLoad = processedSeconds > 0 ? processingSeconds / processedSeconds : 0
            processingSeconds = 0
            processedSeconds = 0
            if !channelLevels.isEmpty {
                events.append([
                    "type": "levels",
                    "timestampMilliseconds": timestamp,
                    "overallDbfs": Double(coreReceiver.takeOverallDbfs()),
                    "processingLoad": processingLoad,
                    "channels": channelLevels,
                ])
            }
        }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.receiver === coreReceiver else { return }
            events.forEach { self.emit?($0) }
        }
    }

    private func emitState(_ status: String) {
        guard listen != nil else { return }
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.portType.rawValue }
        emit?([
            "type": "state",
            "timestampMilliseconds": Int(Date().timeIntervalSince1970 * 1000),
            "status": status,
            "sampleRate": inputSampleRate,
            "audioSource": "measurement",
            "inputRoute": inputs.joined(separator: ","),
        ])
    }

    private func handleInterruption(_ notification: Notification) {
        guard broadcast != nil || listen != nil,
              let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            emitState("interrupted")
            if broadcast != nil { emitBroadcast?("interrupted") }
        case .ended:
            do {
                try rebuild()
                emitState("resumed")
                if broadcast != nil { emitBroadcast?("resumed") }
            } catch let error as SoundLinkError {
                fail?(error)
            } catch {
                fail?(SoundLinkError(code: "microphone_unavailable", message: error.localizedDescription))
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard broadcast != nil || listen != nil,
              let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            do {
                try rebuild()
                emitState("routeChanged")
                if broadcast != nil { emitBroadcast?("routeChanged") }
            } catch let error as SoundLinkError {
                fail?(error)
            } catch {
                fail?(SoundLinkError(code: "microphone_unavailable", message: error.localizedDescription))
            }
        default:
            break
        }
    }

    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { identifier, element in
            if let value = element.value as? Int8, value != 0 {
                identifier.append(Character(UnicodeScalar(UInt8(value))))
            }
        }
    }
}
