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
    private var stdinPipe: Pipe?
    private let runner: LinuxCommandRunner

    init(runner: LinuxCommandRunner = .shared) {
        self.runner = runner
    }

    deinit {
        monitorProcess?.terminate()
    }

    func startScan() {
        onLog?(.outgoing, "Starting Bluetooth LE scan")
        _ = runner.run("busctl", arguments: ["call", "--timeout=2", "org.bluez", "/org/bluez/hci0", "org.bluez.Adapter1", "StartDiscovery"])
    }

    func stopScan() {
        onLog?(.outgoing, "Stopping Bluetooth LE scan")
        _ = runner.run("busctl", arguments: ["call", "--timeout=2", "org.bluez", "/org/bluez/hci0", "org.bluez.Adapter1", "StopDiscovery"])
    }

    func connect(address: String, name: String) {
        guard connectionState != .ready && connectionState != .connecting else { return }

        transition(to: .connecting)
        connectedDeviceAddress = address
        connectedDeviceName = name
        onLog?(.outgoing, "Connecting to \(name) (\(address)) via BlueZ GATT")

        let macSegment = address.replacingOccurrences(of: ":", with: "_").uppercased()

        // 1. Resolve GATT characteristics via BlueZ ObjectManager
        if !resolveCharacteristics(macSegment: macSegment) {
            connectCompanionLEDevice()
            _ = resolveCharacteristics(macSegment: macSegment)
        }

        guard requestCharPath != nil && responseCharPath != nil else {
            onLog?(.incoming, "Failed to resolve Bowers & Wilkins GATT characteristics for \(address)")
            transition(to: .idle)
            return
        }

        enableNotificationsAndStartMonitoring()
    }

    private func connectCompanionLEDevice() {
        guard let result = runner.run("busctl", arguments: ["call", "--json=short", "org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects"]),
              result.exitCode == 0,
              let jsonData = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let payload = json["data"] as? [[String: Any]],
              let objects = payload.first else {
            return
        }

        var leDevicePath: String?
        for (path, val) in objects {
            guard let interfaces = val as? [String: Any],
                  let dev = interfaces["org.bluez.Device1"] as? [String: Any] else {
                continue
            }
            let devName = (dev["Name"] as? [String: Any])?["data"] as? String
                ?? (dev["Alias"] as? [String: Any])?["data"] as? String
                ?? ""
            if devName == "LE_BWHP" || devName.contains("BW") {
                leDevicePath = path
                break
            }
        }

        // If not found in current inventory, run brief discovery scan
        if leDevicePath == nil {
            _ = runner.run("busctl", arguments: ["call", "--timeout=2", "org.bluez", "/org/bluez/hci0", "org.bluez.Adapter1", "StartDiscovery"])
            Thread.sleep(forTimeInterval: 2.0)
            _ = runner.run("busctl", arguments: ["call", "--timeout=2", "org.bluez", "/org/bluez/hci0", "org.bluez.Adapter1", "StopDiscovery"])

            if let postScan = runner.run("busctl", arguments: ["call", "--json=short", "org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects"]),
               let postData = postScan.stdout.data(using: .utf8),
               let postJson = try? JSONSerialization.jsonObject(with: postData) as? [String: Any],
               let postPayload = postJson["data"] as? [[String: Any]],
               let postObjects = postPayload.first {
                for (path, val) in postObjects {
                    guard let interfaces = val as? [String: Any],
                          let dev = interfaces["org.bluez.Device1"] as? [String: Any] else { continue }
                    let devName = (dev["Name"] as? [String: Any])?["data"] as? String
                        ?? (dev["Alias"] as? [String: Any])?["data"] as? String
                        ?? ""
                    if devName == "LE_BWHP" || devName.contains("BW") {
                        leDevicePath = path
                        break
                    }
                }
            }
        }

        if let lePath = leDevicePath {
            _ = runner.run("busctl", arguments: ["set-property", "org.bluez", lePath, "org.bluez.Device1", "Trusted", "b", "true"])
            _ = runner.run("busctl", arguments: ["--timeout=3", "call", "org.bluez", lePath, "org.bluez.Device1", "Connect"], timeout: 3.5)
            // Wait for services to resolve
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.15)
                if let isResolved = runner.run("busctl", arguments: ["get-property", "org.bluez", lePath, "org.bluez.Device1", "ServicesResolved"]),
                   isResolved.stdout.contains("true") {
                    break
                }
            }
        }
    }

    private func resolveCharacteristics(macSegment: String? = nil) -> Bool {
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

        requestCharPath = nil
        responseCharPath = nil
        notificationCharPath = nil

        // First pass: match specific device macSegment if provided
        if let macSegment = macSegment {
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
        }

        // Second pass: match companion LE device exposing BWRPC characteristics
        if requestCharPath == nil || responseCharPath == nil {
            for (path, val) in objects {
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
        }

        return requestCharPath != nil && responseCharPath != nil
    }

    private static let gattBridgeScript = """
    import sys, threading
    from gi.repository import Gio, GLib

    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    loop = GLib.MainLoop()

    resp_path = sys.argv[1]
    notif_path = sys.argv[2]
    req_path = sys.argv[3]

    def on_signal(conn, sender, path, iface, signal, params, user_data):
        if path not in (resp_path, notif_path): return
        changed = params.get_child_value(1)
        for i in range(changed.n_children()):
            e = changed.get_child_value(i)
            if e.get_child_value(0).get_string() == 'Value':
                val = list(e.get_child_value(1).get_variant().get_data_as_bytes().get_data())
                hex_str = ''.join(f'{b:02X}' for b in val)
                prefix = 'RESP' if path == resp_path else 'NOTIF'
                print(f'{prefix} {hex_str}')
                sys.stdout.flush()

    bus.signal_subscribe(None, 'org.freedesktop.DBus.Properties', 'PropertiesChanged', None, None, Gio.DBusSignalFlags.NONE, on_signal, None)

    bus.call_sync('org.bluez', resp_path, 'org.bluez.GattCharacteristic1', 'StartNotify', None, None, Gio.DBusCallFlags.NONE, -1, None)
    if notif_path != 'none':
        bus.call_sync('org.bluez', notif_path, 'org.bluez.GattCharacteristic1', 'StartNotify', None, None, Gio.DBusCallFlags.NONE, -1, None)

    def stdin_worker():
        for line in sys.stdin:
            line = line.strip()
            if not line: continue
            if line.startswith('WRITE '):
                raw = bytes.fromhex(line[6:])
                payload = GLib.Variant('(aya{sv})', (list(raw), {}))
                GLib.idle_add(lambda p=payload: bus.call_sync('org.bluez', req_path, 'org.bluez.GattCharacteristic1', 'WriteValue', p, None, Gio.DBusCallFlags.NONE, -1, None))
            elif line == 'QUIT':
                break
        GLib.idle_add(loop.quit)

    t = threading.Thread(target=stdin_worker, daemon=True)
    t.start()

    print('READY')
    sys.stdout.flush()
    loop.run()
    """

    private func enableNotificationsAndStartMonitoring() {
        guard let respPath = responseCharPath, let reqPath = requestCharPath else {
            transition(to: .idle)
            return
        }

        monitorProcess?.terminate()
        monitorProcess = nil
        stdinPipe = nil

        let pipe = Pipe()
        stdinPipe = pipe

        let notifArg = notificationCharPath ?? "none"
        let proc = runner.spawn(
            "python3",
            arguments: ["-u", "-c", Self.gattBridgeScript, respPath, notifArg, reqPath],
            stdinPipe: pipe
        ) { [weak self] line in
            guard let self else { return }
            if line == "READY" {
                DispatchQueue.main.async {
                    self.transition(to: .ready)
                    self.onLog?(.incoming, "Connected to Bowers & Wilkins device via BlueZ GATT")
                }
            } else if line.hasPrefix("RESP ") {
                let hex = String(line.dropFirst(5))
                if let data = Self.parseHex(hex) {
                    DispatchQueue.main.async {
                        self.onLog?(.incoming, "BWRPC response: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
                        self.onResponseData?(data)
                    }
                }
            } else if line.hasPrefix("NOTIF ") {
                let hex = String(line.dropFirst(6))
                if let data = Self.parseHex(hex) {
                    DispatchQueue.main.async {
                        self.onLog?(.incoming, "BWRPC notification: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
                        self.onNotificationData?(data)
                    }
                }
            }
        }

        if proc == nil {
            onLog?(.incoming, "Failed to launch GATT bridge helper")
            transition(to: .idle)
            return
        }

        monitorProcess = proc
    }

    func disconnect() {
        if let stdinPipe = stdinPipe {
            if let quitData = "QUIT\n".data(using: .utf8) {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: quitData)
            }
            self.stdinPipe = nil
        }

        monitorProcess?.terminate()
        monitorProcess = nil

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

        let hexDisplay = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        onLog?(.outgoing, "BWRPC request: \(hexDisplay)")

        if let stdinPipe = stdinPipe {
            let hex = data.map { String(format: "%02X", $0) }.joined()
            let command = "WRITE \(hex)\n"
            if let cmdData = command.data(using: .utf8) {
                do {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: cmdData)
                    return true
                } catch {
                    onLog?(.incoming, "Pipe write failed: \(error.localizedDescription)")
                }
            }
        }

        // Fallback: busctl WriteValue
        var args = ["--timeout=3", "call", "org.bluez", reqPath, "org.bluez.GattCharacteristic1", "WriteValue", "aya{sv}", "\(data.count)"]
        for byte in data {
            args.append("\(byte)")
        }
        args.append("0")

        guard let result = runner.run("busctl", arguments: args, timeout: 3.5), result.exitCode == 0 else {
            onLog?(.incoming, "Failed to write BWRPC request to \(reqPath)")
            return false
        }
        return true
    }

    nonisolated private static func parseHex(_ hex: String) -> Data? {
        let str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard str.count % 2 == 0 else { return nil }
        var data = Data(capacity: str.count / 2)
        var index = str.startIndex
        while index < str.endIndex {
            let nextIndex = str.index(index, offsetBy: 2)
            guard let byte = UInt8(str[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
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
