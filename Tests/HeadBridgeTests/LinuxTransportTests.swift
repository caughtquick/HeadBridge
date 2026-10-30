import Foundation
import XCTest
@testable import HeadBridge

final class LinuxTransportTests: XCTestCase {

    func testLinuxCommandRunnerFindExecutable() {
        let runner = LinuxCommandRunner.shared
        XCTAssertNotNil(runner.findExecutable("sh"))
        XCTAssertNil(runner.findExecutable("non_existent_executable_12345"))
    }


    @MainActor
    func testLinuxBowersWilkinsTransportStateTransitionsAndSimulation() async {
        let transport = LinuxBowersWilkinsTransport()
        XCTAssertEqual(transport.connectionState, .idle)
        XCTAssertNil(transport.connectedDeviceAddress)
        XCTAssertNil(transport.connectedDeviceName)

        var states: [HeadphoneConnectionState] = []
        transport.onConnectionStateChange = { states.append($0) }

        var receivedResponses: [Data] = []
        transport.onResponseData = { receivedResponses.append($0) }

        var receivedNotifications: [Data] = []
        transport.onNotificationData = { receivedNotifications.append($0) }

        var logs: [(TransportLogEntry.Direction, String)] = []
        transport.onLog = { direction, msg in logs.append((direction, msg)) }

        // Test state simulation
        transport.simulateStateChange(.connecting)
        transport.simulateStateChange(.ready)
        XCTAssertEqual(states, [.connecting, .ready])
        XCTAssertEqual(transport.connectionState, .ready)

        // Test response simulation
        let testResponse = Data([0x0C, 0x92, 0x18, 0x04, 0x00, 0x00, 0x01, 0x00, 0x05])
        transport.simulateResponse(testResponse)
        XCTAssertEqual(receivedResponses, [testResponse])

        // Test notification simulation
        let testNotif = Data([0x04, 0x0B, 0x12, 0x01, 0x03])
        transport.simulateNotification(testNotif)
        XCTAssertEqual(receivedNotifications, [testNotif])

        // Test disconnect
        transport.disconnect()
        XCTAssertEqual(transport.connectionState, .idle)
        XCTAssertEqual(states, [.connecting, .ready, .idle])
    }

    @MainActor
    func testLinuxSonyRFCOMMTransportInitialStateAndSimulation() async {
        let transport = LinuxSonyRFCOMMTransport()
        XCTAssertEqual(transport.status, .idle)

        var statusHistory: [SonyRFCOMMStatus] = []
        transport.onStatusChange = { statusHistory.append($0) }

        var dataHistory: [Data] = []
        transport.onData = { dataHistory.append($0) }

        // Disconnect on idle should be a no-op
        transport.disconnect()
        XCTAssertEqual(transport.status, .idle)
    }

    @MainActor
    func testLinuxPipeWireAudioSimulationAndVolumePublishers() async {
        let audio = LinuxPipeWireAudio()
        let testSinks = [
            SystemAudioDevice(
                id: 10,
                uid: "bluez_output.EC_66_D1_BE_1D_80.1",
                name: "Abhijit’s Px7 S2e",
                transportType: kAudioDeviceTransportTypeBluetooth
            ),
            SystemAudioDevice(
                id: 20,
                uid: "alsa_output.pci-speaker",
                name: "Internal Speakers",
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
        ]

        let exp = expectation(description: "Audio devices published")
        let sub = audio.devicesPublisher.dropFirst().sink { devices in
            XCTAssertEqual(devices.count, 2)
            XCTAssertTrue(devices.first?.isBluetooth ?? false)
            exp.fulfill()
        }

        audio.simulateDevices(testSinks, defaultID: 10, defaultVol: 0.75)

        await fulfillment(of: [exp], timeout: 1)
        withExtendedLifetime(sub) {}

        XCTAssertEqual(audio.devices.count, 2)
        XCTAssertEqual(audio.defaultDeviceID, 10)
        XCTAssertEqual(audio.volume, 0.75)

        // Test volume simulation
        let volExp = expectation(description: "Volume changed")
        let volSub = audio.volumePublisher.dropFirst().sink { vol in
            XCTAssertEqual(vol, 0.50)
            volExp.fulfill()
        }

        audio.simulateVolumeChange(0.50)
        await fulfillment(of: [volExp], timeout: 1)
        withExtendedLifetime(volSub) {}

        XCTAssertEqual(audio.volume, 0.50)
    }

    @MainActor
    func testLinuxSettingsStorePersistence() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeadBridgeTestSettings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = LinuxSettingsStore(fileURL: tempURL)

        XCTAssertTrue(store.isVolumeSyncEnabled(for: "bowers-wilkins"))
        store.setVolumeSyncEnabled(false, for: "bowers-wilkins")
        XCTAssertFalse(store.isVolumeSyncEnabled(for: "bowers-wilkins"))

        XCTAssertTrue(store.isRestoreOnConnectEnabled(for: "bowers-wilkins"))
        store.setRestoreOnConnectEnabled(false, for: "bowers-wilkins")
        XCTAssertFalse(store.isRestoreOnConnectEnabled(for: "bowers-wilkins"))

        let testProfile = LinuxHeadphoneProfile(
            noiseMode: "noiseCancellation",
            ambientLevel: nil,
            bassLevel: 10,
            trebleLevel: -5,
            eqBands: nil
        )
        store.saveProfile(testProfile, for: "mac:ec:66:d1:be:1d:80")

        // Reload store from disk
        let reloadedStore = LinuxSettingsStore(fileURL: tempURL)
        XCTAssertFalse(reloadedStore.isVolumeSyncEnabled(for: "bowers-wilkins"))
        XCTAssertFalse(reloadedStore.isRestoreOnConnectEnabled(for: "bowers-wilkins"))
        let loadedProfile = reloadedStore.profile(for: "mac:ec:66:d1:be:1d:80")
        XCTAssertEqual(loadedProfile, testProfile)
        XCTAssertEqual(loadedProfile?.bassLevel, 10)
        XCTAssertEqual(loadedProfile?.trebleLevel, -5)
    }

    func testAppPlatformPathsOnLinux() {
        let config = AppPlatformPaths.configDirectory
        let data = AppPlatformPaths.dataDirectory
        let state = AppPlatformPaths.stateDirectory

        XCTAssertTrue(config.path.contains("headbridge") || config.path.contains("HeadBridge"))
        XCTAssertTrue(data.path.contains("headbridge") || data.path.contains("HeadBridge"))
        XCTAssertTrue(state.path.contains("headbridge") || state.path.contains("HeadBridge"))
    }
}
