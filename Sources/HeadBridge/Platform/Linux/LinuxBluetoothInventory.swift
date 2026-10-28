import Foundation

public final class LinuxBluetoothInventory: BluetoothInventoryService, @unchecked Sendable {
    public static let shared = LinuxBluetoothInventory()

    public init() {}

    public static func fetchPairedDevices() -> [BluetoothPairedDevice]? {
        shared.fetchPairedDevices()
    }

    public func fetchPairedDevices() -> [BluetoothPairedDevice]? {
        // Try bluetoothctl directly or via dev container helper
        if let devices = fetchViaBluetoothctl() {
            return devices
        }
        return nil
    }

    private func findExecutable(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin")
            .split(separator: ":")
        for dir in paths {
            let fullPath = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    private func runCommand(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        if findExecutable(executable) != nil {
            process.executableURL = URL(fileURLWithPath: findExecutable(executable)!)
            process.arguments = arguments
        } else if let hostExec = findExecutable("distrobox-host-exec") {
            process.executableURL = URL(fileURLWithPath: hostExec)
            process.arguments = [executable] + arguments
        } else {
            return nil
        }

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func fetchViaBluetoothctl() -> [BluetoothPairedDevice]? {
        guard let output = runCommand("bluetoothctl", arguments: ["devices"]) else {
            return nil
        }

        var results: [BluetoothPairedDevice] = []
        let lines = output.split(separator: "\n")

        for line in lines {
            // Format: "Device EC:66:D1:BE:1D:80 Abhijit’s Px7 S2e"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Device ") else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let address = String(parts[1]).uppercased()
            let name = parts.count >= 3 ? String(parts[2]) : address

            var isConnected = false
            if let infoOutput = runCommand("bluetoothctl", arguments: ["info", address]) {
                for infoLine in infoOutput.split(separator: "\n") {
                    let infoTrimmed = infoLine.trimmingCharacters(in: .whitespaces)
                    if infoTrimmed.hasPrefix("Connected:") {
                        isConnected = infoTrimmed.lowercased().contains("yes")
                    }
                }
            }

            results.append(
                BluetoothPairedDevice(
                    id: address,
                    name: name,
                    address: address,
                    isConnected: isConnected,
                    isAudioConnected: isConnected
                )
            )
        }

        return results
    }
}
