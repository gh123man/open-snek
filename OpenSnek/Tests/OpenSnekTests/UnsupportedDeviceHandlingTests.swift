import XCTest
@testable import OpenSnek
import OpenSnekCore
import OpenSnekHardware

final class UnsupportedDeviceHandlingTests: XCTestCase {
    func testUSBTelemetryUnavailableErrorsSkipSecondStateReadSweep() {
        let unavailable = BridgeError.commandFailed(
            "USB device telemetry unavailable. Feature-report interface did not return usable responses."
        )
        let transient = BridgeError.commandFailed("USB transaction timed out")

        XCTAssertTrue(BridgeClient.isUSBTelemetryUnavailableError(unavailable))
        XCTAssertFalse(BridgeClient.isUSBTelemetryUnavailableError(transient))
        XCTAssertFalse(BridgeClient.shouldRetryUSBStateRead(firstScanErrors: [unavailable, unavailable]))
        XCTAssertTrue(BridgeClient.shouldRetryUSBStateRead(firstScanErrors: [unavailable, transient]))
    }

    func testUSBReconnectSettleDeadlineOnlyAppliesToUSBConnectEvents() {
        let observedAt = Date(timeIntervalSince1970: 1234)
        let usbConnected = HIDDevicePresenceEvent(
            deviceID: "usb-device",
            vendorID: 0x1532,
            productID: 0x00CB,
            locationID: 1,
            transport: .usb,
            change: .connected,
            observedAt: observedAt
        )
        let usbDisconnected = HIDDevicePresenceEvent(
            deviceID: "usb-device",
            vendorID: 0x1532,
            productID: 0x00CB,
            locationID: 1,
            transport: .usb,
            change: .disconnected,
            observedAt: observedAt
        )
        let btConnected = HIDDevicePresenceEvent(
            deviceID: "bt-device",
            vendorID: 0x068E,
            productID: 0x00AC,
            locationID: 1,
            transport: .bluetooth,
            change: .connected,
            observedAt: observedAt
        )

        let deadline = BridgeClient.usbReconnectSettleDeadline(for: usbConnected)
        XCTAssertEqual(deadline, observedAt.addingTimeInterval(BridgeClient.usbReconnectSettleInterval))
        XCTAssertNil(BridgeClient.usbReconnectSettleDeadline(for: usbDisconnected))
        XCTAssertNil(BridgeClient.usbReconnectSettleDeadline(for: btConnected))
    }

    func testUSBReconnectReadDeferralUsesSettleDeadline() {
        let now = Date(timeIntervalSince1970: 2000)
        XCTAssertTrue(
            BridgeClient.shouldDeferUSBReconnectRead(
                until: now.addingTimeInterval(0.5),
                now: now
            )
        )
        XCTAssertFalse(
            BridgeClient.shouldDeferUSBReconnectRead(
                until: now.addingTimeInterval(-0.5),
                now: now
            )
        )
        XCTAssertFalse(BridgeClient.shouldDeferUSBReconnectRead(until: nil, now: now))
    }

    func testUSBReconnectSettleIntervalIsTwoSeconds() {
        XCTAssertEqual(BridgeClient.usbReconnectSettleInterval, 2.0)
    }

    func testStaleSessionPermissionFlagDoesNotMasqueradeAsManagerDenial() async {
        let client = BridgeClient(startHIDMonitoring: false)
        await client.testConfigureUSBAccessFlags(hidAccessDenied: true, managerAccessDenied: false)

        let device = MouseDevice(
            id: "usb-stale-denial",
            vendor_id: 0x1532,
            product_id: 0x00AB,
            product_name: "Razer Basilisk V3 Pro",
            transport: .usb,
            path_b64: "",
            serial: nil,
            firmware: nil
        )

        do {
            _ = try await client.readState(device: device)
            XCTFail("Expected readState to fail without any HID sessions")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Device not available")
        }
    }

    func testUnsupportedUSBUsesProbedCapabilitiesOnly() async {
        let client = BridgeClient(startHIDMonitoring: false)
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

        appState.deviceStore.devices = [unsupportedUSB]
        appState.deviceStore.selectedDeviceID = unsupportedUSB.id

        XCTAssertTrue(appState.deviceStore.selectedDeviceIsUnsupportedUSB)
        XCTAssertFalse(appState.deviceStore.selectedDeviceIsStrictlyUnsupported)

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

        appState.deviceStore.devices = [unsupportedBluetooth]
        appState.deviceStore.selectedDeviceID = unsupportedBluetooth.id

        XCTAssertFalse(appState.deviceStore.selectedDeviceIsUnsupportedUSB)
        XCTAssertTrue(appState.deviceStore.selectedDeviceIsStrictlyUnsupported)
    }
}

private extension BridgeClient {
    func testConfigureUSBAccessFlags(hidAccessDenied: Bool, managerAccessDenied: Bool) {
        self.hidAccessDenied = hidAccessDenied
        self.managerAccessDenied = managerAccessDenied
    }
}
