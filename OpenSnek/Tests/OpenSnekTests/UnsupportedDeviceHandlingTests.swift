import XCTest
@testable import OpenSnek
import OpenSnekCore

final class UnsupportedDeviceHandlingTests: XCTestCase {
    func testUnsupportedUSBUsesProbedCapabilitiesOnly() async {
        let client = BridgeClient()
        let device = MouseDevice(
            id: "usb-unsupported",
            vendor_id: 0x1532,
            product_id: 0x1234,
            product_name: "Razer Mystery Mouse",
            transport: .usb,
            path_b64: "",
            serial: nil,
            firmware: nil
        )

        let capabilities = await client.resolvedUSBStateCapabilities(
            device: device,
            profile: nil,
            stages: (1, [800, 1600, 3200]),
            poll: 1000,
            sleepTimeout: nil,
            led: 64
        )

        XCTAssertTrue(capabilities.dpi_stages)
        XCTAssertTrue(capabilities.poll_rate)
        XCTAssertFalse(capabilities.power_management)
        XCTAssertFalse(capabilities.button_remap)
        XCTAssertTrue(capabilities.lighting)
    }

    @MainActor
    func testUnsupportedClassificationIsStrictForBluetoothOnly() {
        let appState = AppState()
        let unsupportedUSB = MouseDevice(
            id: "usb-unsupported",
            vendor_id: 0x1532,
            product_id: 0x1234,
            product_name: "Razer USB Mystery Mouse",
            transport: .usb,
            path_b64: "",
            serial: nil,
            firmware: nil
        )

        appState.devices = [unsupportedUSB]
        appState.selectedDeviceID = unsupportedUSB.id

        XCTAssertTrue(appState.selectedDeviceIsUnsupportedUSB)
        XCTAssertFalse(appState.selectedDeviceIsStrictlyUnsupported)

        let unsupportedBluetooth = MouseDevice(
            id: "bt-unsupported",
            vendor_id: 0x068E,
            product_id: 0x9999,
            product_name: "Razer BT Mystery Mouse",
            transport: .bluetooth,
            path_b64: "",
            serial: nil,
            firmware: nil
        )

        appState.devices = [unsupportedBluetooth]
        appState.selectedDeviceID = unsupportedBluetooth.id

        XCTAssertFalse(appState.selectedDeviceIsUnsupportedUSB)
        XCTAssertTrue(appState.selectedDeviceIsStrictlyUnsupported)
    }
}
