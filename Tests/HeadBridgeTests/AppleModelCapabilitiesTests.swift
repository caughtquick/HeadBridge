//
// Adapted from podctl (https://github.com/Rockykln/podctl)
// Copyright (c) 2026 pods contributors
// Licensed under the MIT License.
//

import XCTest
@testable import HeadBridge

final class AppleModelCapabilitiesTests: XCTestCase {
    func testKnownProductCodesResolveToTheirModel() {
        XCTAssertEqual(AppleModel.from(productCode: 0x2002), .gen1)
        XCTAssertEqual(AppleModel.from(productCode: 0x200F), .gen2)
        XCTAssertEqual(AppleModel.from(productCode: 0x2013), .gen3)
        XCTAssertEqual(AppleModel.from(productCode: 0x201B), .gen4Anc)
        XCTAssertEqual(AppleModel.from(productCode: 0x200E), .pro)
        XCTAssertEqual(AppleModel.from(productCode: 0x2014), .pro2)
        XCTAssertEqual(AppleModel.from(productCode: 0x2024), .pro2UsbC)
        XCTAssertEqual(AppleModel.from(productCode: 0x2027), .pro3)
        XCTAssertEqual(AppleModel.from(productCode: 0x200A), .max)
        XCTAssertEqual(AppleModel.from(productCode: 0x201F), .maxUsbC)
        XCTAssertEqual(AppleModel.from(productCode: 0x202D), .max2)
        XCTAssertEqual(AppleModel.from(productCode: 0x2017), .beatsStudioPro)
        XCTAssertEqual(AppleModel.from(productCode: 0x2025), .beatsSolo4)
    }

    func testModaliasParsing() {
        XCTAssertEqual(AppleModel.from(modalias: "bluetooth:v004Cp2024d0600"), .pro2UsbC)
        XCTAssertEqual(AppleModel.from(modalias: "bluetooth:v004Cp200Ad0100"), .max)
        XCTAssertEqual(AppleModel.from(modalias: "bluetooth:v004Cp201Bd0100"), .gen4Anc)
        // Non-Apple vendor ID (e.g. Sony v005D)
        XCTAssertEqual(AppleModel.from(modalias: "bluetooth:v005Dp0405d0100"), .unknown)
        XCTAssertEqual(AppleModel.from(modalias: "invalid"), .unknown)
    }

    func testPro2Capabilities() {
        let caps = AppleModel.pro2UsbC.capabilities
        XCTAssertTrue(caps.hasANC)
        XCTAssertTrue(caps.hasTransparency)
        XCTAssertTrue(caps.hasAdaptive)
        XCTAssertTrue(caps.hasConvAwareness)
        XCTAssertTrue(caps.hasPressVolume)
        XCTAssertTrue(caps.hasCaseBattery)
        XCTAssertTrue(caps.hasInEarDetection)
    }

    func testAirPodsMaxCapabilities() {
        let caps = AppleModel.max.capabilities
        XCTAssertTrue(caps.hasANC)
        XCTAssertTrue(caps.hasTransparency)
        XCTAssertFalse(caps.hasAdaptive)
        XCTAssertFalse(caps.hasConvAwareness)
        XCTAssertFalse(caps.hasCaseBattery)
        XCTAssertFalse(caps.hasInEarDetection)
        XCTAssertTrue(caps.hasSpatialAudio)
    }

    func testAirPodsGen3Capabilities() {
        let caps = AppleModel.gen3.capabilities
        XCTAssertFalse(caps.hasANC)
        XCTAssertFalse(caps.hasTransparency)
        XCTAssertFalse(caps.hasAdaptive)
        XCTAssertTrue(caps.hasCaseBattery)
        XCTAssertTrue(caps.hasInEarDetection)
        XCTAssertTrue(caps.hasSpatialAudio)
    }

    func testNameFallback() {
        XCTAssertEqual(AppleModel.from(name: "Abhijit’s AirPods Pro"), .pro)
        XCTAssertEqual(AppleModel.from(name: "AirPods Pro 2"), .pro2)
        XCTAssertEqual(AppleModel.from(name: "AirPods Max"), .max)
        XCTAssertEqual(AppleModel.from(name: "Beats Fit Pro"), .beatsFitPro)
        XCTAssertEqual(AppleModel.from(name: "Unknown Device"), .unknown)
    }
}
