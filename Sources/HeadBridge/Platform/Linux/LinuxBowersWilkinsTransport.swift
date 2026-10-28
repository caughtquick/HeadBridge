import Foundation

#if !os(macOS)
@MainActor
final class LinuxBowersWilkinsTransport: BowersWilkinsTransportProtocol {
    var onConnectionStateChange: ((HeadphoneConnectionState) -> Void)?
    var onResponseData: ((Data) -> Void)?
    var onNotificationData: ((Data) -> Void)?
    var onLog: ((TransportLogEntry.Direction, String) -> Void)?

    private(set) var connectionState: HeadphoneConnectionState = .idle
    private(set) var connectedDeviceAddress: String?
    private(set) var connectedDeviceName: String?

    private var requestCharPath: String?
    private var responseCharPath: String?
    private var notificationCharPath: String?

    private var monitorProcess: Process?
    private let runner: LinuxCommandRunner

    init(runner: LinuxCommandRunner = .shared) {
        self.runner = runner
    }

    deinit {
        monitorProcess?.terminate()
    }

    func startScan() {
        onLog?(.outgoing, "Starting Bluetooth LE scan")
        _ = runner.run("bluetoothctl", arguments: ["scan", "on"])
    }

    func stopScan() {
        onLog?(.outgoing, "Stopping Bluetooth LE scan")
        _ = runner.run("bluetoothctl", arguments: ["scan", "off"])
    }

    func connect(address: String, name: String) {
        guard connectionState != .ready && connectionState != .connecting else { return }

        transition(to: .connecting)
        connectedDeviceAddress = address
        connectedDeviceName = name
        onLog?(.outgoing, "Connecting to \(name) (\(address)) via BlueZ GATT")

        // Format device path: EC:66:D1:BE:1D:80 -> dev_EC_66_D1_BE_1D_80
        let macSegment = address.replacingOccurrences(of: ":", with: "_").uppercased()

        // 1. Resolve GATT characteristics via BlueZ ObjectManager
        guard resolveCharacteristics(macSegment: macSegment) else {
            // Attempt to connect device if not connected yet
            _ = runner.run("bluetoothctl", arguments: ["connect", address])
            Thread.sleep(forTimeInterval: 0.5)

            guard resolveCharacteristics(macSegment: macSegment) else {
                onLog?(.incoming, "Failed to resolve Bowers & Wilkins GATT characteristics for \(address)")
                transition(to: .idle)
                return
            }
            return
        }

        enableNotificationsAndStartMonitoring()
    }

    private func resolveCharacteristics(macSegment: String) -> Bool {
        guard let result = runner.run("busctl", arguments: ["call", "--json=short", "org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects"]),
              result.exitCode == 0,
              let jsonData = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let payload = json["data"] as? [[String: Any]],
              let objects = payload.first else {
            return false
        }

        let requestUUID = BWRPC.requestUUID.lowercased()
        let responseUUID = BWRPC.responseUUID.lowercased()
        let notificationUUID = BWRPC.notificationUUID.lowercased()

        for (path, val) in objects {
            guard path.contains("dev_\(macSegment)") else { continue }
            guard let interfaces = val as? [String: Any],
                  let gattChar = interfaces["org.bluez.GattCharacteristic1"] as? [String: Any],
                  let uuidObj = gattChar["UUID"] as? [String: Any],
                  let uuid = (uuidObj["data"] as? String)?.lowercased() else {
                continue
            }

            if uuid == requestUUID {
                requestCharPath = path
            } else if uuid == responseUUID {
                responseCharPath = path
            } else if uuid == notificationUUID {
                notificationCharPath = path
            }
        }

        return requestCharPath != nil && responseCharPath != nil
    }

    private func enableNotificationsAndStartMonitoring() {
        if let respPath = responseCharPath {
            _ = runner.run("busctl", arguments: ["call", "org.bluez", respPath, "org.bluez.GattCharacteristic1", "StartNotify"])
            onLog?(.outgoing, "Enabled notifications on response characteristic: \(respPath)")
        }

        if let notifPath = notificationCharPath {
            _ = runner.run("busctl", arguments: ["call", "org.bluez", notifPath, "org.bluez.GattCharacteristic1", "StartNotify"])
            onLog?(.outgoing, "Enabled notifications on notification characteristic: \(notifPath)")
        }

        startBusMonitor()
        transition(to: .ready)
        onLog?(.incoming, "Connected to Bowers & Wilkins device via BlueZ GATT")
    }

    private func startBusMonitor() {
        monitorProcess?.terminate()
        monitorProcess = nil

        let respPath = responseCharPath
        let notifPath = notificationCharPath

        monitorProcess = runner.spawn("busctl", arguments: ["--system", "monitor", "--json=short", "org.bluez"]) { [weak self] line in
            guard let self else { return }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let member = json["member"] as? String, member == "PropertiesChanged",
                  let path = json["path"] as? String else {
                return
            }

            guard path == respPath || path == notifPath else { return }

            guard let payloadArray = json["data"] as? [Any],
                  payloadArray.count >= 2,
                  let changedProps = payloadArray[1] as? [String: Any],
                  let valueObj = changedProps["Value"] as? [String: Any],
                  let rawBytes = valueObj["data"] as? [NSNumber] else {
                return
            }

            let bytes = rawBytes.map { UInt8(truncating: $0) }
            let packetData = Data(bytes)

            DispatchQueue.main.async {
                if path == respPath {
                    self.onLog?(.incoming, "BWRPC response: \(packetData.map { String(format: "%02X", $0) }.joined(separator: " "))")
                    self.onResponseData?(packetData)
                } else if path == notifPath {
                    self.onLog?(.incoming, "BWRPC notification: \(packetData.map { String(format: "%02X", $0) }.joined(separator: " "))")
                    self.onNotificationData?(packetData)
                }
            }
        }
    }

    func disconnect() {
        monitorProcess?.terminate()
        monitorProcess = nil

        if let respPath = responseCharPath {
            _ = runner.run("busctl", arguments: ["call", "org.bluez", respPath, "org.bluez.GattCharacteristic1", "StopNotify"])
        }
        if let notifPath = notificationCharPath {
            _ = runner.run("busctl", arguments: ["call", "org.bluez", notifPath, "org.bluez.GattCharacteristic1", "StopNotify"])
        }

        requestCharPath = nil
        responseCharPath = nil
        notificationCharPath = nil
        connectedDeviceAddress = nil
        connectedDeviceName = nil

        transition(to: .idle)
        onLog?(.incoming, "Disconnected from Bowers & Wilkins device")
    }

    func writeRequest(_ data: Data) -> Bool {
        guard let reqPath = requestCharPath else {
            onLog?(.incoming, "Cannot write BWRPC request: request characteristic not resolved")
            return false
        }

        var args = ["call", "org.bluez", reqPath, "org.bluez.GattCharacteristic1", "WriteValue", "aya{sv}", "\(data.count)"]
        for byte in data {
            args.append("\(byte)")
        }
        args.append("0") // empty options dict count

        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        onLog?(.outgoing, "BWRPC request: \(hex)")

        guard let result = runner.run("busctl", arguments: args), result.exitCode == 0 else {
            onLog?(.incoming, "Failed to write BWRPC request to \(reqPath)")
            return false
        }
        return true
    }

    private func transition(to state: HeadphoneConnectionState) {
        guard connectionState != state else { return }
        connectionState = state
        onConnectionStateChange?(state)
    }

    // Testing helper for simulating incoming data
    func simulateResponse(_ data: Data) {
        onResponseData?(data)
    }

    func simulateNotification(_ data: Data) {
        onNotificationData?(data)
    }

    func simulateStateChange(_ state: HeadphoneConnectionState) {
        transition(to: state)
    }
}
#endif
