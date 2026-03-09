import XCTest
import OpenSnekCore

final class DeviceProfilesTests: XCTestCase {
    func testResolveUSBProfileForBasiliskV3X() {
        let profile = DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x00B9, transport: .usb)
        XCTAssertEqual(profile?.id, .basiliskV3XHyperspeed)
        XCTAssertEqual(profile?.buttonLayout.writableSlots, [1, 2, 3, 4, 5, 9, 10, 96])
        XCTAssertEqual(profile?.supportsAdvancedLightingEffects, true)
    }

    func testResolveBluetoothProfileForBasiliskV3X() {
        let profile = DeviceProfiles.resolve(vendorID: 0x068E, productID: 0x00BA, transport: .bluetooth)
        XCTAssertEqual(profile?.id, .basiliskV3XHyperspeed)
        XCTAssertEqual(profile?.buttonLayout.writableSlots, [1, 2, 3, 4, 5, 9, 10, 96])
        XCTAssertEqual(profile?.supportsAdvancedLightingEffects, false)
    }

    func testPersistenceKeysPreferSerial() {
        let device = MouseDevice(
            id: "dev",
            vendor_id: 0x1532,
            product_id: 0x00B9,
            product_name: "Mouse",
            transport: .usb,
            path_b64: "",
            serial: "ABC123",
            firmware: nil
        )
        XCTAssertEqual(DevicePersistenceKeys.key(for: device), "serial:abc123")
        XCTAssertEqual(DevicePersistenceKeys.legacyKey(for: device), "dev")
    }
}
