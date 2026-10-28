import Foundation

#if !os(macOS)
@MainActor
public final class LinuxPipeWireAudio: ObservableObject, AudioControllerProtocol {
    @Published public private(set) var devices: [SystemAudioDevice] = []
    @Published public private(set) var inputDevices: [SystemAudioDevice] = []
    @Published public private(set) var defaultDeviceID: AudioDeviceID?
    @Published public private(set) var defaultInputDeviceID: AudioDeviceID?
    @Published public private(set) var volume: Float = 1.0
    public var volumeCanBeChanged: Bool { true }

    public var devicesPublisher: AnyPublisher<[SystemAudioDevice], Never> {
        $devices.eraseToAnyPublisher()
    }

    public var volumePublisher: AnyPublisher<Float, Never> {
        $volume.eraseToAnyPublisher()
    }

    public var defaultDeviceIDPublisher: AnyPublisher<AudioDeviceID?, Never> {
        $defaultDeviceID.eraseToAnyPublisher()
    }

    private let runner: LinuxCommandRunner
    private var monitorProcess: Process?
    private var debounceWorkItem: DispatchWorkItem?

    public init(runner: LinuxCommandRunner = .shared, startMonitoring: Bool = false) {
        self.runner = runner
        refresh()
        if startMonitoring {
            startEventMonitor()
        }
    }

    deinit {
        monitorProcess?.terminate()
    }

    public func refresh() {
        // 1. Query sinks via pactl -f json list sinks
        guard let sinkResult = runner.run("pactl", arguments: ["-f", "json", "list", "sinks"]),
              sinkResult.exitCode == 0,
              let sinkData = sinkResult.stdout.data(using: .utf8),
              let sinkList = try? JSONSerialization.jsonObject(with: sinkData) as? [[String: Any]] else {
            // Fallback to wpctl if pactl is not returning JSON
            refreshViaWpctl()
            return
        }

        var newDevices: [SystemAudioDevice] = []
        var sinkVolumes: [AudioDeviceID: Float] = [:]

        for sink in sinkList {
            guard let index = sink["index"] as? UInt32,
                  let name = sink["name"] as? String else {
                continue
            }
            let description = (sink["description"] as? String) ?? name
            let properties = sink["properties"] as? [String: Any] ?? [:]
            let bus = properties["device.bus"] as? String ?? ""

            let transport: UInt32
            if name.contains("bluez") || bus == "bluetooth" {
                transport = kAudioDeviceTransportTypeBluetooth
            } else if bus == "usb" {
                transport = kAudioDeviceTransportTypeUSB
            } else {
                transport = kAudioDeviceTransportTypeBuiltIn
            }

            let device = SystemAudioDevice(
                id: index,
                uid: name,
                name: description,
                transportType: transport
            )
            newDevices.append(device)

            if let volumeObj = sink["volume"] as? [String: Any],
               let frontLeft = volumeObj["front-left"] as? [String: Any],
               let rawVal = frontLeft["value"] as? NSNumber {
                sinkVolumes[index] = Float(truncating: rawVal) / 65536.0
            }
        }

        devices = newDevices

        // 2. Query default sink via pactl info
        if let infoResult = runner.run("pactl", arguments: ["info"]), infoResult.exitCode == 0 {
            for line in infoResult.stdout.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Default Sink:") {
                    let parts = trimmed.split(separator: ":", maxSplits: 1)
                    if parts.count >= 2 {
                        let defaultName = parts[1].trimmingCharacters(in: .whitespaces)
                        if let matched = devices.first(where: { $0.uid == defaultName }) {
                            defaultDeviceID = matched.id
                            if let vol = sinkVolumes[matched.id] {
                                volume = vol
                            }
                        }
                    }
                }
            }
        }
    }

    private func refreshViaWpctl() {
        guard let statusResult = runner.run("wpctl", arguments: ["status"]), statusResult.exitCode == 0 else {
            return
        }

        var newDevices: [SystemAudioDevice] = []
        var inSinksSection = false

        for line in statusResult.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("Sinks:") {
                inSinksSection = true
                continue
            } else if inSinksSection && (trimmed.contains("Sources:") || trimmed.contains("Filters:") || trimmed.contains("Streams:")) {
                inSinksSection = false
                break
            }

            guard inSinksSection else { continue }
            // Lines like: "│  *   60. Core Ultra 200V Series Processors HD Audio Speaker [vol: 1.00]"
            let isDefault = trimmed.contains("*")
            let clean = trimmed.replacingOccurrences(of: "│", with: "")
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespaces)

            let parts = clean.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, let id = UInt32(parts[0].trimmingCharacters(in: .whitespaces)) else {
                continue
            }

            let rest = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let nameParts = rest.split(separator: "[vol:")
            let name = String(nameParts[0]).trimmingCharacters(in: .whitespaces)

            let transport: UInt32 = name.lowercased().contains("px7") || name.lowercased().contains("wh-") || name.lowercased().contains("bluetooth")
                ? kAudioDeviceTransportTypeBluetooth
                : kAudioDeviceTransportTypeBuiltIn

            let dev = SystemAudioDevice(id: id, uid: "wpctl:\(id)", name: name, transportType: transport)
            newDevices.append(dev)

            if isDefault {
                defaultDeviceID = id
                if nameParts.count >= 2 {
                    let volStr = nameParts[1].replacingOccurrences(of: "]", with: "").trimmingCharacters(in: .whitespaces)
                    if let volFloat = Float(volStr) {
                        volume = volFloat
                    }
                }
            }
        }

        if !newDevices.isEmpty {
            devices = newDevices
        }
    }

    public func setVolume(_ newVolume: Float) {
        let clamped = max(0.0, min(1.0, newVolume))
        volume = clamped
        let percent = Int((clamped * 100).rounded())

        if runner.findExecutable("pactl") != nil {
            _ = runner.run("pactl", arguments: ["set-sink-volume", "@DEFAULT_SINK@", "\(percent)%"])
        } else if runner.findExecutable("wpctl") != nil {
            _ = runner.run("wpctl", arguments: ["set-volume", "@DEFAULT_AUDIO_SINK@", String(format: "%.2f", clamped)])
        }
    }

    public func setDefaultDevice(_ device: SystemAudioDevice) {
        setDefaultOutputDevice(device.id)
    }

    public func setDefaultOutputDevice(_ id: AudioDeviceID) {
        defaultDeviceID = id
        if let device = devices.first(where: { $0.id == id }) {
            if runner.findExecutable("pactl") != nil {
                _ = runner.run("pactl", arguments: ["set-default-sink", device.uid])
            } else if runner.findExecutable("wpctl") != nil {
                _ = runner.run("wpctl", arguments: ["set-default", "\(device.id)"])
            }
        }
    }

    public func setDefaultInputDevice(_ id: AudioDeviceID) {
        defaultInputDeviceID = id
        if let device = inputDevices.first(where: { $0.id == id }) {
            if runner.findExecutable("pactl") != nil {
                _ = runner.run("pactl", arguments: ["set-default-source", device.uid])
            } else if runner.findExecutable("wpctl") != nil {
                _ = runner.run("wpctl", arguments: ["set-default", "\(device.id)"])
            }
        }
    }

    public func shutdown() {
        monitorProcess?.terminate()
        monitorProcess = nil
    }

    public func startMonitoring() {
        startEventMonitor()
    }

    private func startEventMonitor() {
        monitorProcess?.terminate()
        monitorProcess = runner.spawn("pactl", arguments: ["subscribe"]) { [weak self] line in
            let isRelevant = line.contains("on sink") || line.contains("on source") || line.contains("on card") || line.contains("on server")
            guard isRelevant else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.debounceWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    self?.refresh()
                }
                self.debounceWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
            }
        }
    }

    // Testing helpers
    public func simulateDevices(_ testDevices: [SystemAudioDevice], defaultID: AudioDeviceID?, defaultVol: Float = 1.0) {
        devices = testDevices
        defaultDeviceID = defaultID
        volume = defaultVol
    }

    public func simulateVolumeChange(_ newVol: Float) {
        volume = newVol
    }
}
#endif
