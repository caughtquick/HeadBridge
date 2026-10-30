import Foundation

public struct BluetoothPairedDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let address: String
    public let isConnected: Bool
    public let isAudioConnected: Bool

    public init(
        id: String,
        name: String,
        address: String,
        isConnected: Bool,
        isAudioConnected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.isConnected = isConnected
        self.isAudioConnected = isAudioConnected
    }
}
