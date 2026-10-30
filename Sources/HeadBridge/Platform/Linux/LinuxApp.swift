#if os(Linux)
#if canImport(Glibc)
import Glibc
#endif
#if canImport(Combine)
import Combine
#endif
import Foundation

@main
@MainActor
struct LinuxApp {
    private static var runningServer: LinuxDaemonServer?
    private static var autoConnectCancellable: AnyCancellable?

    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())
        let isJSON = args.contains("--json")
        let isVerbose = args.contains("--verbose") || args.contains("-v")
        let filteredArgs = args.filter { $0 != "--json" && $0 != "--verbose" && $0 != "-v" }
        let subcommand = filteredArgs.first ?? "status"

        if subcommand == "help" || subcommand == "--help" || subcommand == "-h" {
            printHelp()
            return
        }

        // 1. If this is a daemon control command (status/stop/start), handle via IPC client
        if subcommand == "daemon" || subcommand == "monitor" {
            if filteredArgs.contains("status") {
                if LinuxDaemonClient.isDaemonRunning() {
                    print("HeadBridge daemon is running (socket: \(LinuxDaemonClient.defaultSocketPath))")
                    exit(0)
                } else {
                    print("HeadBridge daemon is not running.")
                    exit(1)
                }
            } else if filteredArgs.contains("stop") {
                if let response = LinuxDaemonClient.sendCommand(args: ["daemon", "stop"], isJSON: isJSON) {
                    if !response.output.isEmpty { fputs(response.output, stdout) }
                    exit(response.exitCode)
                } else {
                    print("HeadBridge daemon is not running.")
                    exit(1)
                }
            } else if LinuxDaemonClient.isDaemonRunning() {
                if isJSON {
                    print("{\"running\":true,\"socket\":\"\(LinuxDaemonClient.defaultSocketPath)\"}")
                } else {
                    print("HeadBridge daemon is already running (socket: \(LinuxDaemonClient.defaultSocketPath))")
                }
                exit(0)
            }
        } else {
            // 2. For any other command, check if daemon is running and dispatch via IPC
            if let response = LinuxDaemonClient.sendCommand(args: args, isJSON: isJSON) {
                if !response.output.isEmpty {
                    fputs(response.output, response.exitCode == 0 ? stdout : stderr)
                }
                exit(response.exitCode)
            } else if LinuxDaemonClient.isDaemonRunning() {
                fputs("Warning: Daemon is running but did not respond to IPC request.\n", stderr)
            }
        }

        // 3. Fallback: Standalone execution (daemon not running)
        let audio = LinuxPipeWireAudio()
        let bwTransport = LinuxBowersWilkinsTransport()
        let bwProvider = BowersWilkinsProvider(transport: bwTransport)
        if isVerbose {
            bwTransport.onLog = { dir, msg in
                fputs("[\(dir == .outgoing ? "OUT" : "IN")] \(msg)\n", stderr)
            }
        }

        let sonyTransport = LinuxSonyRFCOMMTransport()
        let sonyClient = SonyV1Client(transport: sonyTransport)
        let sonyProvider = SonyMDRProvider(client: sonyClient)

        let appleTransport = LinuxAppleAccessoryTransport()
        let appleProvider = AppleAccessoryProvider(transport: appleTransport)
        if isVerbose {
            appleTransport.onLog = { dir, msg in
                fputs("[\(dir == .outgoing ? "OUT" : "IN")] [Apple] \(msg)\n", stderr)
            }
        }

        let manager = HeadphoneManager(providers: [bwProvider, sonyProvider, appleProvider])
        manager.installAudioDeviceDiscovery(systemAudio: audio)
        manager.updateAudioConnectedDevices(audio.devices)

        // Populate paired devices synchronously
        if let paired = LinuxBluetoothInventory.fetchPairedDevices() {
            manager.applyBluetoothPairedDevices(paired)
        }
        manager.refreshAll()

        if subcommand == "daemon" || subcommand == "monitor" {
            audio.startMonitoring()
            await handleDaemon(
                manager: manager,
                audio: audio,
                bwTransport: bwTransport,
                bwProvider: bwProvider,
                sonyProvider: sonyProvider,
                appleTransport: appleTransport,
                appleProvider: appleProvider
            )
            return
        }

        let response = await dispatchCommand(
            args: args,
            isJSON: isJSON,
            manager: manager,
            audio: audio,
            bwTransport: bwTransport,
            bwProvider: bwProvider,
            sonyProvider: sonyProvider,
            appleTransport: appleTransport,
            appleProvider: appleProvider
        )

        if !response.output.isEmpty {
            fputs(response.output, response.exitCode == 0 ? stdout : stderr)
        }
        exit(response.exitCode)
    }

    private static func activeProvider(manager: HeadphoneManager) -> (any HeadphoneProvider)? {
        manager.providers.first { $0.connectionState == .ready }
            ?? manager.providers.first { $0.connectionState == .connecting }
    }

    private static func dispatchCommand(
        args: [String],
        isJSON: Bool,
        manager: HeadphoneManager,
        audio: LinuxPipeWireAudio,
        bwTransport: LinuxBowersWilkinsTransport,
        bwProvider: BowersWilkinsProvider,
        sonyProvider: SonyMDRProvider,
        appleTransport: LinuxAppleAccessoryTransport,
        appleProvider: AppleAccessoryProvider
    ) async -> LinuxIPCResponse {
        let filteredArgs = args.filter { $0 != "--json" && $0 != "--verbose" && $0 != "-v" }
        let subcommand = filteredArgs.first ?? "status"

        // Ensure active provider connection if headphone is connected to OS
        let requiresActiveProvider = (subcommand == "status" || subcommand == "anc" || subcommand == "eq" || subcommand == "ambient-level")
        if requiresActiveProvider,
           activeProvider(manager: manager)?.connectionState != .ready,
           let connectedDev = manager.recognizedDevices.first(where: { $0.isConnected }) {
            if connectedDev.providerID == "bowers-wilkins" && bwProvider.connectionState == .idle {
                bwTransport.connect(address: connectedDev.address, name: connectedDev.name)
            } else if connectedDev.providerID == "sony" && sonyProvider.connectionState == .idle {
                sonyProvider.connect(to: BluetoothPairedDevice(id: connectedDev.id, name: connectedDev.name, address: connectedDev.address, isConnected: true, isAudioConnected: true))
            } else if connectedDev.providerID == "apple" && appleProvider.connectionState == .idle {
                appleProvider.connect(to: BluetoothPairedDevice(id: connectedDev.id, name: connectedDev.name, address: connectedDev.address, isConnected: true, isAudioConnected: true))
            }
            for _ in 0..<25 {
                if activeProvider(manager: manager)?.connectionState == .ready { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if activeProvider(manager: manager)?.connectionState == .ready {
                let isSetter = (subcommand == "anc" && filteredArgs.count > 1) ||
                               (subcommand == "eq" && filteredArgs.count > 1)
                if !isSetter {
                    for _ in 0..<30 {
                        if connectedDev.providerID == "apple" {
                            if appleProvider.leftBattery != nil || appleProvider.rightBattery != nil || appleProvider.noiseMode != nil {
                                break
                            }
                        } else if bwProvider.hasConfirmedRead(BWRPCatalog.ancGet) &&
                           (bwProvider.supportsToneControls || bwProvider.hasConfirmedRead(BWRPCatalog.eqGet)) {
                            break
                        }
                        if !bwProvider.hasPendingWrites && connectedDev.providerID != "apple" { break }
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    }
                }
            }
        }

        switch subcommand {
        case "status":
            let res = executeStatus(manager: manager, audio: audio, isJSON: isJSON)
            return LinuxIPCResponse(exitCode: res.exitCode, output: res.output)

        case "devices":
            let res = executeDevices(manager: manager, audio: audio, isJSON: isJSON)
            return LinuxIPCResponse(exitCode: res.exitCode, output: res.output)

        case "connect":
            let target = filteredArgs.count > 1 ? filteredArgs[1] : nil
            let res = await executeConnect(target: target, manager: manager, bwTransport: bwTransport, sonyProvider: sonyProvider, appleProvider: appleProvider, isJSON: isJSON)
            return LinuxIPCResponse(exitCode: res.exitCode, output: res.output)

        case "disconnect":
            let res = executeDisconnect(manager: manager, isJSON: isJSON)
            return LinuxIPCResponse(exitCode: res.exitCode, output: res.output)

        case "anc":
            let modeArg = filteredArgs.count > 1 ? filteredArgs[1] : nil
            let res = await executeANC(modeArg: modeArg, manager: manager, isJSON: isJSON)
            return LinuxIPCResponse(exitCode: res.exitCode, output: res.output)

        case "ambient-level":
            let levelArg = filteredArgs.count > 1 ? Int(filteredArgs[1]) : nil
            let res = executeAmbientLevel(level: levelArg, sonyProvider: sonyProvider, isJSON: isJSON)
            return LinuxIPCResponse(exitCode: res.exitCode, output: res.output)

        case "eq":
            let subArgs = Array(filteredArgs.dropFirst())
            let res = await executeEQ(args: subArgs, bwProvider: bwProvider, isJSON: isJSON)
            return LinuxIPCResponse(exitCode: res.exitCode, output: res.output)

        case "battery":
            let res = executeBattery(manager: manager, isJSON: isJSON)
            return LinuxIPCResponse(exitCode: res.exitCode, output: res.output)

        case "restore":
            let action = filteredArgs.count > 1 ? filteredArgs[1] : "status"
            let res = executeRestore(action: action, manager: manager, isJSON: isJSON)
            return LinuxIPCResponse(exitCode: res.exitCode, output: res.output)

        case "diag":
            let res = executeDiag(manager: manager, audio: audio, isJSON: isJSON)
            return LinuxIPCResponse(exitCode: res.exitCode, output: res.output)

        case "ping":
            return LinuxIPCResponse(exitCode: 0, output: isJSON ? "{\"pong\":true}\n" : "pong\n")

        case "daemon":
            if filteredArgs.contains("stop") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    runningServer?.stop()
                    manager.shutdown()
                    exit(0)
                }
                return LinuxIPCResponse(exitCode: 0, output: isJSON ? "{\"stopped\":true}\n" : "HeadBridge daemon stopped.\n")
            } else {
                return LinuxIPCResponse(exitCode: 0, output: isJSON ? "{\"running\":true}\n" : "HeadBridge daemon is running.\n")
            }

        default:
            let msg = "Unknown command: \(subcommand). Use 'headbridge help' for available commands.\n"
            return LinuxIPCResponse(exitCode: 1, output: msg)
        }
    }

    private static func executeStatus(manager: HeadphoneManager, audio: LinuxPipeWireAudio, isJSON: Bool) -> (output: String, exitCode: Int32) {
        let provider = activeProvider(manager: manager)
        let isConnected = provider?.connectionState == .ready
        let osConnectedDevice = manager.recognizedDevices.first(where: { $0.isConnected })

        if isJSON {
            let activeDevName = provider?.connectedName.isEmpty == false ? provider?.connectedName : osConnectedDevice?.name
            let activeVendor = provider != nil ? provider?.vendorName : osConnectedDevice?.vendorName
            let activeProviderID = provider != nil ? provider?.providerID : osConnectedDevice?.providerID
            let battery = provider?.batteryPercent ?? (osConnectedDevice.flatMap { LinuxBluetoothInventory.shared.fetchBatteryPercentage(for: $0.address) })

            var dict: [String: Any] = [
                "connected": isConnected || osConnectedDevice != nil,
                "connectionState": isConnected ? ((provider?.connectionState.title) ?? "ready") : (osConnectedDevice != nil ? "connected" : "idle"),
                "deviceName": activeDevName ?? "",
                "vendor": activeVendor ?? "",
                "providerID": activeProviderID ?? "",
                "batteryPercent": battery as Any,
                "isCharging": provider?.isCharging as Any,
                "noiseMode": provider?.noiseMode?.rawValue as Any,
                "audioSink": audio.devices.first(where: { $0.id == audio.defaultDeviceID })?.name ?? "",
                "vendorRPCReady": isConnected
            ]
            if let bw = provider as? BowersWilkinsProvider {
                dict["bassLevel"] = bw.bassLevel
                dict["trebleLevel"] = bw.trebleLevel
            } else if let sony = provider as? SonyMDRProvider {
                dict["ambientLevel"] = sony.ambientLevel
            } else if let apple = provider as? AppleAccessoryProvider {
                dict["leftBattery"] = apple.leftBattery?.level
                dict["rightBattery"] = apple.rightBattery?.level
                dict["caseBattery"] = apple.caseBattery?.level
                dict["conversationAwareness"] = apple.conversationAwarenessEnabled
                dict["earDetection"] = apple.earDetectionEnabled
                dict["appleModel"] = apple.appleModel.displayName
            }
            return (jsonString(for: dict), 0)
        }

        var lines: [String] = []
        lines.append("=== HeadBridge Status ===")
        if let provider = provider, isConnected {
            lines.append("Device:        \(provider.connectedName)")
            lines.append("Vendor:        \(provider.vendorName)")
            if let apple = provider as? AppleAccessoryProvider, apple.appleModel != .unknown {
                lines.append("Model:         \(apple.appleModel.displayName)")
            }
            lines.append("State:         \(provider.connectionState.title)")
            let battery = provider.batteryPercent ?? osConnectedDevice.flatMap { LinuxBluetoothInventory.shared.fetchBatteryPercentage(for: $0.address) }
            if let battery = battery {
                let charging = (provider.isCharging ?? false) ? " (Charging)" : ""
                lines.append("Battery:       \(battery)%\(charging)")
            } else {
                lines.append("Battery:       Unknown")
            }
            if let noiseMode = provider.noiseMode {
                lines.append("ANC Mode:      \(noiseModeDescription(noiseMode))")
            }
            if let bw = provider as? BowersWilkinsProvider {
                lines.append("Tone / EQ:     Bass: \(bw.bassLevel), Treble: \(bw.trebleLevel)")
            } else if let sony = provider as? SonyMDRProvider {
                lines.append("Ambient Level: \(sony.ambientLevel)/20")
            } else if let apple = provider as? AppleAccessoryProvider {
                var podParts: [String] = []
                if let l = apple.leftBattery, l.status != .disconnected {
                    podParts.append("L: \(l.level)%\(l.status == .charging ? " ⚡" : "")")
                }
                if let r = apple.rightBattery, r.status != .disconnected {
                    podParts.append("R: \(r.level)%\(r.status == .charging ? " ⚡" : "")")
                }
                if let c = apple.caseBattery, c.status != .disconnected {
                    podParts.append("Case: \(c.level)%\(c.status == .charging ? " ⚡" : "")")
                }
                if !podParts.isEmpty {
                    lines.append("Pods / Case:   \(podParts.joined(separator: "  |  "))")
                }
                if let ca = apple.conversationAwarenessEnabled {
                    lines.append("Conv. Aware:   \(ca ? "On" : "Off")")
                }
            }
            let sinkName = audio.devices.first(where: { $0.id == audio.defaultDeviceID })?.name ?? "Default"
            lines.append("Audio Output:  \(sinkName)")
        } else if let osDev = osConnectedDevice {
            lines.append("Device:        \(osDev.name) (\(osDev.address))")
            lines.append("Vendor:        \(osDev.vendorName)")
            lines.append("State:         Connected (Audio / BlueZ)")
            if let battery = LinuxBluetoothInventory.shared.fetchBatteryPercentage(for: osDev.address) {
                lines.append("Battery:       \(battery)%")
            } else {
                lines.append("Battery:       Unknown")
            }
            let sinkName = audio.devices.first(where: { $0.id == audio.defaultDeviceID })?.name ?? "Default"
            lines.append("Audio Output:  \(sinkName)")
            if osDev.providerID == "apple" {
                lines.append("Vendor RPC:    Disconnected (L2CAP PSM 0x1001 required for ANC/Telemetry)")
            } else if osDev.providerID == "sony" {
                lines.append("Vendor RPC:    Disconnected (RFCOMM required for ANC/EQ controls)")
            } else {
                lines.append("Vendor RPC:    Disconnected (BLE GATT required for ANC/EQ controls)")
            }
        } else {
            lines.append("No supported headphones currently connected.")
            let paired = manager.recognizedDevices
            if !paired.isEmpty {
                lines.append("\nRecognized paired devices:")
                for dev in paired {
                    lines.append("  • \(dev.name) (\(dev.address)) [\(dev.vendorName)]")
                }
                lines.append("\nRun 'headbridge connect <address>' to connect.")
            } else {
                lines.append("No recognized AirPods, Beats, Bowers & Wilkins, or Sony devices found in paired Bluetooth inventory.")
            }
        }
        return (lines.joined(separator: "\n") + "\n", 0)
    }

    private static func executeDevices(manager: HeadphoneManager, audio: LinuxPipeWireAudio, isJSON: Bool) -> (output: String, exitCode: Int32) {
        let paired = manager.recognizedDevices

        if isJSON {
            let list = paired.map { dev -> [String: Any] in
                [
                    "id": dev.id,
                    "address": dev.address,
                    "name": dev.name,
                    "vendor": dev.vendorName,
                    "providerID": dev.providerID,
                    "isConnected": dev.isConnected
                ]
            }
            return (jsonString(for: ["devices": list]), 0)
        }

        var lines: [String] = []
        lines.append("=== Recognized Bluetooth Devices ===")
        if paired.isEmpty {
            lines.append("No supported AirPods, Beats, Bowers & Wilkins, or Sony headphones detected.")
            lines.append("Ensure headphones are paired via bluetoothctl or your desktop settings.")
        } else {
            for dev in paired {
                let status = dev.isConnected ? " [Connected]" : " [Paired]"
                lines.append("  \(dev.address)  \(dev.name)  (\(dev.vendorName))\(status)")
            }
        }
        return (lines.joined(separator: "\n") + "\n", 0)
    }

    private static func executeConnect(
        target: String?,
        manager: HeadphoneManager,
        bwTransport: LinuxBowersWilkinsTransport,
        sonyProvider: SonyMDRProvider,
        appleProvider: AppleAccessoryProvider,
        isJSON: Bool
    ) async -> (output: String, exitCode: Int32) {
        let paired = manager.recognizedDevices
        guard !paired.isEmpty else {
            if isJSON {
                return (jsonString(for: ["error": "No recognized paired devices found"]), 1)
            } else {
                return ("Error: No recognized paired devices found.\n", 1)
            }
        }

        let device: RecognizedHeadphoneDevice
        if let target = target {
            guard let matched = paired.first(where: {
                $0.address.caseInsensitiveCompare(target) == .orderedSame ||
                $0.name.lowercased().contains(target.lowercased())
            }) else {
                if isJSON {
                    return (jsonString(for: ["error": "Device '\(target)' not found in paired list"]), 1)
                } else {
                    return ("Error: Device '\(target)' not found in paired inventory.\n", 1)
                }
            }
            device = matched
        } else {
            device = paired.first!
        }

        if device.providerID == "bowers-wilkins" {
            bwTransport.connect(address: device.address, name: device.name)
        } else if device.providerID == "sony" {
            sonyProvider.connect(to: BluetoothPairedDevice(id: device.id, name: device.name, address: device.address, isConnected: true, isAudioConnected: true))
        } else if device.providerID == "apple" {
            appleProvider.connect(to: BluetoothPairedDevice(id: device.id, name: device.name, address: device.address, isConnected: true, isAudioConnected: true))
        }

        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if activeProvider(manager: manager)?.connectionState == .ready {
                break
            }
        }

        let ready = activeProvider(manager: manager)?.connectionState == .ready
        if isJSON {
            return (jsonString(for: ["success": ready, "device": device.name, "address": device.address, "vendorRPCReady": ready]), ready ? 0 : 1)
        } else {
            if ready {
                return ("Successfully connected to \(device.name) vendor RPC!\n", 0)
            } else {
                var out = "Connecting to \(device.name) (\(device.address))...\n"
                out += "Audio and Battery are connected via BlueZ.\n"
                if device.providerID == "apple" {
                    out += "AirPods L2CAP PSM 0x1001 connection failed. Ensure the AirPods are out of the case, in-ear, and connected to Bluetooth audio.\n"
                } else if device.providerID == "sony" {
                    out += "Sony RFCOMM connection failed. Ensure headphones are connected to Bluetooth audio.\n"
                } else {
                    out += "Vendor GATT RPC control session is not currently active.\n"
                    out += "Bowers & Wilkins headphones broadcast their ANC/EQ GATT controls over their companion BLE interface ('LE_BWHP').\n"
                }
                return (out, 1)
            }
        }
    }

    private static func executeDisconnect(manager: HeadphoneManager, isJSON: Bool) -> (output: String, exitCode: Int32) {
        guard let provider = activeProvider(manager: manager) else {
            if isJSON { return (jsonString(for: ["error": "No active device to disconnect"]), 1) }
            else { return ("No active headphone connection.\n", 1) }
        }

        let name = provider.connectedName
        provider.disconnect()

        if isJSON {
            return (jsonString(for: ["disconnected": true, "device": name]), 0)
        } else {
            return ("Disconnected from \(name).\n", 0)
        }
    }

    private static func executeANC(modeArg: String?, manager: HeadphoneManager, isJSON: Bool) async -> (output: String, exitCode: Int32) {
        guard let provider = activeProvider(manager: manager), provider.connectionState == .ready else {
            if isJSON { return (jsonString(for: ["error": "No headphone connected or session not ready"]), 1) }
            else { return ("Error: No headphone connected or session not ready.\n", 1) }
        }

        guard let modeArg = modeArg else {
            let current = provider.noiseMode
            if isJSON {
                return (jsonString(for: ["ancMode": current?.rawValue as Any, "description": current.map(noiseModeDescription) as Any]), 0)
            } else {
                var out = "Current ANC mode: \(current.map(noiseModeDescription) ?? "Unknown")\n"
                out += "Supported modes: \(provider.supportedNoiseModes.map(noiseModeDescription).joined(separator: ", "))\n"
                return (out, 0)
            }
        }

        let targetMode: HeadphoneNoiseMode?
        switch modeArg.lowercased() {
        case "off":
            targetMode = .off
        case "anc", "cancelling", "noise-cancelling", "cancellation", "noise-cancellation":
            targetMode = .noiseCancellation
        case "ambient", "pass-through", "transparency", "passthrough":
            targetMode = .ambient
        case "wind", "wind-reduction":
            targetMode = .windReduction
        case "adaptive":
            targetMode = .adaptive
        default:
            targetMode = nil
        }

        guard let mode = targetMode else {
            return ("Invalid ANC mode: \(modeArg). Available: off, anc, ambient, adaptive, wind\n", 1)
        }

        guard provider.supportedNoiseModes.contains(mode) else {
            let supported = provider.supportedNoiseModes.map(noiseModeDescription).joined(separator: ", ")
            let err = "Mode '\(modeArg)' is not supported by this device. Supported: \(supported)\n"
            return isJSON ? (jsonString(for: ["error": err.trimmingCharacters(in: .whitespacesAndNewlines)]), 1) : (err, 1)
        }

        provider.setNoiseMode(mode)
        for _ in 0..<25 {
            if let bw = provider as? BowersWilkinsProvider, !bw.isCommandInFlightOrQueued(BWRPCatalog.ancSet) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        if isJSON {
            return (jsonString(for: ["success": true, "ancMode": mode.rawValue, "description": noiseModeDescription(mode)]), 0)
        } else {
            return ("ANC mode set to: \(noiseModeDescription(mode))\n", 0)
        }
    }

    private static func executeAmbientLevel(level: Int?, sonyProvider: SonyMDRProvider, isJSON: Bool) -> (output: String, exitCode: Int32) {
        guard let level = level else {
            let current = sonyProvider.ambientLevel
            if isJSON {
                return (jsonString(for: ["ambientLevel": current]), 0)
            } else {
                return ("Current ambient level: \(current)/20\n", 0)
            }
        }

        let clamped = max(0, min(20, level))
        sonyProvider.setAmbientLevel(clamped)
        if isJSON {
            return (jsonString(for: ["success": true, "ambientLevel": clamped]), 0)
        } else {
            return ("Ambient sound level set to: \(clamped)/20\n", 0)
        }
    }

    private static func executeEQ(args: [String], bwProvider: BowersWilkinsProvider, isJSON: Bool) async -> (output: String, exitCode: Int32) {
        if args.isEmpty {
            let bass = bwProvider.bassLevel
            let treble = bwProvider.trebleLevel
            if isJSON {
                return (jsonString(for: ["bass": bass, "treble": treble]), 0)
            } else {
                var out = "Equalizer / Tone Controls:\n"
                out += "  Bass:   \(bass) (-60 to +60)\n"
                out += "  Treble: \(treble) (-60 to +60)\n"
                return (out, 0)
            }
        }

        var i = 0
        while i < args.count {
            let key = args[i].lowercased()
            if key == "bass", i + 1 < args.count, let val = Int(args[i + 1]) {
                bwProvider.setBassLevel(val)
                bwProvider.commitBass()
                i += 2
            } else if key == "treble", i + 1 < args.count, let val = Int(args[i + 1]) {
                bwProvider.setTrebleLevel(val)
                bwProvider.commitTreble()
                i += 2
            } else {
                i += 1
            }
        }

        for _ in 0..<25 {
            if !bwProvider.isCommandInFlightOrQueued(BWRPCatalog.bassSet) &&
               !bwProvider.isCommandInFlightOrQueued(BWRPCatalog.trebleSet) {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        if isJSON {
            return (jsonString(for: ["success": true, "bass": bwProvider.bassLevel, "treble": bwProvider.trebleLevel]), 0)
        } else {
            return ("Updated tone controls: Bass=\(bwProvider.bassLevel), Treble=\(bwProvider.trebleLevel)\n", 0)
        }
    }

    private static func executeBattery(manager: HeadphoneManager, isJSON: Bool) -> (output: String, exitCode: Int32) {
        let provider = activeProvider(manager: manager)
        let osConnectedDevice = manager.recognizedDevices.first(where: { $0.isConnected })

        guard provider != nil || osConnectedDevice != nil else {
            if isJSON { return (jsonString(for: ["error": "No headphone connected"]), 1) }
            else { return ("No headphone connected.\n", 1) }
        }

        let name = (provider?.connectedName.isEmpty == false ? provider?.connectedName : osConnectedDevice?.name) ?? "Headphones"
        let percent = provider?.batteryPercent ?? (osConnectedDevice.flatMap { LinuxBluetoothInventory.shared.fetchBatteryPercentage(for: $0.address) })
        let isCharging = provider?.isCharging ?? false

        if isJSON {
            var dict: [String: Any] = ["device": name, "batteryPercent": percent as Any, "isCharging": isCharging]
            if let apple = provider as? AppleAccessoryProvider {
                dict["leftBattery"] = apple.leftBattery?.level
                dict["rightBattery"] = apple.rightBattery?.level
                dict["caseBattery"] = apple.caseBattery?.level
            }
            return (jsonString(for: dict), 0)
        } else {
            var out = "Device:        \(name)\n"
            out += "Battery:       \(percent.map { "\($0)%" } ?? "Unknown")\n"
            out += "Charging:      \(isCharging ? "Yes" : "No")\n"
            if let apple = provider as? AppleAccessoryProvider {
                var podParts: [String] = []
                if let l = apple.leftBattery, l.status != .disconnected {
                    podParts.append("L: \(l.level)%\(l.status == .charging ? " ⚡" : "")")
                }
                if let r = apple.rightBattery, r.status != .disconnected {
                    podParts.append("R: \(r.level)%\(r.status == .charging ? " ⚡" : "")")
                }
                if let c = apple.caseBattery, c.status != .disconnected {
                    podParts.append("Case: \(c.level)%\(c.status == .charging ? " ⚡" : "")")
                }
                if !podParts.isEmpty {
                    out += "Pods / Case:   \(podParts.joined(separator: "  |  "))\n"
                }
            }
            return (out, 0)
        }
    }

    private static func executeRestore(action: String, manager: HeadphoneManager, isJSON: Bool) -> (output: String, exitCode: Int32) {
        let store = LinuxSettingsStore.shared
        let provider = activeProvider(manager: manager)
        let providerID = provider?.providerID ?? "bowers-wilkins"

        switch action.lowercased() {
        case "enable", "on", "1":
            store.setRestoreOnConnectEnabled(true, for: providerID)
            if isJSON { return (jsonString(for: ["restoreOnConnect": true, "provider": providerID]), 0) }
            else { return ("Restore-on-connect enabled for \(providerID).\n", 0) }

        case "disable", "off", "0":
            store.setRestoreOnConnectEnabled(false, for: providerID)
            if isJSON { return (jsonString(for: ["restoreOnConnect": false, "provider": providerID]), 0) }
            else { return ("Restore-on-connect disabled for \(providerID).\n", 0) }

        default:
            let enabled = store.isRestoreOnConnectEnabled(for: providerID)
            if isJSON { return (jsonString(for: ["restoreOnConnect": enabled, "provider": providerID]), 0) }
            else { return ("Restore-on-connect for \(providerID): \(enabled ? "Enabled" : "Disabled")\n", 0) }
        }
    }

    private static func executeDiag(manager: HeadphoneManager, audio: LinuxPipeWireAudio, isJSON: Bool) -> (output: String, exitCode: Int32) {
        var info: [String: Any] = [:]
        info["os"] = "Linux"
        info["configDir"] = AppPlatformPaths.configDirectory.path
        info["dataDir"] = AppPlatformPaths.dataDirectory.path
        info["audioDevices"] = audio.devices.map { ["id": $0.id, "name": $0.name, "uid": $0.uid] }
        info["defaultSinkID"] = audio.defaultDeviceID as Any
        info["recognizedBluetooth"] = manager.recognizedDevices.map { ["address": $0.address, "name": $0.name, "vendor": $0.vendorName] }

        if let provider = activeProvider(manager: manager) {
            info["activeDevice"] = [
                "name": provider.connectedName,
                "vendor": provider.vendorName,
                "state": provider.connectionState.title,
                "battery": provider.batteryPercent as Any,
                "charging": provider.isCharging as Any,
                "anc": provider.noiseMode?.rawValue as Any
            ]
        }

        if isJSON {
            return (jsonString(for: info), 0)
        } else {
            var lines: [String] = []
            lines.append("=== HeadBridge Linux Diagnostics ===")
            lines.append("Configuration Directory: \(AppPlatformPaths.configDirectory.path)")
            lines.append("Data Directory:          \(AppPlatformPaths.dataDirectory.path)")
            lines.append("\nAudio Sinks Detected:")
            for dev in audio.devices {
                let def = dev.id == audio.defaultDeviceID ? " [Default]" : ""
                lines.append("  • [\(dev.id)] \(dev.name)\(def)")
            }
            lines.append("\nBluetooth Devices Paired:")
            for dev in manager.recognizedDevices {
                lines.append("  • \(dev.address) - \(dev.name) (\(dev.vendorName))")
            }
            if let provider = activeProvider(manager: manager) {
                lines.append("\nActive Headphone Session:")
                lines.append("  • Name:    \(provider.connectedName)")
                lines.append("  • State:   \(provider.connectionState.title)")
                lines.append("  • Vendor:  \(provider.vendorName)")
                lines.append("  • Battery: \(provider.batteryPercent.map { "\($0)%" } ?? "—")")
            }
            return (lines.joined(separator: "\n") + "\n", 0)
        }
    }

    private static func handleDaemon(
        manager: HeadphoneManager,
        audio: LinuxPipeWireAudio,
        bwTransport: LinuxBowersWilkinsTransport,
        bwProvider: BowersWilkinsProvider,
        sonyProvider: SonyMDRProvider,
        appleTransport: LinuxAppleAccessoryTransport,
        appleProvider: AppleAccessoryProvider
    ) async {
        print("Starting HeadBridge daemon on Linux...")
        let server = LinuxDaemonServer()
        self.runningServer = server

        server.requestHandler = { request in
            let filteredArgs = request.args.filter { $0 != "--json" && $0 != "--verbose" && $0 != "-v" }
            let subcommand = filteredArgs.first ?? "status"

            if subcommand == "ping" {
                return LinuxIPCResponse(exitCode: 0, output: request.isJSON ? "{\"pong\":true}\n" : "pong\n")
            }

            if subcommand == "daemon" {
                if filteredArgs.contains("stop") {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        runningServer?.stop()
                        manager.shutdown()
                        exit(0)
                    }
                    return LinuxIPCResponse(exitCode: 0, output: request.isJSON ? "{\"stopped\":true}\n" : "HeadBridge daemon stopped.\n")
                } else {
                    return LinuxIPCResponse(exitCode: 0, output: request.isJSON ? "{\"running\":true}\n" : "HeadBridge daemon is running.\n")
                }
            }

            return await dispatchCommand(
                args: request.args,
                isJSON: request.isJSON,
                manager: manager,
                audio: audio,
                bwTransport: bwTransport,
                bwProvider: bwProvider,
                sonyProvider: sonyProvider,
                appleTransport: appleTransport,
                appleProvider: appleProvider
            )
        }

        guard server.start() else {
            fputs("Error: Failed to bind daemon socket at \(server.socketPath). Is another daemon instance running?\n", stderr)
            exit(1)
        }

        // Auto-connect to recognized connected headphone asynchronously
        Task {
            if let connectedDev = manager.recognizedDevices.first(where: { $0.isConnected }) {
                if connectedDev.providerID == "bowers-wilkins" {
                    bwTransport.connect(address: connectedDev.address, name: connectedDev.name)
                } else if connectedDev.providerID == "sony" {
                    sonyProvider.connect(to: BluetoothPairedDevice(id: connectedDev.id, name: connectedDev.name, address: connectedDev.address, isConnected: true, isAudioConnected: true))
                } else if connectedDev.providerID == "apple" {
                    appleProvider.connect(to: BluetoothPairedDevice(id: connectedDev.id, name: connectedDev.name, address: connectedDev.address, isConnected: true, isAudioConnected: true))
                }
                for _ in 0..<30 {
                    if activeProvider(manager: manager)?.connectionState == .ready { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if activeProvider(manager: manager)?.connectionState == .ready {
                    for _ in 0..<30 {
                        if bwProvider.hasConfirmedRead(BWRPCatalog.ancGet) &&
                           (bwProvider.supportsToneControls || bwProvider.hasConfirmedRead(BWRPCatalog.eqGet)) {
                            break
                        }
                        if !bwProvider.hasPendingWrites { break }
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    }
                }
            }
        }

        // Auto-connect when headphones connect while daemon is running
        self.autoConnectCancellable = audio.devicesPublisher
            .sink { _ in
                guard let connectedDev = manager.recognizedDevices.first(where: { $0.isConnected }) else { return }
                if connectedDev.providerID == "bowers-wilkins" && bwProvider.connectionState == .idle {
                    bwTransport.connect(address: connectedDev.address, name: connectedDev.name)
                } else if connectedDev.providerID == "sony" && sonyProvider.connectionState == .idle {
                    sonyProvider.connect(to: BluetoothPairedDevice(id: connectedDev.id, name: connectedDev.name, address: connectedDev.address, isConnected: true, isAudioConnected: true))
                } else if connectedDev.providerID == "apple" && appleProvider.connectionState == .idle {
                    appleProvider.connect(to: BluetoothPairedDevice(id: connectedDev.id, name: connectedDev.name, address: connectedDev.address, isConnected: true, isAudioConnected: true))
                }
            }

        print("HeadBridge daemon listening on \(server.socketPath)")
        print("Monitoring Bluetooth connections and PipeWire audio stream...")
        print("Use 'headbridge daemon status' to check health, or 'headbridge daemon stop' to terminate.")

        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigSource.setEventHandler {
            print("\nShutting down HeadBridge daemon cleanly...")
            server.stop()
            manager.shutdown()
            exit(0)
        }
        sigSource.resume()

        let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigTermSource.setEventHandler {
            print("\nTerminating HeadBridge daemon...")
            server.stop()
            manager.shutdown()
            exit(0)
        }
        sigTermSource.resume()

        // Yield to cooperative Tasks and DispatchQueue.main
        while true {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func noiseModeDescription(_ mode: HeadphoneNoiseMode) -> String {
        switch mode {
        case .noiseCancellation: return "Noise Cancellation"
        case .ambient: return "Ambient / Pass Through"
        case .windReduction: return "Wind Reduction"
        case .adaptive: return "Adaptive"
        case .off: return "Off"
        }
    }

    private static func jsonString(for dictionary: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}\n"
        }
        return str + "\n"
    }

    private static func printHelp() {
        print("""
        HeadBridge - Linux Bluetooth Headphone Control

        USAGE:
            headbridge [COMMAND] [OPTIONS]

        COMMANDS:
            status                      Show status of connected headphone (default)
            devices                     List paired AirPods, Beats, Bowers & Wilkins, and Sony devices
            connect [address|name]      Connect to headphone
            disconnect                  Disconnect active headphone session
            anc [off|anc|ambient|adaptive] Get or set Active Noise Cancellation / Listening mode
            ambient-level [0-20]        Get or set Sony ambient sound level
            eq [bass <n>] [treble <n>]  Get or set tone / EQ controls (-60 to +60)
            battery                     Show battery percentage and charging status
            restore [status|on|off]     Configure restore-on-connect profile
            daemon [start|status|stop]  Run or control the background daemon
            diag                        Print system and diagnostic state
            help                        Show this help message

        OPTIONS:
            --json                      Format output as JSON
            --verbose, -v               Print verbose transport logs
        """)
    }
}
#endif
