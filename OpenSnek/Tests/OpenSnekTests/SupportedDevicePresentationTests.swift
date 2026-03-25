import XCTest
import OpenSnekCore
@testable import OpenSnek

final class SupportedDevicePresentationTests: XCTestCase {
    func testRegularBasiliskV3DoesNotShowMappedBadgeInSupportedList() {
        XCTAssertNil(supportedDeviceSupportBadge(for: [DeviceProfiles.basiliskV3USB]))
    }

    func testUnvalidatedNonV3ProfileStillShowsMappedBadgeInSupportedList() {
        let profile = DeviceProfile(
            id: .basiliskV3Pro,
            productName: "Basilisk V3 Pro",
            transport: .usb,
            supportedProducts: [0x00AB],
            buttonLayout: DeviceProfiles.basiliskV3ProUSB.buttonLayout,
            supportsAdvancedLightingEffects: DeviceProfiles.basiliskV3ProUSB.supportsAdvancedLightingEffects,
            supportedLightingEffects: DeviceProfiles.basiliskV3ProUSB.supportedLightingEffects,
            usbLightingLEDIDs: DeviceProfiles.basiliskV3ProUSB.usbLightingLEDIDs,
            usbLightingZones: DeviceProfiles.basiliskV3ProUSB.usbLightingZones,
            passiveDPIInput: DeviceProfiles.basiliskV3ProUSB.passiveDPIInput,
            supportsIndependentXYDPI: DeviceProfiles.basiliskV3ProUSB.supportsIndependentXYDPI,
            onboardProfileCount: DeviceProfiles.basiliskV3ProUSB.onboardProfileCount,
            isLocallyValidated: false
        )

        XCTAssertEqual(supportedDeviceSupportBadge(for: [profile]), "Mapped")
    }
}
