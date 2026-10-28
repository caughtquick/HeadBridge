import Foundation

public final class LinuxBluetoothInventory: BluetoothInventoryService, @unchecked Sendable {
    public static let shared = LinuxBluetoothInventory()
    private let runner: LinuxCommandRunner

    public init(runner: LinuxCommandRunner = .shared) {
        self.runner = runner
    }

    public static func fetchPairedDevices() -> [BluetoothPairedDevice]? {
        shared.fetchPairedDevices()
    }

    public func fetchPairedDevices() -> [BluetoothPairedDevice]? {
        fetchViaBluetoothctl()
    }

    public func fetchBatteryPercentage(for address: String) -> Int? {
        let macSegment = address.replacingOccurrences(of: ":", with: "_").uppercased()
        let path = "/org/bluez/hci0/dev_\(macSegment)"
        guard let result = runner.run("busctl", arguments: ["get-property", "org.bluez", path, "org.bluez.Battery1", "Percentage"]),
              result.exitCode == 0 else {
            return nil
        }
        // Output format: "y 61"
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ")
        if parts.count >= 2, let percent = Int(parts[1]) {
            return percent
        }
        return nil
    }

    private func fetchViaBluetoothctl() -> [BluetoothPairedDevice]? {
        // 1. Get currently connected device addresses in one fast query (~30ms)
        var connectedAddresses = Set<String>()
        if let connResult = runner.run("bluetoothctl", arguments: ["devices", "Connected"]),
           connResult.exitCode == 0 {
            for line in connResult.stdout.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("Device ") else { continue }
                let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count >= 2 else { continue }
                connectedAddresses.insert(String(parts[1]).uppercased())
            }
        }

        // 2. Get paired devices (fast ~30ms; fallback to general devices query if Paired is not supported)
        var pairedOutput: String?
        if let pairedResult = runner.run("bluetoothctl", arguments: ["devices", "Paired"]),
           pairedResult.exitCode == 0, !pairedResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pairedOutput = pairedResult.stdout
        } else if let devResult = runner.run("bluetoothctl", arguments: ["devices"]),
                  devResult.exitCode == 0 {
            pairedOutput = devResult.stdout
        }

        guard let output = pairedOutput else { return nil }

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

            let isConnected = connectedAddresses.contains(address)
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
