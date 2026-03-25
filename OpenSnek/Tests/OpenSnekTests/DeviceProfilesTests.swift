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
        XCTAssertEqual(profile?.passiveDPIInput?.usagePage, 0x01)
        XCTAssertEqual(profile?.passiveDPIInput?.usage, 0x06)
        XCTAssertEqual(profile?.passiveDPIInput?.reportID, 0x05)
        XCTAssertEqual(profile?.passiveDPIInput?.subtype, 0x02)
        XCTAssertEqual(profile?.passiveDPIInput?.maximumDPI, 18_000)
        XCTAssertEqual(profile?.onboardProfileCount, 1)
    }

    func testResolveUSBProfileForBasiliskV335K() {
        let profile = DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x00CB, transport: .usb)
        XCTAssertEqual(profile?.id, .basiliskV335K)
        XCTAssertEqual(profile?.buttonLayout.writableSlots, [1, 2, 3, 4, 5, 9, 10, 15, 52, 53, 96])
        XCTAssertEqual(profile?.buttonLayout.visibleSlots.map(\.slot), [1, 2, 3, 4, 5, 9, 10, 15, 52, 53, 96])
        XCTAssertEqual(profile?.buttonLayout.documentedSlots.map(\.slot), [1, 2, 3, 4, 5, 9, 10, 14, 15, 52, 53, 96, 106])
        XCTAssertEqual(profile?.buttonLayout.access(for: 14), .protocolReadOnly)
        XCTAssertEqual(profile?.buttonLayout.access(for: 15), .editable)
        XCTAssertEqual(profile?.buttonLayout.access(for: 106), .softwareReadOnly)
        XCTAssertEqual(profile?.buttonLayout.softwareReadOnlySlots.map(\.slot), [106])
        XCTAssertEqual(profile?.supportsAdvancedLightingEffects, true)
        XCTAssertEqual(profile?.supportedLightingEffects, [.off, .staticColor, .spectrum, .wave])
        XCTAssertEqual(profile?.usbLightingLEDIDs, [0x01, 0x04, 0x0A])
        XCTAssertEqual(profile?.usbLightingZones.map(\.id), ["scroll_wheel", "logo", "underglow"])
        XCTAssertEqual(profile?.passiveDPIInput?.usagePage, 0x01)
        XCTAssertEqual(profile?.passiveDPIInput?.usage, 0x06)
        XCTAssertEqual(profile?.passiveDPIInput?.reportID, 0x05)
        XCTAssertEqual(profile?.passiveDPIInput?.subtype, 0x02)
        XCTAssertEqual(profile?.passiveDPIInput?.maximumDPI, 35_000)
        XCTAssertEqual(profile?.onboardProfileCount, 5)
    }

    func testBasiliskV335KSupportsDPIClutchBindings() {
        XCTAssertTrue(ButtonBindingSupport.availableButtonBindingKinds(profileID: .basiliskV335K).contains(.dpiClutch))
        XCTAssertEqual(ButtonBindingSupport.defaultDPIClutchDPI(for: .basiliskV335K), 400)
    }

    func testResolveUSBProfileForBasiliskV3() {
        let profile = DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x0099, transport: .usb)
        XCTAssertEqual(profile?.id, .basiliskV3)
        XCTAssertEqual(profile?.buttonLayout.writableSlots, [1, 2, 3, 4, 5, 9, 10, 15, 52, 53, 96])
        XCTAssertEqual(profile?.buttonLayout.visibleSlots.map(\.slot), [1, 2, 3, 4, 5, 9, 10, 15, 52, 53, 96])
        XCTAssertEqual(profile?.buttonLayout.documentedSlots.map(\.slot), [1, 2, 3, 4, 5, 9, 10, 14, 15, 52, 53, 96, 106])
        XCTAssertEqual(profile?.buttonLayout.access(for: 14), .protocolReadOnly)
        XCTAssertEqual(profile?.buttonLayout.access(for: 15), .editable)
        XCTAssertEqual(profile?.buttonLayout.access(for: 106), .softwareReadOnly)
        XCTAssertEqual(profile?.buttonLayout.softwareReadOnlySlots.map(\.slot), [106])
        XCTAssertEqual(profile?.supportsAdvancedLightingEffects, true)
        XCTAssertEqual(profile?.supportedLightingEffects, [.off, .staticColor, .spectrum, .wave])
        XCTAssertEqual(profile?.usbLightingLEDIDs, [0x01, 0x04, 0x0A])
        XCTAssertEqual(profile?.usbLightingZones.map(\.id), ["scroll_wheel", "logo", "underglow"])
        XCTAssertEqual(profile?.passiveDPIInput?.usagePage, 0x01)
        XCTAssertEqual(profile?.passiveDPIInput?.usage, 0x06)
        XCTAssertEqual(profile?.passiveDPIInput?.reportID, 0x05)
        XCTAssertEqual(profile?.passiveDPIInput?.subtype, 0x02)
        XCTAssertEqual(profile?.passiveDPIInput?.maximumDPI, 26_000)
        XCTAssertEqual(profile?.onboardProfileCount, 5)
        XCTAssertEqual(profile?.isLocallyValidated, false)
    }

    func testBasiliskV3SupportsDPIClutchBindings() {
        XCTAssertTrue(ButtonBindingSupport.availableButtonBindingKinds(profileID: .basiliskV3).contains(.dpiClutch))
        XCTAssertEqual(ButtonBindingSupport.defaultDPIClutchDPI(for: .basiliskV3), 400)
    }

    func testResolveUSBProfileForBasiliskV3Pro() {
        let profile = DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x00AB, transport: .usb)
        XCTAssertEqual(profile?.id, .basiliskV3Pro)
        XCTAssertEqual(profile?.buttonLayout.writableSlots, [1, 2, 3, 4, 5, 9, 10, 15, 52, 53])
        XCTAssertEqual(profile?.buttonLayout.visibleSlots.map(\.slot), [1, 2, 3, 4, 5, 9, 10, 15, 52, 53])
        XCTAssertEqual(profile?.buttonLayout.documentedSlots.map(\.slot), [1, 2, 3, 4, 5, 9, 10, 15, 52, 53, 106])
        XCTAssertEqual(profile?.buttonLayout.access(for: 15), .editable)
        XCTAssertEqual(profile?.buttonLayout.access(for: 106), .protocolReadOnly)
        XCTAssertEqual(profile?.buttonLayout.softwareReadOnlySlots.map(\.slot), [])
        XCTAssertEqual(profile?.supportsAdvancedLightingEffects, true)
        XCTAssertEqual(profile?.supportedLightingEffects, [.off, .staticColor, .spectrum, .wave])
        XCTAssertEqual(profile?.usbLightingLEDIDs, [0x01, 0x04, 0x0A])
        XCTAssertEqual(profile?.usbLightingZones.map(\.id), ["scroll_wheel", "logo", "underglow"])
        XCTAssertEqual(profile?.passiveDPIInput?.usagePage, 0x01)
        XCTAssertEqual(profile?.passiveDPIInput?.usage, 0x06)
        XCTAssertEqual(profile?.passiveDPIInput?.reportID, 0x05)
        XCTAssertEqual(profile?.passiveDPIInput?.subtype, 0x02)
        XCTAssertEqual(profile?.passiveDPIInput?.maximumDPI, 30_000)
        XCTAssertEqual(profile?.onboardProfileCount, 5)
    }

    func testBasiliskV3ProUSBLightingTargetsResolveAllZones() throws {
        let profile = try XCTUnwrap(DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x00AB, transport: .usb))
        let targets = try XCTUnwrap(profile.lightingTargets())
        XCTAssertEqual(targets.map(\.zoneID), ["scroll_wheel", "logo", "underglow"])
        XCTAssertEqual(targets.map(\.ledID), [0x01, 0x04, 0x0A])
        XCTAssertEqual(profile.lightingLEDIDs(), [0x01, 0x04, 0x0A])
    }

    func testBasiliskV3ProUSBLightingTargetsResolveSpecificZone() throws {
        let profile = try XCTUnwrap(DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x00AB, transport: .usb))
        let targets = try XCTUnwrap(profile.lightingTargets(for: "logo"))
        XCTAssertEqual(targets.map(\.zoneID), ["logo"])
        XCTAssertEqual(targets.map(\.ledID), [0x04])
        XCTAssertEqual(profile.lightingLEDIDs(for: "logo"), [0x04])
        XCTAssertNil(profile.lightingTargets(for: "bogus"))
        XCTAssertNil(profile.lightingLEDIDs(for: "bogus"))
    }

    func testResolveBluetoothProfileForBasiliskV3X() {
        let profile = DeviceProfiles.resolve(vendorID: 0x068E, productID: 0x00BA, transport: .bluetooth)
        XCTAssertEqual(profile?.id, .basiliskV3XHyperspeed)
        XCTAssertEqual(profile?.buttonLayout.writableSlots, [1, 2, 3, 4, 5, 9, 10, 96])
        XCTAssertEqual(profile?.buttonLayout.documentedSlots.map(\.slot), [1, 2, 3, 4, 5, 6, 9, 10, 96])
        XCTAssertEqual(profile?.buttonLayout.access(for: 6), .softwareReadOnly)
        XCTAssertEqual(profile?.buttonLayout.softwareReadOnlySlots.map(\.slot), [6])
        XCTAssertEqual(profile?.supportsAdvancedLightingEffects, false)
        XCTAssertEqual(profile?.passiveDPIInput?.usagePage, 0x01)
        XCTAssertEqual(profile?.passiveDPIInput?.usage, 0x02)
        XCTAssertEqual(profile?.passiveDPIInput?.reportID, 0x05)
        XCTAssertEqual(profile?.passiveDPIInput?.subtype, 0x02)
        XCTAssertEqual(profile?.passiveDPIInput?.maximumDPI, 18_000)
        XCTAssertEqual(profile?.onboardProfileCount, 1)
    }

    func testResolveBluetoothProfileForBasiliskV3Pro() {
        let profile = DeviceProfiles.resolve(vendorID: 0x068E, productID: 0x00AC, transport: .bluetooth)
        XCTAssertEqual(profile?.id, .basiliskV3Pro)
        XCTAssertEqual(profile?.buttonLayout.writableSlots, [1, 2, 3, 4, 5, 9, 10, 52, 53])
        XCTAssertEqual(profile?.buttonLayout.visibleSlots.map(\.slot), [1, 2, 3, 4, 5, 9, 10, 15, 52, 53])
        XCTAssertEqual(profile?.buttonLayout.documentedSlots.map(\.slot), [1, 2, 3, 4, 5, 9, 10, 15, 52, 53, 106])
        XCTAssertEqual(profile?.buttonLayout.access(for: 15), .softwareReadOnly)
        XCTAssertEqual(profile?.buttonLayout.access(for: 52), .editable)
        XCTAssertEqual(profile?.buttonLayout.access(for: 106), .softwareReadOnly)
        XCTAssertEqual(profile?.buttonLayout.softwareReadOnlySlots.map(\.slot), [15, 106])
        XCTAssertEqual(profile?.supportsAdvancedLightingEffects, false)
        XCTAssertEqual(profile?.passiveDPIInput?.usagePage, 0x01)
        XCTAssertEqual(profile?.passiveDPIInput?.usage, 0x02)
        XCTAssertEqual(profile?.passiveDPIInput?.reportID, 0x05)
        XCTAssertEqual(profile?.passiveDPIInput?.subtype, 0x02)
        XCTAssertEqual(profile?.passiveDPIInput?.maxFeatureReportSize, 1)
        XCTAssertEqual(profile?.passiveDPIInput?.maximumDPI, 30_000)
        XCTAssertEqual(profile?.onboardProfileCount, 3)
        XCTAssertEqual(profile?.usbLightingLEDIDs, [0x01, 0x04, 0x0A])
        XCTAssertEqual(profile?.usbLightingZones.map(\.id), ["scroll_wheel", "logo", "underglow"])
    }

    func testDPIRangesMatchSupportedProfiles() {
        XCTAssertEqual(DeviceProfiles.dpiRange(for: .basiliskV3XHyperspeed), 100...18_000)
        XCTAssertEqual(DeviceProfiles.dpiRange(for: .basiliskV3), 100...26_000)
        XCTAssertEqual(DeviceProfiles.dpiRange(for: .basiliskV3Pro), 100...30_000)
        XCTAssertEqual(DeviceProfiles.dpiRange(for: .basiliskV335K), 100...35_000)
        XCTAssertEqual(DeviceProfiles.sliderDpiRange(for: .basiliskV3XHyperspeed), 100...6_000)
        XCTAssertEqual(DeviceProfiles.sliderDpiRange(for: .basiliskV3), 100...6_000)
        XCTAssertEqual(DeviceProfiles.sliderDpiRange(for: .basiliskV3Pro), 100...6_000)
        XCTAssertEqual(DeviceProfiles.sliderDpiRange(for: .basiliskV335K), 100...6_000)
        XCTAssertEqual(DeviceProfiles.clampDPI(40_000, profileID: .basiliskV335K), 35_000)
        XCTAssertEqual(DeviceProfiles.clampDPI(30_000, profileID: .basiliskV3), 26_000)
        XCTAssertEqual(DeviceProfiles.clampDPI(24_000, profileID: .basiliskV3XHyperspeed), 18_000)
    }

    func testBasiliskV3ProBluetoothShowsLightingControls() {
        let bluetoothV3Pro = MouseDevice(
            id: "bt-v3-pro",
            vendor_id: 0x068E,
            product_id: 0x00AC,
            product_name: "Basilisk V3 Pro",
            transport: .bluetooth,
            path_b64: "",
            serial: nil,
            firmware: nil,
            profile_id: .basiliskV3Pro
        )
        let bluetoothV3X = MouseDevice(
            id: "bt-v3x",
            vendor_id: 0x068E,
            product_id: 0x00BA,
            product_name: "Basilisk V3 X HyperSpeed",
            transport: .bluetooth,
            path_b64: "",
            serial: nil,
            firmware: nil,
            profile_id: .basiliskV3XHyperspeed
        )
        let usbV3Pro = MouseDevice(
            id: "usb-v3-pro",
            vendor_id: 0x1532,
            product_id: 0x00AB,
            product_name: "Basilisk V3 Pro",
            transport: .usb,
            path_b64: "",
            serial: nil,
            firmware: nil,
            profile_id: .basiliskV3Pro
        )

        XCTAssertTrue(bluetoothV3Pro.showsLightingControls)
        XCTAssertTrue(bluetoothV3X.showsLightingControls)
        XCTAssertTrue(usbV3Pro.showsLightingControls)
    }

    func testBasiliskV3ProBluetoothLightingTargetsResolveAllZones() throws {
        let profile = try XCTUnwrap(DeviceProfiles.resolve(vendorID: 0x068E, productID: 0x00AC, transport: .bluetooth))
        let targets = try XCTUnwrap(profile.lightingTargets())
        XCTAssertEqual(targets.map(\.zoneID), ["scroll_wheel", "logo", "underglow"])
        XCTAssertEqual(targets.map(\.ledID), [0x01, 0x04, 0x0A])
        XCTAssertEqual(profile.lightingLEDIDs(), [0x01, 0x04, 0x0A])
    }

    func testResolveBluetoothFallbackProfileByName() {
        let exact = DeviceProfiles.resolveBluetoothFallback(name: "Basilisk V3 X HyperSpeed")
        XCTAssertEqual(exact?.id, .basiliskV3XHyperspeed)

        let prefixed = DeviceProfiles.resolveBluetoothFallback(name: "Razer Basilisk V3 X HyperSpeed")
        XCTAssertEqual(prefixed?.id, .basiliskV3XHyperspeed)

        let shorthand = DeviceProfiles.resolveBluetoothFallback(name: "BSK V3 PRO")
        XCTAssertEqual(shorthand?.id, .basiliskV3Pro)

        let unknown = DeviceProfiles.resolveBluetoothFallback(name: "Razer Cobra Pro")
        XCTAssertNil(unknown)
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
