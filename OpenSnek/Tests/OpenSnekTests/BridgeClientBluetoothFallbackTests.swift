import XCTest
@testable import OpenSnek
import OpenSnekCore
import OpenSnekHardware

final class BridgeClientBluetoothFallbackTests: XCTestCase {
    func testSupportedBluetoothFallbackUsesResolvedProfile() {
        let summary = BLEVendorTransportClient.ConnectedPeripheralSummary(
            name: "Razer Basilisk V3 X HyperSpeed",
            identifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )

        let device = BridgeClient.makeBluetoothFallbackDevice(summary: summary)

        XCTAssertEqual(device.vendor_id, 0x068E)
        XCTAssertEqual(device.product_id, 0x00BA)
        XCTAssertEqual(device.profile_id, .basiliskV3XHyperspeed)
        XCTAssertEqual(device.product_name, "Razer Basilisk V3 X HyperSpeed")
        XCTAssertEqual(device.transport, .bluetooth)
        XCTAssertNotNil(device.button_layout)
    }

    func testSupportedBluetoothFallbackUsesResolvedProfileForBasiliskV3ProAlias() {
        let summary = BLEVendorTransportClient.ConnectedPeripheralSummary(
            name: "BSK V3 PRO",
            identifier: UUID(uuidString: "99999999-2222-3333-4444-555555555555")!
        )

        let device = BridgeClient.makeBluetoothFallbackDevice(summary: summary)

        XCTAssertEqual(device.vendor_id, 0x068E)
        XCTAssertEqual(device.product_id, 0x00AC)
        XCTAssertEqual(device.profile_id, .basiliskV3Pro)
        XCTAssertEqual(device.product_name, "BSK V3 PRO")
        XCTAssertEqual(device.transport, .bluetooth)
        XCTAssertNotNil(device.button_layout)
    }

    func testUnsupportedBluetoothFallbackRemainsGeneric() {
        let summary = BLEVendorTransportClient.ConnectedPeripheralSummary(
            name: "Razer Cobra Pro",
            identifier: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )

        let device = BridgeClient.makeBluetoothFallbackDevice(summary: summary)

        XCTAssertEqual(device.vendor_id, 0x068E)
        XCTAssertEqual(device.product_id, 0x0000)
        XCTAssertNil(device.profile_id)
        XCTAssertEqual(device.product_name, "Razer Cobra Pro")
        XCTAssertEqual(device.transport, .bluetooth)
        XCTAssertNil(device.button_layout)
        XCTAssertFalse(device.supports_advanced_lighting_effects)
    }

    func testPreferredBluetoothControlWarmupNameUsesResolvedProfile() {
        let preferredName = BridgeClient.preferredBluetoothControlWarmupName(
            vendorID: 0x068E,
            productID: 0x00BA,
            transport: .bluetooth
        )

        XCTAssertEqual(preferredName, "Basilisk V3 X HyperSpeed")
    }

    func testPreferredBluetoothControlWarmupNameUsesResolvedProfileForBasiliskV3Pro() {
        let preferredName = BridgeClient.preferredBluetoothControlWarmupName(
            vendorID: 0x068E,
            productID: 0x00AC,
            transport: .bluetooth
        )

        XCTAssertEqual(preferredName, "Basilisk V3 Pro")
    }

    func testPreferredBluetoothControlWarmupNameSkipsNonBluetoothDevices() {
        let preferredName = BridgeClient.preferredBluetoothControlWarmupName(
            vendorID: 0x1532,
            productID: 0x00B9,
            transport: .usb
        )

        XCTAssertNil(preferredName)
    }
}
