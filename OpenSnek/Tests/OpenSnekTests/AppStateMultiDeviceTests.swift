import Foundation
import XCTest
import OpenSnekCore
@testable import OpenSnek

final class AppStateMultiDeviceTests: XCTestCase {
    func testRefreshDevicesRefreshesAllDeviceCachesAndKeepsSelectedPresentationStable() async {
        let alphaDevice = makeTestDevice(
            id: "alpha-device",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "ALPHA",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let betaDevice = makeTestDevice(
            id: "beta-device",
            productName: "Beta Mouse",
            transport: .bluetooth,
            serial: "BETA",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let backend = MultiDeviceStubBackend(
            devices: [betaDevice, alphaDevice],
            stateByDeviceID: [
                alphaDevice.id: makeTestState(
                    device: alphaDevice,
                    connection: "usb",
                    batteryPercent: 81,
                    dpiValues: [1200, 2400, 3600],
                    activeStage: 0,
                    dpiValue: 1200
                ),
                betaDevice.id: makeTestState(
                    device: betaDevice,
                    connection: "bluetooth",
                    batteryPercent: 72,
                    dpiValues: [3200, 4800, 6400],
                    activeStage: 1,
                    dpiValue: 4800
                ),
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.refreshDevices()

        let selectedDeviceID = await MainActor.run { appState.selectedDeviceID }
        let selectedDpi = await MainActor.run { appState.state?.dpi?.x }
        let initialReadOrder = await backend.recordedReadOrder()

        XCTAssertEqual(selectedDeviceID, alphaDevice.id)
        XCTAssertEqual(selectedDpi, 1200)
        XCTAssertEqual(initialReadOrder, [alphaDevice.id, betaDevice.id])

        await MainActor.run {
            appState.selectDevice(betaDevice.id)
        }

        let betaDpi = await MainActor.run { appState.state?.dpi?.x }
        let activeStage = await MainActor.run { appState.editableActiveStage }
        let readCountAfterSelection = await backend.readCount()

        XCTAssertEqual(betaDpi, 4800)
        XCTAssertEqual(activeStage, 2)
        XCTAssertEqual(readCountAfterSelection, 2)
    }

    func testRemotePresenceSelectedDeviceDrivesServiceInteractivePollingUntilExpiry() async {
        let suiteName = "AppStateMultiDeviceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: UserDefaults(suiteName: suiteName)!)
        }
        let appState = await MainActor.run {
            AppState(launchRole: .service, serviceCoordinator: coordinator, autoStart: false)
        }
        let alphaDevice = makeTestDevice(
            id: "alpha-device",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "ALPHA",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let betaDevice = makeTestDevice(
            id: "beta-device",
            productName: "Beta Mouse",
            transport: .usb,
            serial: "BETA",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let now = Date(timeIntervalSince1970: 1_773_400_000)

        await MainActor.run {
            appState.devices = [alphaDevice, betaDevice]
            appState.selectedDeviceID = betaDevice.id
            appState.recordRemoteClientPresence(
                CrossProcessClientPresence(sourceProcessID: 41, selectedDeviceID: alphaDevice.id),
                now: now
            )
        }

        let activeProfile = await MainActor.run { appState.pollingProfile(at: now) }
        let activeDeviceIDs = await MainActor.run { appState.activeFastPollingDeviceIDs(at: now) }
        let expiredProfile = await MainActor.run { appState.pollingProfile(at: now.addingTimeInterval(3.0)) }
        let expiredDeviceIDs = await MainActor.run { appState.activeFastPollingDeviceIDs(at: now.addingTimeInterval(3.0)) }
        let selectedDeviceID = await MainActor.run { appState.selectedDeviceID }

        XCTAssertEqual(selectedDeviceID, betaDevice.id)
        XCTAssertEqual(activeProfile, .serviceInteractive)
        XCTAssertEqual(activeDeviceIDs, [alphaDevice.id])
        XCTAssertEqual(expiredProfile, .serviceIdle)
        XCTAssertTrue(expiredDeviceIDs.isEmpty)
    }

    func testServiceFastPollingUnionIncludesLocalAndRemoteSelections() async {
        let suiteName = "AppStateMultiDeviceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: UserDefaults(suiteName: suiteName)!)
        }
        let appState = await MainActor.run {
            AppState(launchRole: .service, serviceCoordinator: coordinator, autoStart: false)
        }
        let alphaDevice = makeTestDevice(
            id: "alpha-device",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "ALPHA",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let betaDevice = makeTestDevice(
            id: "beta-device",
            productName: "Beta Mouse",
            transport: .usb,
            serial: "BETA",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let now = Date(timeIntervalSince1970: 1_773_400_100)

        await MainActor.run {
            appState.devices = [alphaDevice, betaDevice]
            appState.selectedDeviceID = betaDevice.id
            appState.setCompactMenuPresented(true)
            appState.recordRemoteClientPresence(
                CrossProcessClientPresence(sourceProcessID: 42, selectedDeviceID: alphaDevice.id),
                now: now
            )
        }

        let profile = await MainActor.run { appState.pollingProfile(at: now) }
        let activeDeviceIDs = await MainActor.run { appState.activeFastPollingDeviceIDs(at: now) }

        XCTAssertEqual(profile, .serviceInteractive)
        XCTAssertEqual(activeDeviceIDs, [betaDevice.id, alphaDevice.id])
    }
}

private actor MultiDeviceStubBackend: DeviceBackend {
    nonisolated var usesRemoteServiceTransport: Bool { false }

    private let devices: [MouseDevice]
    private let stateByDeviceID: [String: MouseState]
    private var readOrder: [String] = []

    init(devices: [MouseDevice], stateByDeviceID: [String: MouseState]) {
        self.devices = devices
        self.stateByDeviceID = stateByDeviceID
    }

    func listDevices() async throws -> [MouseDevice] {
        devices
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        readOrder.append(device.id)
        guard let state = stateByDeviceID[device.id] else {
            throw NSError(domain: "AppStateMultiDeviceTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing stub state for \(device.id)"
            ])
        }
        return state
    }

    func readDpiStagesFast(device _: MouseDevice) async throws -> DpiFastSnapshot? {
        nil
    }

    func apply(device _: MouseDevice, patch _: DevicePatch) async throws -> MouseState {
        throw NSError(domain: "AppStateMultiDeviceTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "apply not implemented"
        ])
    }

    func readLightingColor(device _: MouseDevice) async throws -> RGBPatch? {
        nil
    }

    func debugUSBReadButtonBinding(device _: MouseDevice, slot _: Int, profile _: Int) async throws -> [UInt8]? {
        nil
    }

    func recordedReadOrder() -> [String] {
        readOrder
    }

    func readCount() -> Int {
        readOrder.count
    }
}

private func makeTestDevice(
    id: String,
    productName: String,
    transport: DeviceTransportKind,
    serial: String,
    locationID: Int,
    profile: DeviceProfileID
) -> MouseDevice {
    MouseDevice(
        id: id,
        vendor_id: 0x1532,
        product_id: transport == .bluetooth ? 0x00BA : 0x00AB,
        product_name: productName,
        transport: transport,
        path_b64: "",
        serial: serial,
        firmware: "1.0.0",
        location_id: locationID,
        profile_id: profile,
        supports_advanced_lighting_effects: true,
        onboard_profile_count: 1
    )
}

private func makeTestState(
    device: MouseDevice,
    connection: String,
    batteryPercent: Int,
    dpiValues: [Int],
    activeStage: Int,
    dpiValue: Int
) -> MouseState {
    MouseState(
        device: DeviceSummary(
            id: device.id,
            product_name: device.product_name,
            serial: device.serial,
            transport: device.transport,
            firmware: device.firmware
        ),
        connection: connection,
        battery_percent: batteryPercent,
        charging: false,
        dpi: DpiPair(x: dpiValue, y: dpiValue),
        dpi_stages: DpiStages(active_stage: activeStage, values: dpiValues),
        poll_rate: 1000,
        device_mode: DeviceMode(mode: 0x00, param: 0x00),
        led_value: 64,
        capabilities: Capabilities(
            dpi_stages: true,
            poll_rate: true,
            power_management: true,
            button_remap: true,
            lighting: true
        )
    )
}
