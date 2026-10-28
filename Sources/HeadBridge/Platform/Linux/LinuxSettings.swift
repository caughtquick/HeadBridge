import Foundation

#if !os(macOS)
public struct LinuxHeadphoneProfile: Codable, Equatable, Sendable {
    public var noiseMode: String?
    public var ambientLevel: Int?
    public var bassLevel: Int?
    public var trebleLevel: Int?
    public var eqBands: [Int]?

    public init(
        noiseMode: String? = nil,
        ambientLevel: Int? = nil,
        bassLevel: Int? = nil,
        trebleLevel: Int? = nil,
        eqBands: [Int]? = nil
    ) {
        self.noiseMode = noiseMode
        self.ambientLevel = ambientLevel
        self.bassLevel = bassLevel
        self.trebleLevel = trebleLevel
        self.eqBands = eqBands
    }
}

public struct LinuxAppSettingsData: Codable, Equatable, Sendable {
    public var volumeSyncEnabled: [String: Bool] = [
        "bowers-wilkins": true,
        "sony-mdr": true
    ]
    public var restoreOnConnectEnabled: [String: Bool] = [
        "bowers-wilkins": true,
        "sony-mdr": true
    ]
    public var profiles: [String: LinuxHeadphoneProfile] = [:]

    public init() {}
}

@MainActor
public final class LinuxSettingsStore {
    public static let shared = LinuxSettingsStore()

    public private(set) var data: LinuxAppSettingsData

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        let target = fileURL ?? AppPlatformPaths.configDirectory.appendingPathComponent("settings.json")
        self.fileURL = target

        if FileManager.default.fileExists(atPath: target.path),
           let rawData = try? Data(contentsOf: target),
           let decoded = try? JSONDecoder().decode(LinuxAppSettingsData.self, from: rawData) {
            self.data = decoded
        } else {
            self.data = LinuxAppSettingsData()
        }
    }

    public func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? encoder.encode(data) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }

    public func isVolumeSyncEnabled(for providerID: String) -> Bool {
        data.volumeSyncEnabled[providerID] ?? true
    }

    public func setVolumeSyncEnabled(_ enabled: Bool, for providerID: String) {
        data.volumeSyncEnabled[providerID] = enabled
        save()
    }

    public func isRestoreOnConnectEnabled(for providerID: String) -> Bool {
        data.restoreOnConnectEnabled[providerID] ?? true
    }

    public func setRestoreOnConnectEnabled(_ enabled: Bool, for providerID: String) {
        data.restoreOnConnectEnabled[providerID] = enabled
        save()
    }

    public func profile(for deviceID: String) -> LinuxHeadphoneProfile? {
        data.profiles[deviceID.lowercased()]
    }

    public func saveProfile(_ profile: LinuxHeadphoneProfile, for deviceID: String) {
        data.profiles[deviceID.lowercased()] = profile
        save()
    }
}
#endif
