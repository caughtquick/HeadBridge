//
// Adapted from podctl (https://github.com/Rockykln/podctl)
// Copyright (c) 2026 pods contributors
// Licensed under the MIT License.
//

#if canImport(Combine)
import Combine
#endif
import Foundation

@MainActor
final class AppleAccessoryProvider: NSObject, HeadphoneProvider, ObservableObject {
    let providerID: String = "apple"
    let vendorName: String = "Apple"

    @Published private(set) var connectedDeviceID: String?
    @Published private(set) var connectionState: HeadphoneConnectionState = .idle
    @Published private(set) var connectedName: String = "AirPods"
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var isCharging: Bool?
    @Published private(set) var codecName: String? = "AAC"
    @Published private(set) var noiseMode: HeadphoneNoiseMode?
    @Published private(set) var restoreOnConnectEnabled: Bool = false

    // Component-specific telemetry
    @Published private(set) var leftBattery: AAPProtocol.BatteryComponent?
    @Published private(set) var rightBattery: AAPProtocol.BatteryComponent?
    @Published private(set) var caseBattery: AAPProtocol.BatteryComponent?
    @Published private(set) var inEarStatus: AAPProtocol.InEarStatus?
    @Published private(set) var conversationAwarenessEnabled: Bool?
    @Published private(set) var earDetectionEnabled: Bool?
    @Published private(set) var modelNumber: String?

    private(set) var appleModel: AppleModel = .unknown

    var capabilities: HeadphoneCapabilities {
        var caps: HeadphoneCapabilities = [.battery, .deviceName]
        let modelCaps = appleModel.capabilities
        if modelCaps.hasANC {
            caps.insert(.noiseControl)
        }
        if modelCaps.hasInEarDetection {
            caps.insert(.wearSensor)
        }
        if modelCaps.hasSpatialAudio {
            caps.insert(.spatialAudio)
        }
        return caps
    }

    var supportedNoiseModes: [HeadphoneNoiseMode] {
        let modelCaps = appleModel.capabilities
        if modelCaps.hasAdaptive {
            return [.off, .ambient, .adaptive, .noiseCancellation]
        } else if modelCaps.hasANC {
            return [.off, .ambient, .noiseCancellation]
        } else {
            return []
        }
    }

    var connectionStatePublisher: AnyPublisher<HeadphoneConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    private let transport: AppleAccessoryTransportProtocol
    private var pairedDevices: [BluetoothPairedDevice] = []

    init(transport: AppleAccessoryTransportProtocol) {
        self.transport = transport
        super.init()
        setupTransportCallbacks()
    }

    private func setupTransportCallbacks() {
        transport.onConnectionStateChange = { [weak self] state in
            guard let self else { return }
            self.connectionState = state
            if state == .ready {
                self.sendHandshake()
            } else if case .failed = state {
                self.resetTelemetry()
            } else if state == .idle {
                self.resetTelemetry()
            }
        }

        transport.onFrameReceived = { [weak self] frame in
            guard let self else { return }
            self.handleFrame(frame)
        }
    }

    // MARK: - Handshake & Telemetry

    private func sendHandshake() {
        do {
            try transport.send(frame: AAPProtocol.handshakeFrame())
        } catch {
            // Handshake send failed
        }
    }

    private func handleFrame(_ frame: AAPProtocol.Frame) {
        guard let opcode = AAPProtocol.Opcode(rawValue: frame.opcode) else {
            return
        }

        switch opcode {
        case .handshake:
            // Handshake ACK received; subscribe to notifications
            do {
                try transport.send(frame: AAPProtocol.subscribeNotificationsFrame())
            } catch {}

        case .battery:
            let components = AAPProtocol.parseBattery(payload: frame.payload)
            for comp in components {
                switch comp.kind {
                case .left:
                    self.leftBattery = comp
                case .right:
                    self.rightBattery = comp
                case .caseKind:
                    self.caseBattery = comp
                }
            }
            updateAggregateBattery()

        case .earDetection:
            if let inEar = AAPProtocol.parseInEar(payload: frame.payload) {
                self.inEarStatus = inEar
            }

        case .settings:
            if let notice = AAPProtocol.SettingNotice.parse(from: frame), !notice.data.isEmpty {
                handleSettingNotice(id: notice.id, data: notice.data)
            }

        case .metadata:
            if let modelNum = AAPProtocol.parseModelNumber(payload: frame.payload) {
                self.modelNumber = modelNum
            }

        default:
            break
        }
    }

    private func handleSettingNotice(id: UInt8, data: Data) {
        guard let setting = AAPProtocol.SettingID(rawValue: id) else { return }

        switch setting {
        case .noiseControl:
            guard let modeByte = data.first,
                  let listeningMode = AAPProtocol.ListeningMode(rawValue: modeByte) else { return }
            switch listeningMode {
            case .off:
                self.noiseMode = .off
            case .noiseCancellation:
                self.noiseMode = .noiseCancellation
            case .transparency:
                self.noiseMode = .ambient
            case .adaptive:
                self.noiseMode = .adaptive
            }

        case .convAware:
            guard let val = data.first else { return }
            self.conversationAwarenessEnabled = (val == 1)

        case .earDetection:
            guard let val = data.first else { return }
            self.earDetectionEnabled = (val == 1)

        default:
            break
        }
    }

    private func updateAggregateBattery() {
        var levels: [Int] = []
        var charging = false

        if let l = leftBattery, l.status != .disconnected, l.level <= 100 {
            levels.append(Int(l.level))
            if l.status == .charging { charging = true }
        }
        if let r = rightBattery, r.status != .disconnected, r.level <= 100 {
            levels.append(Int(r.level))
            if r.status == .charging { charging = true }
        }

        if !levels.isEmpty {
            // Lowest pod level represents active usable charge
            self.batteryPercent = levels.min()
            self.isCharging = charging
        } else if let c = caseBattery, c.level <= 100 {
            self.batteryPercent = Int(c.level)
            self.isCharging = (c.status == .charging)
        }
    }

    private func resetTelemetry() {
        batteryPercent = nil
        isCharging = nil
        leftBattery = nil
        rightBattery = nil
        caseBattery = nil
        inEarStatus = nil
        noiseMode = nil
        conversationAwarenessEnabled = nil
        earDetectionEnabled = nil
    }

    // MARK: - Device Discovery & Matching

    func recognizesBluetoothDevice(named name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("airpods") { return true }
        if lower.contains("beats fit pro") { return true }
        if lower.contains("beats studio pro") { return true }
        if lower.contains("beats studio buds") { return true }
        if lower.contains("beats solo 4") { return true }
        if lower.contains("beats solo buds") { return true }
        if lower.contains("powerbeats") { return true }
        return false
    }

    func updateBluetoothPairedDevices(_ devices: [BluetoothPairedDevice]) {
        self.pairedDevices = devices
        for dev in devices {
            if recognizesBluetoothDevice(named: dev.name) {
                detectModel(for: dev.address)
            }
        }
    }

    func matches(audioDevice: SystemAudioDevice) -> Bool {
        recognizesBluetoothDevice(named: audioDevice.name)
    }

    func updateAudioConnectedDevices(_ devices: [SystemAudioDevice]) {
        let matched = devices.filter(\.isBluetooth).first(where: { matches(audioDevice: $0) })
        guard let matched else { return }

        if let paired = pairedDevices.first(where: { $0.name == matched.name }) {
            if connectedDeviceID != paired.address || connectionState == .idle {
                connect(to: paired)
            }
        }
    }

    func connect(to device: BluetoothPairedDevice) {
        guard connectionState != .ready, !connectionState.isConnecting else { return }
        connectedDeviceID = device.address
        connectedName = device.name
        detectModel(for: device.address)
        transport.connect(address: device.address, name: device.name)
    }

    private func detectModel(for address: String) {
        if let result = LinuxCommandRunner.shared.run("bluetoothctl", arguments: ["info", address]),
           result.exitCode == 0 {
            for line in result.stdout.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.starts(with: "Modalias:") {
                    let modalias = trimmed.replacingOccurrences(of: "Modalias:", with: "").trimmingCharacters(in: .whitespaces)
                    let detected = AppleModel.from(modalias: modalias)
                    if detected != .unknown {
                        self.appleModel = detected
                    }
                }
            }
        }
    }

    // MARK: - Control Actions

    func refresh() {
        if connectionState == .ready {
            sendHandshake()
        }
    }

    func refreshBatteryStatus() {
        // Handled via periodic unsolicited AAP notifications
    }

    func disconnect() {
        transport.disconnect()
        connectedDeviceID = nil
        resetTelemetry()
    }

    func shutdown() {
        disconnect()
    }

    func setNoiseMode(_ mode: HeadphoneNoiseMode) {
        guard connectionState == .ready else { return }

        let targetMode: AAPProtocol.ListeningMode
        switch mode {
        case .off:
            targetMode = .off
        case .noiseCancellation:
            targetMode = .noiseCancellation
        case .ambient, .windReduction:
            targetMode = .transparency
        case .adaptive:
            targetMode = .adaptive
        }

        do {
            try transport.send(frame: AAPProtocol.setNoiseControl(targetMode))
            self.noiseMode = mode
        } catch {
            // Write failed
        }
    }

    func setConversationAwareness(_ on: Bool) {
        guard connectionState == .ready else { return }
        do {
            try transport.send(frame: AAPProtocol.setConversationAwareness(on))
            self.conversationAwarenessEnabled = on
        } catch {}
    }

    func setEarDetection(_ on: Bool) {
        guard connectionState == .ready else { return }
        do {
            try transport.send(frame: AAPProtocol.setEarDetection(on))
            self.earDetectionEnabled = on
        } catch {}
    }

    func setRestoreOnConnectEnabled(_ enabled: Bool) {
        self.restoreOnConnectEnabled = enabled
    }
}
