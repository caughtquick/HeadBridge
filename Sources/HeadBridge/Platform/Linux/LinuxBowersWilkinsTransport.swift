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
        let adapter = LinuxBluetoothInventory.findDefaultAdapterPath(runner: runner)
        _ = runner.run("busctl", arguments: ["call", "--timeout=2", "org.bluez", adapter, "org.bluez.Adapter1", "StartDiscovery"])
    }

    func stopScan() {
        onLog?(.outgoing, "Stopping Bluetooth LE scan")
        let adapter = LinuxBluetoothInventory.findDefaultAdapterPath(runner: runner)
        _ = runner.run("busctl", arguments: ["call", "--timeout=2", "org.bluez", adapter, "org.bluez.Adapter1", "StopDiscovery"])
    }

    private let connectionQueue = DispatchQueue(label: "com.headbridge.bw.connection", qos: .userInitiated)
    private var generation: UInt64 = 0

    func connect(address: String, name: String) {
        guard connectionState != .ready && connectionState != .connecting else { return }

        generation &+= 1
        let currentGen = generation

        connectedDeviceAddress = address
        connectedDeviceName = name
        transition(to: .connecting)
        onLog?(.outgoing, "Connecting to \(name) (\(address)) via BlueZ GATT")

        let currentRunner = runner
        connectionQueue.async { [weak self] in
            let macSegment = address.replacingOccurrences(of: ":", with: "_").uppercased()

            var resolved = Self.resolveCharacteristics(macSegment: macSegment, runner: currentRunner)
            if resolved == nil {
                Self.connectCompanionLEDevice(runner: currentRunner)
                resolved = Self.resolveCharacteristics(macSegment: macSegment, runner: currentRunner)
            }

            Task { @MainActor [weak self] in
                guard let self = self, self.generation == currentGen else { return }

                guard let chars = resolved else {
                    self.onLog?(.incoming, "Failed to resolve Bowers & Wilkins GATT characteristics for \(address)")
                    self.transition(to: .idle)
                    return
                }

                self.requestCharPath = chars.requestPath
                self.responseCharPath = chars.responsePath
                self.notificationCharPath = chars.notificationPath
                self.enableNotificationsAndStartMonitoring(generation: currentGen)
            }
        }
    }

    nonisolated private static func connectCompanionLEDevice(runner: LinuxCommandRunner) {
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

        // If not found in current inventory, run brief LE discovery scan
        if leDevicePath == nil {
            let adapter = LinuxBluetoothInventory.findDefaultAdapterPath(runner: runner)
            if let scanResult = runner.run("python3", arguments: ["-c", Self.leScanScript, adapter], timeout: 3.5),
               scanResult.exitCode == 0 {
                let detectedPath = scanResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if detectedPath.hasPrefix("/org/bluez") {
                    leDevicePath = detectedPath
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

    private struct ResolvedCharacteristics: Sendable {
        let requestPath: String
        let responsePath: String
        let notificationPath: String?
    }

    nonisolated private static func resolveCharacteristics(
        macSegment: String? = nil,
        runner: LinuxCommandRunner
    ) -> ResolvedCharacteristics? {
        guard let result = runner.run("busctl", arguments: ["call", "--json=short", "org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects"]),
              result.exitCode == 0,
              let jsonData = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let payload = json["data"] as? [[String: Any]],
              let objects = payload.first else {
            return nil
        }

        let reqUUID = BWRPC.requestUUID.lowercased()
        let respUUID = BWRPC.responseUUID.lowercased()
        let notifUUID = BWRPC.notificationUUID.lowercased()

        var req: String?
        var resp: String?
        var notif: String?

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

                if uuid == reqUUID { req = path }
                else if uuid == respUUID { resp = path }
                else if uuid == notifUUID { notif = path }
            }
        }

        // Second pass: match companion LE device exposing BWRPC characteristics
        if req == nil || resp == nil {
            for (path, val) in objects {
                guard let interfaces = val as? [String: Any],
                      let gattChar = interfaces["org.bluez.GattCharacteristic1"] as? [String: Any],
                      let uuidObj = gattChar["UUID"] as? [String: Any],
                      let uuid = (uuidObj["data"] as? String)?.lowercased() else {
                    continue
                }

                if uuid == reqUUID { req = path }
                else if uuid == respUUID { resp = path }
                else if uuid == notifUUID { notif = path }
            }
        }

        guard let r = req, let s = resp else { return nil }
        return ResolvedCharacteristics(requestPath: r, responsePath: s, notificationPath: notif)
    }

    nonisolated private static let leScanScript = """
    import sys
    from gi.repository import Gio, GLib

    adapter_path = sys.argv[1] if len(sys.argv) > 1 else '/org/bluez/hci0'
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    loop = GLib.MainLoop()

    found = None

    def on_signal(conn, sender, path, iface, signal, params, user_data):
        global found
        if signal == 'InterfacesAdded':
            obj_path = params.get_child_value(0).get_string()
            ifaces = params.get_child_value(1)
            for i in range(ifaces.n_children()):
                entry = ifaces.get_child_value(i)
                if entry.get_child_value(0).get_string() == 'org.bluez.Device1':
                    props = entry.get_child_value(1)
                    for j in range(props.n_children()):
                        p = props.get_child_value(j)
                        p_name = p.get_child_value(0).get_string()
                        if p_name in ('Name', 'Alias'):
                            val = p.get_child_value(1).get_variant().get_string()
                            if 'BW' in val or 'LE_' in val:
                                found = obj_path
                                loop.quit()

    bus.signal_subscribe('org.bluez', 'org.freedesktop.DBus.ObjectManager', 'InterfacesAdded', None, None, Gio.DBusSignalFlags.NONE, on_signal, None)

    try:
        filter_dict = {'Transport': GLib.Variant('s', 'le')}
        bus.call_sync('org.bluez', adapter_path, 'org.bluez.Adapter1', 'SetDiscoveryFilter', GLib.Variant('(a{sv})', [filter_dict]), None, Gio.DBusCallFlags.NONE, 2000)
        bus.call_sync('org.bluez', adapter_path, 'org.bluez.Adapter1', 'StartDiscovery', None, None, Gio.DBusCallFlags.NONE, 2000)
    except:
        pass

    GLib.timeout_add_seconds(2, loop.quit)
    loop.run()

    try:
        bus.call_sync('org.bluez', adapter_path, 'org.bluez.Adapter1', 'StopDiscovery', None, None, Gio.DBusCallFlags.NONE, 2000)
    except:
        pass

    if found:
        print(found)
    """

    nonisolated private static let gattBridgeScript = """
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

    try:
        bus.call_sync('org.bluez', resp_path, 'org.bluez.GattCharacteristic1', 'StartNotify', None, None, Gio.DBusCallFlags.NONE, 2000, None)
    except Exception as e:
        print(f"ERR StartNotify resp error: {e}")
        sys.stdout.flush()

    if notif_path != 'none':
        try:
            bus.call_sync('org.bluez', notif_path, 'org.bluez.GattCharacteristic1', 'StartNotify', None, None, Gio.DBusCallFlags.NONE, 2000, None)
        except Exception as e:
            print(f"ERR StartNotify notif error: {e}")
            sys.stdout.flush()

    def do_write(payload):
        try:
            bus.call_sync('org.bluez', req_path, 'org.bluez.GattCharacteristic1', 'WriteValue', payload, None, Gio.DBusCallFlags.NONE, 2000, None)
        except Exception as e:
            print(f"ERR WriteValue error: {e}")
            sys.stdout.flush()
        return False

    def stdin_worker():
        for line in sys.stdin:
            line = line.strip()
            if not line: continue
            if line.startswith('WRITE '):
                try:
                    raw = bytes.fromhex(line[6:])
                    payload = GLib.Variant('(aya{sv})', (list(raw), {}))
                    GLib.idle_add(do_write, payload)
                except Exception as e:
                    print(f"ERR Write parse error: {e}")
                    sys.stdout.flush()
            elif line == 'QUIT':
                break
        GLib.idle_add(loop.quit)

    t = threading.Thread(target=stdin_worker, daemon=True)
    t.start()

    print('READY')
    sys.stdout.flush()
    loop.run()
    """

    private func enableNotificationsAndStartMonitoring(generation currentGen: UInt64) {
        guard let respPath = responseCharPath, let reqPath = requestCharPath else {
            transition(to: .idle)
            return
        }

        monitorProcess?.terminationHandler = nil
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
            Task { @MainActor in
                guard self.generation == currentGen else { return }
                if line == "READY" {
                    self.transition(to: .ready)
                    self.onLog?(.incoming, "Connected to Bowers & Wilkins device via BlueZ GATT")
                } else if line.hasPrefix("RESP ") {
                    let hex = String(line.dropFirst(5))
                    if let data = Self.parseHex(hex) {
                        self.onLog?(.incoming, "BWRPC response: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
                        self.onResponseData?(data)
                    }
                } else if line.hasPrefix("NOTIF ") {
                    let hex = String(line.dropFirst(6))
                    if let data = Self.parseHex(hex) {
                        self.onLog?(.incoming, "BWRPC notification: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
                        self.onNotificationData?(data)
                    }
                } else if line.hasPrefix("ERR ") {
                    self.onLog?(.incoming, "GATT bridge error: \(line.dropFirst(4))")
                }
            }
        }

        guard let proc = proc else {
            onLog?(.incoming, "Failed to launch GATT bridge helper")
            transition(to: .idle)
            return
        }

        proc.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self = self else { return }
                guard self.generation == currentGen else { return }
                if self.monitorProcess == process {
                    self.monitorProcess = nil
                    self.stdinPipe = nil
                    if self.connectionState != .idle {
                        self.transition(to: .idle)
                        self.onLog?(.incoming, "GATT bridge helper exited (status: \(process.terminationStatus))")
                    }
                }
            }
        }

        monitorProcess = proc
    }

    func disconnect() {
        generation &+= 1
        if let stdinPipe = stdinPipe {
            if let quitData = "QUIT\n".data(using: .utf8) {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: quitData)
            }
            self.stdinPipe = nil
        }

        monitorProcess?.terminationHandler = nil
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
