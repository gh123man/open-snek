import XCTest
import OpenSnekCore

final class DeviceProfilesTests: XCTestCase {
    func testResolveUSBProfileForBasiliskV3X() {
        let profile = DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x00B9, transport: .usb)
        XCTAssertEqual(profile?.id, .basiliskV3XHyperspeed)
        XCTAssertEqual(profile?.buttonLayout.writableSlots, [1, 2, 3, 4, 5, 9, 10, 96])
        XCTAssertEqual(profile?.supportsAdvancedLightingEffects, true)
        XCTAssertEqual(profile?.supportedLightingEffects, [.off, .staticColor, .spectrum, .wave, .reactive, .pulseRandom, .pulseSingle, .pulseDual])
        XCTAssertEqual(profile?.usbLightingLEDIDs, [0x01])
        XCTAssertEqual(profile?.usbLightingZones.map(\.id), ["scroll_wheel"])
        XCTAssertEqual(profile?.onboardProfileCount, 1)
    }

    func testResolveUSBProfileForBasiliskV335K() {
        let profile = DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x00CB, transport: .usb)
        XCTAssertEqual(profile?.id, .basiliskV335K)
        XCTAssertEqual(profile?.buttonLayout.writableSlots, [1, 2, 3, 4, 5, 9, 10, 52, 53, 96])
        XCTAssertEqual(profile?.buttonLayout.visibleSlots.map(\.slot), [1, 2, 3, 4, 5, 9, 10, 52, 53, 96])
        XCTAssertEqual(profile?.buttonLayout.documentedSlots.map(\.slot), [1, 2, 3, 4, 5, 9, 10, 14, 15, 52, 53, 96, 106])
        XCTAssertEqual(profile?.buttonLayout.access(for: 14), .protocolReadOnly)
        XCTAssertEqual(profile?.buttonLayout.access(for: 15), .softwareReadOnly)
        XCTAssertEqual(profile?.buttonLayout.access(for: 106), .softwareReadOnly)
        XCTAssertEqual(profile?.buttonLayout.softwareReadOnlySlots.map(\.slot), [15, 106])
        XCTAssertEqual(profile?.supportsAdvancedLightingEffects, true)
        XCTAssertEqual(profile?.supportedLightingEffects, [.off, .staticColor, .spectrum, .wave])
        XCTAssertEqual(profile?.usbLightingLEDIDs, [0x01, 0x04, 0x0A])
        XCTAssertEqual(profile?.usbLightingZones.map(\.id), ["scroll_wheel", "logo", "underglow"])
        XCTAssertEqual(profile?.onboardProfileCount, 5)
    }

    func testResolveBluetoothProfileForBasiliskV3X() {
        let profile = DeviceProfiles.resolve(vendorID: 0x068E, productID: 0x00BA, transport: .bluetooth)
        XCTAssertEqual(profile?.id, .basiliskV3XHyperspeed)
        XCTAssertEqual(profile?.buttonLayout.writableSlots, [1, 2, 3, 4, 5, 9, 10, 96])
        XCTAssertEqual(profile?.buttonLayout.documentedSlots.map(\.slot), [1, 2, 3, 4, 5, 6, 9, 10, 96])
        XCTAssertEqual(profile?.buttonLayout.access(for: 6), .softwareReadOnly)
        XCTAssertEqual(profile?.buttonLayout.softwareReadOnlySlots.map(\.slot), [6])
        XCTAssertEqual(profile?.supportsAdvancedLightingEffects, false)
        XCTAssertEqual(profile?.onboardProfileCount, 1)
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
