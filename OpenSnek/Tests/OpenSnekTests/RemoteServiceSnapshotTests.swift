import Foundation
import XCTest
import OpenSnekCore
@testable import OpenSnek

final class RemoteServiceSnapshotTests: XCTestCase {
    func testRemoteServiceBackendUsesSnapshotFeed() async {
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: SnapshotTestRemoteBackend(), autoStart: false)
        }

        let usesRemoteSnapshots = await MainActor.run { appState.usesRemoteServiceUpdates }
        XCTAssertTrue(usesRemoteSnapshots)
    }

    func testApplyRemoteServiceSnapshotHydratesSelectedState() async {
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: SnapshotTestRemoteBackend(), autoStart: false)
        }

        let device = makeSnapshotDevice(
            id: "snapshot-device",
            productName: "Snapshot Mouse",
            transport: .usb,
            serial: "SNAPSHOT",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let state = makeSnapshotState(
            device: device,
            connection: "usb",
            batteryPercent: 81,
            dpiValues: [800, 2400, 6400],
            activeStage: 1,
            dpiValue: 2400
        )
        let snapshot = SharedServiceSnapshot(
            devices: [device],
            stateByDeviceID: [device.id: state],
            lastUpdatedByDeviceID: [device.id: Date(timeIntervalSince1970: 1_773_320_000)]
        )

        await MainActor.run {
            appState.applyRemoteServiceSnapshot(snapshot)
        }

        let selectedDeviceID = await MainActor.run { appState.selectedDeviceID }
        let selectedDpi = await MainActor.run { appState.state?.dpi?.x }
        let activeStage = await MainActor.run { appState.editableActiveStage }
        let pollRate = await MainActor.run { appState.editablePollRate }

        XCTAssertEqual(selectedDeviceID, device.id)
        XCTAssertEqual(selectedDpi, 2400)
        XCTAssertEqual(activeStage, 2)
        XCTAssertEqual(pollRate, 1000)
    }

    func testApplyingLaterSnapshotKeepsExistingLocalSelection() async {
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: SnapshotTestRemoteBackend(), autoStart: false)
        }

        let bluetoothDevice = makeSnapshotDevice(
            id: "bluetooth-device",
            productName: "A Bluetooth Mouse",
            transport: .bluetooth,
            serial: "BT",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let usbDevice = makeSnapshotDevice(
            id: "usb-device",
            productName: "Z USB Mouse",
            transport: .usb,
            serial: "USB",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let initialSnapshot = SharedServiceSnapshot(
            devices: [bluetoothDevice, usbDevice],
            stateByDeviceID: [
                bluetoothDevice.id: makeSnapshotState(
                    device: bluetoothDevice,
                    connection: "bluetooth",
                    batteryPercent: 74,
                    dpiValues: [1200, 2400, 3200],
                    activeStage: 2,
                    dpiValue: 3200
                ),
                usbDevice.id: makeSnapshotState(
                    device: usbDevice,
                    connection: "usb",
                    batteryPercent: 81,
                    dpiValues: [800, 2400, 6400],
                    activeStage: 1,
                    dpiValue: 2400
                ),
            ],
            lastUpdatedByDeviceID: [
                bluetoothDevice.id: Date(timeIntervalSince1970: 1_773_320_010),
                usbDevice.id: Date(timeIntervalSince1970: 1_773_320_000),
            ]
        )
        let laterSnapshot = SharedServiceSnapshot(
            devices: [bluetoothDevice, usbDevice],
            stateByDeviceID: [
                bluetoothDevice.id: makeSnapshotState(
                    device: bluetoothDevice,
                    connection: "bluetooth",
                    batteryPercent: 75,
                    dpiValues: [1400, 2800, 4200],
                    activeStage: 2,
                    dpiValue: 4200
                ),
                usbDevice.id: makeSnapshotState(
                    device: usbDevice,
                    connection: "usb",
                    batteryPercent: 82,
                    dpiValues: [900, 1800, 3600],
                    activeStage: 0,
                    dpiValue: 900
                ),
            ],
            lastUpdatedByDeviceID: [
                bluetoothDevice.id: Date(timeIntervalSince1970: 1_773_320_020),
                usbDevice.id: Date(timeIntervalSince1970: 1_773_320_021),
            ]
        )

        await MainActor.run {
            appState.applyRemoteServiceSnapshot(initialSnapshot)
            appState.selectDevice(usbDevice.id)
            appState.applyRemoteServiceSnapshot(laterSnapshot)
        }

        let selectedDeviceID = await MainActor.run { appState.selectedDeviceID }
        let selectedDpi = await MainActor.run { appState.state?.dpi?.x }
        let selectedBattery = await MainActor.run { appState.state?.battery_percent }
        let activeStage = await MainActor.run { appState.editableActiveStage }

        XCTAssertEqual(selectedDeviceID, usbDevice.id)
        XCTAssertEqual(selectedDpi, 900)
        XCTAssertEqual(selectedBattery, 82)
        XCTAssertEqual(activeStage, 1)
    }

    func testCurrentDeviceStatusUsesSelectedDeviceFreshnessFromSnapshotCache() async {
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: SnapshotTestRemoteBackend(), autoStart: false)
        }

        let alphaDevice = makeSnapshotDevice(
            id: "alpha-device",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "ALPHA",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let betaDevice = makeSnapshotDevice(
            id: "beta-device",
            productName: "Beta Mouse",
            transport: .usb,
            serial: "BETA",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let snapshot = SharedServiceSnapshot(
            devices: [alphaDevice, betaDevice],
            stateByDeviceID: [
                alphaDevice.id: makeSnapshotState(
                    device: alphaDevice,
                    connection: "usb",
                    batteryPercent: 70,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800
                ),
                betaDevice.id: makeSnapshotState(
                    device: betaDevice,
                    connection: "usb",
                    batteryPercent: 72,
                    dpiValues: [1000, 2000, 3000],
                    activeStage: 1,
                    dpiValue: 2000
                ),
            ],
            lastUpdatedByDeviceID: [
                alphaDevice.id: Date(timeIntervalSince1970: 1_700_000_000),
                betaDevice.id: Date(),
            ]
        )

        await MainActor.run {
            appState.applyRemoteServiceSnapshot(snapshot)
            appState.selectDevice(alphaDevice.id)
        }
        let staleLabel = await MainActor.run { appState.currentDeviceStatusIndicator.label }

        await MainActor.run {
            appState.selectDevice(betaDevice.id)
        }
        let freshLabel = await MainActor.run { appState.currentDeviceStatusIndicator.label }

        XCTAssertEqual(staleLabel, "Poll Delayed")
        XCTAssertEqual(freshLabel, "Connected")
    }
}

private func makeSnapshotDevice(
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

private func makeSnapshotState(
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

private final class SnapshotTestRemoteBackend: DeviceBackend {
    var usesRemoteServiceTransport: Bool { true }

    func listDevices() async throws -> [MouseDevice] { [] }
    func readState(device _: MouseDevice) async throws -> MouseState { throw SnapshotBackendError.unimplemented }
    func readDpiStagesFast(device _: MouseDevice) async throws -> DpiFastSnapshot? { nil }
    func apply(device _: MouseDevice, patch _: DevicePatch) async throws -> MouseState { throw SnapshotBackendError.unimplemented }
    func readLightingColor(device _: MouseDevice) async throws -> RGBPatch? { nil }
    func debugUSBReadButtonBinding(device _: MouseDevice, slot _: Int, profile _: Int) async throws -> [UInt8]? { nil }
}

private enum SnapshotBackendError: Error {
    case unimplemented
}
