#if canImport(Combine)
import Combine
#endif
import Foundation

public enum BatteryDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case never
    case low
    case always

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .never: "Never"
        case .low: "Only below 20%"
        case .always: "Always"
        }
    }

    public func shouldDisplay(level: Int?) -> Bool {
        guard let level else { return false }
        return switch self {
        case .never: false
        case .low: level < 20
        case .always: true
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let batteryDisplayMode = "BatteryDisplayMode"
        static let legacySonyVolumeSync = "SonyVolumeSync"
        static let volumeSyncPrefix = "VolumeSyncEnabled"
        static let developerMode = "DeveloperModeEnabled"
        static let showsDockIconWithSettings = "ShowsDockIconWithSettings"

        static func volumeSync(providerID: String) -> String {
            "\(volumeSyncPrefix).\(providerID)"
        }
    }

    @Published var batteryDisplayMode: BatteryDisplayMode {
        didSet { defaults.set(batteryDisplayMode.rawValue, forKey: Key.batteryDisplayMode) }
    }

    @Published private var volumeSyncEnabledByProvider: [String: Bool] = [:]

    @Published var developerModeEnabled: Bool {
        didSet { defaults.set(developerModeEnabled, forKey: Key.developerMode) }
    }

    @Published var showsDockIconWithSettings: Bool {
        didSet { defaults.set(showsDockIconWithSettings, forKey: Key.showsDockIconWithSettings) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        batteryDisplayMode =
            defaults.string(forKey: Key.batteryDisplayMode)
            .flatMap(BatteryDisplayMode.init(rawValue:)) ?? .always
        developerModeEnabled = defaults.bool(forKey: Key.developerMode)
        showsDockIconWithSettings = defaults.bool(forKey: Key.showsDockIconWithSettings)
    }

    func registerVolumeSynchronization(
        providerID: String,
        defaultEnabled: Bool
    ) {
        guard volumeSyncEnabledByProvider[providerID] == nil else { return }

        let key = Key.volumeSync(providerID: providerID)
        let value: Bool
        if let stored = defaults.object(forKey: key) as? Bool {
            value = stored
        } else if providerID == "sony-mdr",
            let legacy = defaults.object(forKey: Key.legacySonyVolumeSync) as? Bool
        {
            value = legacy
            defaults.set(legacy, forKey: key)
            defaults.removeObject(forKey: Key.legacySonyVolumeSync)
        } else {
            value = defaultEnabled
        }
        volumeSyncEnabledByProvider[providerID] = value
    }

    func volumeSynchronizationEnabled(for providerID: String) -> Bool {
        volumeSyncEnabledByProvider[providerID] ?? false
    }

    func setVolumeSynchronizationEnabled(_ enabled: Bool, for providerID: String) {
        volumeSyncEnabledByProvider[providerID] = enabled
        defaults.set(enabled, forKey: Key.volumeSync(providerID: providerID))
    }

    func volumeSynchronizationPublisher(for providerID: String) -> AnyPublisher<Bool, Never> {
        $volumeSyncEnabledByProvider
            .map { $0[providerID] ?? false }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
