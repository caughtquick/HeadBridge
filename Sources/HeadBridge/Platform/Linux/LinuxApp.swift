#if os(Linux)
import Foundation

@main
@MainActor
struct LinuxApp {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let isJSON = args.contains("--json")
        let filteredArgs = args.filter { $0 != "--json" }
        let subcommand = filteredArgs.first ?? "status"

        if subcommand == "help" || subcommand == "--help" || subcommand == "-h" {
            printHelp()
            return
        }

        let audio = LinuxPipeWireAudio()
        let bwTransport = LinuxBowersWilkinsTransport()
        let bwProvider = BowersWilkinsProvider(transport: bwTransport)

        let sonyTransport = LinuxSonyRFCOMMTransport()
        let sonyClient = SonyV1Client(transport: sonyTransport)
        let sonyProvider = SonyMDRProvider(client: sonyClient)

        let manager = HeadphoneManager(providers: [bwProvider, sonyProvider])
        manager.installAudioDeviceDiscovery(systemAudio: audio)
        manager.refreshAll()

        // Wait brief moment for initial discovery
        try? await Task.sleep(nanoseconds: 300_000_000)

        switch subcommand {
        case "status":
            handleStatus(manager: manager, audio: audio, isJSON: isJSON)

        case "devices":
            handleDevices(manager: manager, audio: audio, isJSON: isJSON)

        case "connect":
            let target = filteredArgs.count > 1 ? filteredArgs[1] : nil
            await handleConnect(target: target, manager: manager, bwTransport: bwTransport, isJSON: isJSON)

        case "disconnect":
            handleDisconnect(manager: manager, isJSON: isJSON)

        case "anc":
            let modeArg = filteredArgs.count > 1 ? filteredArgs[1] : nil
            handleANC(modeArg: modeArg, manager: manager, isJSON: isJSON)

        case "ambient-level":
            let levelArg = filteredArgs.count > 1 ? Int(filteredArgs[1]) : nil
            handleAmbientLevel(level: levelArg, sonyProvider: sonyProvider, isJSON: isJSON)

        case "eq":
            let subArgs = Array(filteredArgs.dropFirst())
            handleEQ(args: subArgs, bwProvider: bwProvider, isJSON: isJSON)

        case "volume":
            let action = filteredArgs.count > 1 ? filteredArgs[1] : "get"
            let value = filteredArgs.count > 2 ? Float(filteredArgs[2]) : nil
            handleVolume(action: action, value: value, audio: audio, isJSON: isJSON)

        case "battery":
            handleBattery(manager: manager, isJSON: isJSON)

        case "restore":
            let action = filteredArgs.count > 1 ? filteredArgs[1] : "status"
            handleRestore(action: action, manager: manager, isJSON: isJSON)

        case "monitor", "daemon":
            await handleDaemon(manager: manager, audio: audio, bwTransport: bwTransport)

        case "diag":
            handleDiag(manager: manager, audio: audio, isJSON: isJSON)

        default:
            print("Unknown command: \(subcommand). Use 'headbridge help' for available commands.")
            exit(1)
        }
    }

    private static func activeProvider(manager: HeadphoneManager) -> (any HeadphoneProvider)? {
        manager.providers.first { $0.connectionState == .ready }
            ?? manager.providers.first { $0.connectionState == .connecting }
    }

    private static func handleStatus(manager: HeadphoneManager, audio: LinuxPipeWireAudio, isJSON: Bool) {
        let provider = activeProvider(manager: manager)
        let isConnected = provider?.connectionState == .ready

        if isJSON {
            var dict: [String: Any] = [
                "connected": isConnected,
                "connectionState": (provider?.connectionState.title) ?? "idle",
                "deviceName": provider?.connectedName ?? "",
                "vendor": provider?.vendorName ?? "",
                "providerID": provider?.providerID ?? "",
                "batteryPercent": provider?.batteryPercent as Any,
                "isCharging": provider?.isCharging as Any,
                "noiseMode": provider?.noiseMode?.rawValue as Any,
                "volume": audio.volume,
                "audioSink": audio.devices.first(where: { $0.id == audio.defaultDeviceID })?.name ?? ""
            ]
            if let bw = provider as? BowersWilkinsProvider {
                dict["bassLevel"] = bw.bassLevel
                dict["trebleLevel"] = bw.trebleLevel
            } else if let sony = provider as? SonyMDRProvider {
                dict["ambientLevel"] = sony.ambientLevel
            }
            printJSON(dict)
            return
        }

        print("=== HeadBridge Status ===")
        if let provider = provider, isConnected {
            print("Device:        \(provider.connectedName)")
            print("Vendor:        \(provider.vendorName)")
            print("State:         \(provider.connectionState.title)")
            if let battery = provider.batteryPercent {
                let charging = (provider.isCharging ?? false) ? " (Charging)" : ""
                print("Battery:       \(battery)%\(charging)")
            } else {
                print("Battery:       Unknown")
            }
            if let noiseMode = provider.noiseMode {
                print("ANC Mode:      \(noiseModeDescription(noiseMode))")
            }
            if let bw = provider as? BowersWilkinsProvider {
                print("Tone / EQ:     Bass: \(bw.bassLevel), Treble: \(bw.trebleLevel)")
            } else if let sony = provider as? SonyMDRProvider {
                print("Ambient Level: \(sony.ambientLevel)/20")
            }
            let sinkName = audio.devices.first(where: { $0.id == audio.defaultDeviceID })?.name ?? "Default"
            let volPercent = Int((audio.volume * 100).rounded())
            print("Audio Output:  \(sinkName) (Volume: \(volPercent)%)")
        } else {
            print("No supported headphones currently connected.")
            let paired = manager.recognizedDevices
            if !paired.isEmpty {
                print("\nRecognized paired devices:")
                for dev in paired {
                    print("  • \(dev.name) (\(dev.address)) [\(dev.vendorName)]")
                }
                print("\nRun 'headbridge connect <address>' to connect.")
            } else {
                print("No recognized Bowers & Wilkins or Sony devices found in paired Bluetooth inventory.")
            }
        }
    }

    private static func handleDevices(manager: HeadphoneManager, audio: LinuxPipeWireAudio, isJSON: Bool) {
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
            printJSON(["devices": list])
            return
        }

        print("=== Recognized Bluetooth Devices ===")
        if paired.isEmpty {
            print("No supported Bowers & Wilkins or Sony headphones detected.")
            print("Ensure headphones are paired via bluetoothctl or your desktop settings.")
        } else {
            for dev in paired {
                let status = dev.isConnected ? " [Connected]" : " [Paired]"
                print("  \(dev.address)  \(dev.name)  (\(dev.vendorName))\(status)")
            }
        }
    }

    private static func handleConnect(target: String?, manager: HeadphoneManager, bwTransport: LinuxBowersWilkinsTransport, isJSON: Bool) async {
        let paired = manager.recognizedDevices
        guard !paired.isEmpty else {
            if isJSON {
                printJSON(["error": "No recognized paired devices found"])
            } else {
                print("Error: No recognized paired devices found.")
            }
            return
        }

        let device: RecognizedHeadphoneDevice
        if let target = target {
            guard let matched = paired.first(where: {
                $0.address.caseInsensitiveCompare(target) == .orderedSame ||
                $0.name.lowercased().contains(target.lowercased())
            }) else {
                if isJSON {
                    printJSON(["error": "Device '\(target)' not found in paired list"])
                } else {
                    print("Error: Device '\(target)' not found in paired inventory.")
                }
                return
            }
            device = matched
        } else {
            device = paired.first!
        }

        if !isJSON {
            print("Connecting to \(device.name) (\(device.address))...")
        }

        if device.providerID == "bowers-wilkins" {
            bwTransport.connect(address: device.address, name: device.name)
        }

        // Wait for connection to settle
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if activeProvider(manager: manager)?.connectionState == .ready {
                break
            }
        }

        let ready = activeProvider(manager: manager)?.connectionState == .ready
        if isJSON {
            printJSON(["success": ready, "device": device.name, "address": device.address])
        } else {
            if ready {
                print("Successfully connected to \(device.name)!")
            } else {
                print("Connection in progress or pending.")
            }
        }
    }

    private static func handleDisconnect(manager: HeadphoneManager, isJSON: Bool) {
        guard let provider = activeProvider(manager: manager) else {
            if isJSON { printJSON(["error": "No active device to disconnect"]) }
            else { print("No active headphone connection.") }
            return
        }

        let name = provider.connectedName
        provider.disconnect()

        if isJSON {
            printJSON(["disconnected": true, "device": name])
        } else {
            print("Disconnected from \(name).")
        }
    }

    private static func handleANC(modeArg: String?, manager: HeadphoneManager, isJSON: Bool) {
        guard let provider = activeProvider(manager: manager) else {
            if isJSON { printJSON(["error": "No headphone connected"]) }
            else { print("Error: No headphone connected.") }
            return
        }

        guard let modeArg = modeArg else {
            // Print current mode
            let current = provider.noiseMode
            if isJSON {
                printJSON(["ancMode": current?.rawValue as Any, "description": current.map(noiseModeDescription) as Any])
            } else {
                print("Current ANC mode: \(current.map(noiseModeDescription) ?? "Unknown")")
                print("Supported modes: \(provider.supportedNoiseModes.map(noiseModeDescription).joined(separator: ", "))")
            }
            return
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
        default:
            targetMode = nil
        }

        guard let mode = targetMode else {
            print("Invalid ANC mode: \(modeArg). Available: off, anc, ambient, wind")
            return
        }

        provider.setNoiseMode(mode)
        if isJSON {
            printJSON(["success": true, "ancMode": mode.rawValue, "description": noiseModeDescription(mode)])
        } else {
            print("ANC mode set to: \(noiseModeDescription(mode))")
        }
    }

    private static func handleAmbientLevel(level: Int?, sonyProvider: SonyMDRProvider, isJSON: Bool) {
        guard let level = level else {
            let current = sonyProvider.ambientLevel
            if isJSON {
                printJSON(["ambientLevel": current])
            } else {
                print("Current ambient level: \(current)/20")
            }
            return
        }

        let clamped = max(0, min(20, level))
        sonyProvider.setAmbientLevel(clamped)
        if isJSON {
            printJSON(["success": true, "ambientLevel": clamped])
        } else {
            print("Ambient sound level set to: \(clamped)/20")
        }
    }

    private static func handleEQ(args: [String], bwProvider: BowersWilkinsProvider, isJSON: Bool) {
        if args.isEmpty {
            let bass = bwProvider.bassLevel
            let treble = bwProvider.trebleLevel
            if isJSON {
                printJSON(["bass": bass, "treble": treble])
            } else {
                print("Equalizer / Tone Controls:")
                print("  Bass:   \(bass) (-60 to +60)")
                print("  Treble: \(treble) (-60 to +60)")
            }
            return
        }

        var i = 0
        while i < args.count {
            let key = args[i].lowercased()
            if key == "bass", i + 1 < args.count, let val = Int(args[i + 1]) {
                bwProvider.setBassLevel(val)
                i += 2
            } else if key == "treble", i + 1 < args.count, let val = Int(args[i + 1]) {
                bwProvider.setTrebleLevel(val)
                i += 2
            } else {
                i += 1
            }
        }

        if isJSON {
            printJSON(["success": true, "bass": bwProvider.bassLevel, "treble": bwProvider.trebleLevel])
        } else {
            print("Updated tone controls: Bass=\(bwProvider.bassLevel), Treble=\(bwProvider.trebleLevel)")
        }
    }

    private static func handleVolume(action: String, value: Float?, audio: LinuxPipeWireAudio, isJSON: Bool) {
        if action == "set", let val = value {
            let normalized = val > 1.0 ? val / 100.0 : val
            audio.setVolume(normalized)
            let percent = Int((audio.volume * 100).rounded())
            if isJSON {
                printJSON(["volume": audio.volume, "percent": percent])
            } else {
                print("Volume set to: \(percent)%")
            }
        } else {
            let percent = Int((audio.volume * 100).rounded())
            if isJSON {
                printJSON(["volume": audio.volume, "percent": percent])
            } else {
                print("Current Volume: \(percent)% (\(String(format: "%.2f", audio.volume)))")
            }
        }
    }

    private static func handleBattery(manager: HeadphoneManager, isJSON: Bool) {
        guard let provider = activeProvider(manager: manager) else {
            if isJSON { printJSON(["error": "No headphone connected"]) }
            else { print("No headphone connected.") }
            return
        }

        let percent = provider.batteryPercent
        let isCharging = provider.isCharging ?? false

        if isJSON {
            printJSON(["device": provider.connectedName, "batteryPercent": percent as Any, "isCharging": isCharging])
        } else {
            print("Device:        \(provider.connectedName)")
            print("Battery:       \(percent.map { "\($0)%" } ?? "Unknown")")
            print("Charging:      \(isCharging ? "Yes" : "No")")
        }
    }

    private static func handleRestore(action: String, manager: HeadphoneManager, isJSON: Bool) {
        let store = LinuxSettingsStore.shared
        let provider = activeProvider(manager: manager)
        let providerID = provider?.providerID ?? "bowers-wilkins"

        switch action.lowercased() {
        case "enable", "on", "1":
            store.setRestoreOnConnectEnabled(true, for: providerID)
            if isJSON { printJSON(["restoreOnConnect": true, "provider": providerID]) }
            else { print("Restore-on-connect enabled for \(providerID).") }

        case "disable", "off", "0":
            store.setRestoreOnConnectEnabled(false, for: providerID)
            if isJSON { printJSON(["restoreOnConnect": false, "provider": providerID]) }
            else { print("Restore-on-connect disabled for \(providerID).") }

        default:
            let enabled = store.isRestoreOnConnectEnabled(for: providerID)
            if isJSON { printJSON(["restoreOnConnect": enabled, "provider": providerID]) }
            else { print("Restore-on-connect for \(providerID): \(enabled ? "Enabled" : "Disabled")") }
        }
    }

    private static func handleDaemon(manager: HeadphoneManager, audio: LinuxPipeWireAudio, bwTransport: LinuxBowersWilkinsTransport) async {
        print("Starting HeadBridge daemon on Linux...")
        print("Monitoring Bluetooth connections and PipeWire audio stream...")
        print("Press Ctrl+C to exit.")

        // Listen for signals
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigSource.setEventHandler {
            print("\nShutting down HeadBridge daemon cleanly...")
            manager.shutdown()
            exit(0)
        }
        sigSource.resume()

        let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigTermSource.setEventHandler {
            print("\nTerminating HeadBridge daemon...")
            manager.shutdown()
            exit(0)
        }
        sigTermSource.resume()

        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static func handleDiag(manager: HeadphoneManager, audio: LinuxPipeWireAudio, isJSON: Bool) {
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
            printJSON(info)
        } else {
            print("=== HeadBridge Linux Diagnostics ===")
            print("Configuration Directory: \(AppPlatformPaths.configDirectory.path)")
            print("Data Directory:          \(AppPlatformPaths.dataDirectory.path)")
            print("\nAudio Sinks Detected:")
            for dev in audio.devices {
                let def = dev.id == audio.defaultDeviceID ? " [Default]" : ""
                print("  • [\(dev.id)] \(dev.name)\(def)")
            }
            print("\nBluetooth Devices Paired:")
            for dev in manager.recognizedDevices {
                print("  • \(dev.address) - \(dev.name) (\(dev.vendorName))")
            }
            if let provider = activeProvider(manager: manager) {
                print("\nActive Headphone Session:")
                print("  • Name:    \(provider.connectedName)")
                print("  • State:   \(provider.connectionState.title)")
                print("  • Vendor:  \(provider.vendorName)")
                print("  • Battery: \(provider.batteryPercent.map { "\($0)%" } ?? "—")")
            }
        }
    }

    private static func noiseModeDescription(_ mode: HeadphoneNoiseMode) -> String {
        switch mode {
        case .noiseCancellation: return "Noise Cancellation"
        case .ambient: return "Ambient / Pass Through"
        case .windReduction: return "Wind Reduction"
        case .off: return "Off"
        }
    }

    private static func printJSON(_ dictionary: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            print("{}")
            return
        }
        print(str)
    }

    private static func printHelp() {
        print("""
        HeadBridge - Linux Bluetooth Headphone Control

        USAGE:
            headbridge [COMMAND] [OPTIONS]

        COMMANDS:
            status                      Show status of connected headphone (default)
            devices                     List paired Bowers & Wilkins and Sony devices
            connect [address|name]      Connect to headphone
            disconnect                  Disconnect active headphone session
            anc [off|anc|ambient]       Get or set Active Noise Cancellation mode
            ambient-level [0-20]        Get or set Sony ambient sound level
            eq [bass <n>] [treble <n>]  Get or set tone / EQ controls (-60 to +60)
            volume [get|set <0-100>]    Get or set audio output volume
            battery                     Show battery percentage and charging status
            restore [status|on|off]     Configure restore-on-connect profile
            monitor, daemon             Run persistent daemon monitoring connections
            diag                        Print system and diagnostic state
            help                        Show this help message

        OPTIONS:
            --json                      Format output as JSON
        """)
    }
}
#endif
