//
// Adapted from podctl (https://github.com/Rockykln/podctl)
// Copyright (c) 2026 pods contributors
// Licensed under the MIT License.
//

import XCTest
@testable import HeadBridge

final class AAPProtocolTests: XCTestCase {
    func testFrameRoundtrip() {
        let frame = AAPProtocol.Frame(
            opcode: AAPProtocol.Opcode.settings.rawValue,
            subop: 0x00,
            payload: Data([AAPProtocol.SettingID.noiseControl.rawValue, 0x02, 0, 0, 0])
        )
        let encoded = frame.encode()
        let expected: [UInt8] = [
            0x04, 0x00, 0x04, 0x00,
            0x09, 0x00,
            AAPProtocol.SettingID.noiseControl.rawValue,
            0x02, 0, 0, 0
        ]
        XCTAssertEqual([UInt8](encoded), expected)

        let parsed = AAPProtocol.Frame.parse(encoded)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.opcode, 0x09)
        XCTAssertEqual(parsed?.subop, 0x00)
        XCTAssertEqual(parsed?.payload, Data([AAPProtocol.SettingID.noiseControl.rawValue, 0x02, 0, 0, 0]))
    }

    func testFrameParseAcceptsHandshakeReplyMagic() {
        // Handshake response uses `01 00 04 00` as the first 4 bytes
        let bytes: [UInt8] = [0x01, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x03, 0x00]
        let parsed = AAPProtocol.Frame.parse(Data(bytes))
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.opcode, 0x00)
    }

    func testFrameParseRejectsMalformed() {
        XCTAssertNil(AAPProtocol.Frame.parse(Data()))
        XCTAssertNil(AAPProtocol.Frame.parse(Data([0xFF, 0xFF, 0xFF])))
        // Wrong magic: 04 00 [05 00]
        XCTAssertNil(AAPProtocol.Frame.parse(Data([0x04, 0x00, 0x05, 0x00, 0x00, 0x00])))
    }

    func testBatteryDecodesExampleFromDoc() {
        // Example from LibrePods AAP Definitions & podctl test suite:
        // 03 02 01 64 02 01 04 01 63 01 01 08 01 11 02 01
        // = Right 100% discharging, Left 99% charging, Case 17% discharging.
        let payload: [UInt8] = [
            0x03, 0x02, 0x01, 0x64, 0x02, 0x01, 0x04, 0x01, 0x63, 0x01, 0x01, 0x08, 0x01, 0x11, 0x02, 0x01
        ]
        let comps = AAPProtocol.parseBattery(payload: Data(payload))
        XCTAssertEqual(comps.count, 3)

        XCTAssertEqual(comps[0].kind, .right)
        XCTAssertEqual(comps[0].level, 100)
        XCTAssertEqual(comps[0].status, .discharging)

        XCTAssertEqual(comps[1].kind, .left)
        XCTAssertEqual(comps[1].level, 99)
        XCTAssertEqual(comps[1].status, .charging)

        XCTAssertEqual(comps[2].kind, .caseKind)
        XCTAssertEqual(comps[2].level, 17)
        XCTAssertEqual(comps[2].status, .discharging)
    }

    func testBatteryHandlesShortPayloads() {
        XCTAssertTrue(AAPProtocol.parseBattery(payload: Data()).isEmpty)
        // Claims 3 components but only carries 1 full component
        let shortPayload: [UInt8] = [3, 2, 1, 50, 2, 1]
        let comps = AAPProtocol.parseBattery(payload: Data(shortPayload))
        XCTAssertEqual(comps.count, 1)
        XCTAssertEqual(comps[0].kind, .right)
        XCTAssertEqual(comps[0].level, 50)
    }

    func testInEarMapsStatuses() {
        // primary=in-ear, secondary=in-case
        let status1 = AAPProtocol.parseInEar(payload: Data([0x00, 0x02]))
        XCTAssertEqual(status1?.primary, .inEar)
        XCTAssertEqual(status1?.secondary, .inCase)

        // primary=out, secondary=in-ear
        let status2 = AAPProtocol.parseInEar(payload: Data([0x01, 0x00]))
        XCTAssertEqual(status2?.primary, .outOfEar)
        XCTAssertEqual(status2?.secondary, .inEar)

        // fallback to unknown
        let status3 = AAPProtocol.parseInEar(payload: Data([0x99, 0x00]))
        XCTAssertEqual(status3?.primary, .unknown)
        XCTAssertEqual(status3?.secondary, .inEar)

        // Too short
        XCTAssertNil(AAPProtocol.parseInEar(payload: Data([0x00])))
    }

    func testModelNumberExtraction() {
        var payload = Data([0x02, 0x40, 0x00, 0x04, 0x00])
        for field in ["Test AirPods", "A3047", "Apple Inc.", "XXXXXXXXXX", "1.0.0"] {
            payload.append(contentsOf: field.utf8)
            payload.append(0)
        }
        XCTAssertEqual(AAPProtocol.parseModelNumber(payload: payload), "A3047")
    }

    func testProximityPairExtractsModelCode() {
        // 07 19 <flags> <model_lo> <model_hi> ...
        // Model 0x2024 = AirPods Pro 2 USB-C
        let data: [UInt8] = [0x07, 0x19, 0x01, 0x24, 0x20, 0x00, 0x00, 0x00]
        XCTAssertEqual(AAPProtocol.parseProximityPair(data: Data(data)), 0x2024)

        // Wrong type byte
        let invalidData: [UInt8] = [0x08, 0x19, 0x01, 0x24, 0x20, 0x00, 0x00, 0x00]
        XCTAssertNil(AAPProtocol.parseProximityPair(data: Data(invalidData)))
    }

    func testSettingsFrameEncodersAndDecoders() {
        let frame = AAPProtocol.setNoiseControl(.adaptive)
        let encoded = frame.encode()
        let parsed = AAPProtocol.Frame.parse(encoded)
        XCTAssertNotNil(parsed)

        let notice = AAPProtocol.SettingNotice.parse(from: parsed!)
        XCTAssertNotNil(notice)
        XCTAssertEqual(notice?.id, AAPProtocol.SettingID.noiseControl.rawValue)
        XCTAssertEqual(notice?.data.first, AAPProtocol.ListeningMode.adaptive.rawValue)

        let convFrame = AAPProtocol.setConversationAwareness(true)
        let convParsed = AAPProtocol.Frame.parse(convFrame.encode())
        let convNotice = AAPProtocol.SettingNotice.parse(from: convParsed!)
        XCTAssertEqual(convNotice?.id, AAPProtocol.SettingID.convAware.rawValue)
        XCTAssertEqual(convNotice?.data.first, 1)

        let convOffFrame = AAPProtocol.setConversationAwareness(false)
        let convOffParsed = AAPProtocol.Frame.parse(convOffFrame.encode())
        let convOffNotice = AAPProtocol.SettingNotice.parse(from: convOffParsed!)
        XCTAssertEqual(convOffNotice?.data.first, 2)
    }
}
