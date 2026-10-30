//
// Adapted from podctl (https://github.com/Rockykln/podctl)
// Copyright (c) 2026 pods contributors
// Licensed under the MIT License.
//

import Foundation

/// Apple Accessory Protocol over L2CAP PSM 0x1001.
public enum AAPProtocol {
    public static let psm: UInt16 = 0x1001
    public static let frameMagic: [UInt8] = [0x04, 0x00, 0x04, 0x00]
    public static let handshakeReplyMagic: [UInt8] = [0x01, 0x00, 0x04, 0x00]

    public enum Opcode: UInt8, Sendable {
        case handshake = 0x00
        case battery = 0x04
        case earDetection = 0x06
        case settings = 0x09
        case subscribeNotif = 0x0F
        case metadata = 0x1D
        case rename = 0x1A
        case requestInfo = 0x30
        case proximityKeys = 0x31
        case convAwarenessLvl = 0x4B
        case featureFlags = 0x4D
    }

    public enum SettingID: UInt8, Sendable {
        case micMode = 0x01       // 0=auto, 1=right, 2=left
        case earDetection = 0x0A // 1=enabled, 2=disabled
        case noiseControl = 0x0D // 1=Off, 2=NC, 3=Transparency, 4=Adaptive
        case oneBudANC = 0x1B    // 1=enabled, 2=disabled
        case chimeVolume = 0x1F  // 0..100
        case convAware = 0x28    // 1=enabled, 2=disabled
        case autoANCLevel = 0x2E // 0..100
    }

    public enum BatteryKind: UInt8, Sendable {
        case right = 0x02
        case left = 0x04
        case caseKind = 0x08
    }

    public enum BatteryStatus: UInt8, Sendable {
        case unknown = 0x00
        case charging = 0x01
        case discharging = 0x02
        case disconnected = 0x04
    }

    public enum EarStatus: UInt8, Sendable {
        case inEar = 0x00
        case outOfEar = 0x01
        case inCase = 0x02
        case unknown = 0xFF
    }

    public enum ListeningMode: UInt8, CaseIterable, Sendable {
        case off = 0x01
        case noiseCancellation = 0x02
        case transparency = 0x03
        case adaptive = 0x04
    }

    public enum MicSelection: UInt8, Sendable {
        case auto = 0x00
        case alwaysRight = 0x01
        case alwaysLeft = 0x02
    }

    public struct BatteryComponent: Equatable, Sendable {
        public let kind: BatteryKind
        public let level: UInt8 // 0..=100
        public let status: BatteryStatus

        public init(kind: BatteryKind, level: UInt8, status: BatteryStatus) {
            self.kind = kind
            self.level = level
            self.status = status
        }
    }

    public struct InEarStatus: Equatable, Sendable {
        public let primary: EarStatus
        public let secondary: EarStatus

        public init(primary: EarStatus, secondary: EarStatus) {
            self.primary = primary
            self.secondary = secondary
        }
    }

    public struct ProximityKeys: Equatable, Sendable {
        public let irk: [UInt8] // 16 bytes, big-endian / spec order
        public let enc: [UInt8] // 16 bytes, big-endian / spec order

        public init(irk: [UInt8], enc: [UInt8]) {
            self.irk = irk
            self.enc = enc
        }
    }

    public struct Frame: Equatable, Sendable {
        public let opcode: UInt8
        public let subop: UInt8
        public let payload: Data

        public init(opcode: UInt8, subop: UInt8, payload: Data = Data()) {
            self.opcode = opcode
            self.subop = subop
            self.payload = payload
        }

        public init(opcode: Opcode, subop: UInt8, payload: Data = Data()) {
            self.opcode = opcode.rawValue
            self.subop = subop
            self.payload = payload
        }

        public func encode() -> Data {
            var data = Data(AAPProtocol.frameMagic)
            data.append(opcode)
            data.append(subop)
            data.append(payload)
            return data
        }

        public static func parse(_ data: Data) -> Frame? {
            // Outgoing frames use 04 00 04 00, incoming 04 00 04 00 too in steady
            // state; the handshake reply uses 01 00 04 00. Be lenient on byte 0
            // since the rest of the magic (00 04 00) is stable.
            guard data.count >= 6 else { return nil }
            if data[1] != 0x00 || data[2] != 0x04 || data[3] != 0x00 {
                return nil
            }
            return Frame(
                opcode: data[4],
                subop: data[5],
                payload: data.subdata(in: 6..<data.count)
            )
        }
    }

    public struct SettingNotice: Equatable, Sendable {
        public let id: UInt8
        public let data: Data

        public static func parse(from frame: Frame) -> SettingNotice? {
            guard frame.opcode == Opcode.settings.rawValue, !frame.payload.isEmpty else {
                return nil
            }
            return SettingNotice(
                id: frame.payload[0],
                data: frame.payload.subdata(in: 1..<frame.payload.count)
            )
        }
    }

    // MARK: - Frame Builders

    /// Raw handshake frame required by AirPods Pro 2 and modern AAP firmware (16 bytes).
    public static let handshakeRawBytes: [UInt8] = [
        0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ]

    /// Feature flag packet with mask 0xD7 required to enable battery notifications on AirPods Pro 2.
    public static let setFeaturesPro2Bytes: [UInt8] = [
        0x04, 0x00, 0x04, 0x00, 0x4D, 0x00, 0xD7, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ]

    public static func handshakeFrame() -> Frame {
        Frame(opcode: .handshake, subop: 0x01, payload: Data([0x01, 0x00, 0x02, 0x00]))
    }

    /// Subscribes to unsolicited telemetry notifications (opcode 0x0F, subop 0x00, 5 bytes of 0xFF).
    public static func subscribeNotificationsFrame() -> Frame {
        Frame(opcode: .subscribeNotif, subop: 0x00, payload: Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
    }

    public static func writeSetting(id: UInt8, value: UInt8) -> Frame {
        Frame(opcode: .settings, subop: 0x00, payload: Data([id, value, 0x00, 0x00, 0x00]))
    }

    public static func setNoiseControl(_ mode: ListeningMode) -> Frame {
        writeSetting(id: SettingID.noiseControl.rawValue, value: mode.rawValue)
    }

    public static func setConversationAwareness(_ on: Bool) -> Frame {
        writeSetting(id: SettingID.convAware.rawValue, value: on ? 1 : 2)
    }

    public static func setEarDetection(_ on: Bool) -> Frame {
        writeSetting(id: SettingID.earDetection.rawValue, value: on ? 1 : 2)
    }

    public static func setMicMode(_ mic: MicSelection) -> Frame {
        writeSetting(id: SettingID.micMode.rawValue, value: mic.rawValue)
    }

    public static func requestKeys() -> Frame {
        Frame(opcode: .requestInfo, subop: 0x00, payload: Data([0x05, 0x00]))
    }

    // MARK: - Decoders (Adapted from podctl/src/aap.rs)

    /// Decodes a BATTERY notification payload (everything after 04 00 04 00 04 00).
    /// Layout: [count] ([component] 01 [level] [status] 01) × count
    public static func parseBattery(payload: Data) -> [BatteryComponent] {
        guard !payload.isEmpty else { return [] }
        let declared = Int(payload[0])
        let maxFit = (payload.count - 1) / 5
        let count = min(declared, maxFit)
        var out: [BatteryComponent] = []
        out.reserveCapacity(count)

        var idx = 1
        for _ in 0..<count {
            if idx + 5 > payload.count { break }
            let kindRaw = payload[idx]
            let level = payload[idx + 2]
            let statusRaw = payload[idx + 3]

            let kind = BatteryKind(rawValue: kindRaw) ?? .caseKind
            let status = BatteryStatus(rawValue: statusRaw) ?? .unknown
            out.append(BatteryComponent(kind: kind, level: level, status: status))
            idx += 5
        }
        return out
    }

    /// Decodes an EAR_DETECTION (0x06) notification payload.
    /// Layout: [primary] [secondary]
    public static func parseInEar(payload: Data) -> InEarStatus? {
        guard payload.count >= 2 else { return nil }
        let primary = EarStatus(rawValue: payload[0]) ?? .unknown
        let secondary = EarStatus(rawValue: payload[1]) ?? .unknown
        return InEarStatus(primary: primary, secondary: secondary)
    }

    /// Parses Apple's model number (e.g. "A3047") from NUL-separated metadata strings.
    public static func parseModelNumber(payload: Data) -> String? {
        let slices = payload.split(separator: 0)
        let strings = slices.compactMap { String(data: Data($0), encoding: .utf8) }
        for i in 0..<(strings.count - 1) {
            let name = strings[i]
            let candidate = strings[i + 1]
            let isNameValid = !name.isEmpty && name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
            let isModelValid = candidate.count == 5 && candidate.starts(with: "A") && candidate.dropFirst().allSatisfy { $0.isNumber }
            if isNameValid && isModelValid {
                return candidate
            }
        }
        return nil
    }

    /// Decodes 16-byte proximity keys (IRK & ENC) from PROXIMITY_KEYS (0x31) reply.
    public static func parseKeys(payload: Data) -> ProximityKeys? {
        guard payload.count > 1 else { return nil }
        var irk: [UInt8]?
        var enc: [UInt8]?
        var rest = payload.subdata(in: 1..<payload.count)

        while rest.count >= 4 {
            let kind = rest[0]
            let len = Int(UInt16(rest[1]) << 8 | UInt16(rest[2]))
            guard rest.count >= 4 + len else { break }
            let body = rest.subdata(in: 4..<(4 + len))
            if len == 16 {
                var keyBytes = [UInt8](body)
                keyBytes.reverse() // Reverse LSB to MSB spec order
                if kind == 1 {
                    irk = keyBytes
                } else if kind == 4 {
                    enc = keyBytes
                }
            }
            rest = rest.subdata(in: (4 + len)..<rest.count)
        }

        guard let validIrk = irk, let validEnc = enc else { return nil }
        return ProximityKeys(irk: validIrk, enc: validEnc)
    }

    /// Decodes proximity BLE advertisement pairing packet (0x07 0x19 ...).
    public static func parseProximityPair(data: Data) -> UInt16? {
        guard data.count >= 8 else { return nil }
        guard data[0] == 0x07 && data[1] == 0x19 else { return nil }
        return UInt16(data[3]) | (UInt16(data[4]) << 8)
    }
}
