//
// Adapted from podctl (https://github.com/Rockykln/podctl)
// Copyright (c) 2026 pods contributors
// Licensed under the MIT License.
//

import Foundation

public enum AppleModel: String, CaseIterable, Sendable {
    case gen1
    case gen2
    case gen3
    case gen4
    case gen4Anc
    case pro
    case pro2
    case pro2UsbC
    case pro3
    case max
    case maxUsbC
    case max2
    case beatsFitPro
    case beatsStudioPro
    case beatsStudioBudsPlus
    case beatsSolo4
    case beatsSoloBuds
    case unknown

    /// Bluetooth Modalias product code -> model.
    /// 0x2024 (Pro 2 USB-C) is hardware-verified; remainder cross-referenced
    /// with The Apple Wiki Bluetooth PIDs and OpenPods' BLE proximity-pair table.
    public static func from(productCode: UInt16) -> AppleModel {
        switch productCode {
        case 0x2002: return .gen1
        case 0x200F: return .gen2
        case 0x2013: return .gen3
        case 0x201B: return .gen4Anc
        case 0x200E: return .pro
        case 0x2014: return .pro2
        case 0x2024: return .pro2UsbC
        case 0x2027: return .pro3
        case 0x200A: return .max
        case 0x201F: return .maxUsbC
        case 0x202D: return .max2
        // Beats models with Apple silicon / AAP support
        case 0x2012: return .beatsFitPro
        case 0x2017: return .beatsStudioPro
        case 0x2019: return .beatsStudioBudsPlus
        case 0x2025: return .beatsSolo4
        case 0x2026: return .beatsSoloBuds
        default: return .unknown
        }
    }

    /// Extract product code from Linux BlueZ modalias string, e.g. "bluetooth:v004Cp2024d..."
    public static func from(modalias: String) -> AppleModel {
        let lower = modalias.lowercased()
        guard let vRange = lower.range(of: "v004c") else {
            return .unknown
        }
        let afterV = lower[vRange.upperBound...]
        guard let pRange = afterV.range(of: "p") else {
            return .unknown
        }
        let afterP = afterV[pRange.upperBound...]
        let hexString = String(afterP.prefix(4))
        guard hexString.count == 4, hexString.allSatisfy(\.isHexDigit), let code = UInt16(hexString, radix: 16) else {
            return .unknown
        }
        return from(productCode: code)
    }

    /// Fallback device model inference from Bluetooth broadcast name.
    public static func from(name: String) -> AppleModel {
        let lower = name.lowercased()
        if lower.contains("beats fit pro") {
            return .beatsFitPro
        } else if lower.contains("beats studio pro") {
            return .beatsStudioPro
        } else if lower.contains("beats studio buds") {
            return .beatsStudioBudsPlus
        } else if lower.contains("beats solo 4") {
            return .beatsSolo4
        } else if lower.contains("beats solo buds") {
            return .beatsSoloBuds
        } else if lower.contains("pro 2") || lower.contains("pro (2") || lower.contains("pro 2nd") {
            return .pro2
        } else if lower.contains("pro 3") {
            return .pro3
        } else if lower.contains("max") {
            return .max
        } else if lower.contains("pro") {
            return .pro
        } else if lower.contains("4") && lower.contains("anc") {
            return .gen4Anc
        } else if lower.contains("4") {
            return .gen4
        } else if lower.contains("3") {
            return .gen3
        } else if lower.contains("2") {
            return .gen2
        } else if lower.contains("1") {
            return .gen1
        }
        return .unknown
    }

    public var displayName: String {
        switch self {
        case .gen1: return "AirPods (1st gen)"
        case .gen2: return "AirPods (2nd gen)"
        case .gen3: return "AirPods (3rd gen)"
        case .gen4: return "AirPods 4"
        case .gen4Anc: return "AirPods 4 (ANC)"
        case .pro: return "AirPods Pro"
        case .pro2: return "AirPods Pro (2nd gen)"
        case .pro2UsbC: return "AirPods Pro (2nd gen, USB-C)"
        case .pro3: return "AirPods Pro (3rd gen)"
        case .max: return "AirPods Max"
        case .maxUsbC: return "AirPods Max (USB-C)"
        case .max2: return "AirPods Max (2nd gen)"
        case .beatsFitPro: return "Beats Fit Pro"
        case .beatsStudioPro: return "Beats Studio Pro"
        case .beatsStudioBudsPlus: return "Beats Studio Buds+"
        case .beatsSolo4: return "Beats Solo 4"
        case .beatsSoloBuds: return "Beats Solo Buds"
        case .unknown: return "AirPods / Apple Accessory"
        }
    }

    public var capabilities: AppleCapabilities {
        switch self {
        case .gen1, .gen2, .gen3, .gen4, .beatsSolo4, .beatsSoloBuds:
            return AppleCapabilities(
                model: self,
                hasANC: false,
                hasTransparency: false,
                hasAdaptive: false,
                hasConvAwareness: false,
                hasCaseBattery: true,
                hasInEarDetection: true,
                hasEarDetectionSetting: true,
                hasLoudSoundReduction: false,
                hasSpatialAudio: self == .gen3 || self == .gen4 || self == .beatsSolo4,
                hasPressVolume: false,
                hasPressAndHold: false,
                hasMicSelection: true,
                hasRename: true,
                hasToneOnPress: false
            )
        case .gen4Anc:
            return AppleCapabilities(
                model: self,
                hasANC: true,
                hasTransparency: true,
                hasAdaptive: true,
                hasConvAwareness: true,
                hasCaseBattery: true,
                hasInEarDetection: true,
                hasEarDetectionSetting: true,
                hasLoudSoundReduction: true,
                hasSpatialAudio: true,
                hasPressVolume: false,
                hasPressAndHold: true,
                hasMicSelection: true,
                hasRename: true,
                hasToneOnPress: true
            )
        case .pro, .beatsFitPro, .beatsStudioBudsPlus, .beatsStudioPro:
            return AppleCapabilities(
                model: self,
                hasANC: true,
                hasTransparency: true,
                hasAdaptive: false,
                hasConvAwareness: false,
                hasCaseBattery: self != .beatsStudioPro,
                hasInEarDetection: true,
                hasEarDetectionSetting: true,
                hasLoudSoundReduction: false,
                hasSpatialAudio: true,
                hasPressVolume: false,
                hasPressAndHold: true,
                hasMicSelection: true,
                hasRename: true,
                hasToneOnPress: true
            )
        case .pro2, .pro2UsbC, .pro3:
            return AppleCapabilities(
                model: self,
                hasANC: true,
                hasTransparency: true,
                hasAdaptive: true,
                hasConvAwareness: true,
                hasCaseBattery: true,
                hasInEarDetection: true,
                hasEarDetectionSetting: true,
                hasLoudSoundReduction: true,
                hasSpatialAudio: true,
                hasPressVolume: true,
                hasPressAndHold: true,
                hasMicSelection: true,
                hasRename: true,
                hasToneOnPress: true
            )
        case .max, .maxUsbC, .max2:
            return AppleCapabilities(
                model: self,
                hasANC: true,
                hasTransparency: true,
                hasAdaptive: false,
                hasConvAwareness: false,
                hasCaseBattery: false,
                hasInEarDetection: false,
                hasEarDetectionSetting: false,
                hasLoudSoundReduction: true,
                hasSpatialAudio: true,
                hasPressVolume: false,
                hasPressAndHold: true,
                hasMicSelection: false,
                hasRename: true,
                hasToneOnPress: false
            )
        case .unknown:
            return AppleCapabilities.conservative(self)
        }
    }
}

public struct AppleCapabilities: Equatable, Sendable {
    public let model: AppleModel
    public let hasANC: Bool
    public let hasTransparency: Bool
    public let hasAdaptive: Bool
    public let hasConvAwareness: Bool
    public let hasCaseBattery: Bool
    public let hasInEarDetection: Bool
    public let hasEarDetectionSetting: Bool
    public let hasLoudSoundReduction: Bool
    public let hasSpatialAudio: Bool
    public let hasPressVolume: Bool
    public let hasPressAndHold: Bool
    public let hasMicSelection: Bool
    public let hasRename: Bool
    public let hasToneOnPress: Bool

    public init(
        model: AppleModel,
        hasANC: Bool,
        hasTransparency: Bool,
        hasAdaptive: Bool,
        hasConvAwareness: Bool,
        hasCaseBattery: Bool,
        hasInEarDetection: Bool,
        hasEarDetectionSetting: Bool,
        hasLoudSoundReduction: Bool,
        hasSpatialAudio: Bool,
        hasPressVolume: Bool,
        hasPressAndHold: Bool,
        hasMicSelection: Bool,
        hasRename: Bool,
        hasToneOnPress: Bool
    ) {
        self.model = model
        self.hasANC = hasANC
        self.hasTransparency = hasTransparency
        self.hasAdaptive = hasAdaptive
        self.hasConvAwareness = hasConvAwareness
        self.hasCaseBattery = hasCaseBattery
        self.hasInEarDetection = hasInEarDetection
        self.hasEarDetectionSetting = hasEarDetectionSetting
        self.hasLoudSoundReduction = hasLoudSoundReduction
        self.hasSpatialAudio = hasSpatialAudio
        self.hasPressVolume = hasPressVolume
        self.hasPressAndHold = hasPressAndHold
        self.hasMicSelection = hasMicSelection
        self.hasRename = hasRename
        self.hasToneOnPress = hasToneOnPress
    }

    public static func conservative(_ model: AppleModel = .unknown) -> AppleCapabilities {
        AppleCapabilities(
            model: model,
            hasANC: false,
            hasTransparency: false,
            hasAdaptive: false,
            hasConvAwareness: false,
            hasCaseBattery: true,
            hasInEarDetection: false,
            hasEarDetectionSetting: false,
            hasLoudSoundReduction: false,
            hasSpatialAudio: false,
            hasPressVolume: false,
            hasPressAndHold: false,
            hasMicSelection: false,
            hasRename: true,
            hasToneOnPress: false
        )
    }
}
