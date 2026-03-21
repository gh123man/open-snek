import XCTest
@testable import OpenSnek

final class WindowChromeConfiguratorTests: XCTestCase {
    func testCompatibilityChromeIsEnabledOnMacOS15() {
        XCTAssertTrue(
            WindowChromeConfigurator.shouldUseCompatibilityChrome(
                osVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)
            )
        )
    }

    func testCompatibilityChromeIsDisabledOutsideMacOS15() {
        XCTAssertFalse(
            WindowChromeConfigurator.shouldUseCompatibilityChrome(
                osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 5)
            )
        )
        XCTAssertFalse(
            WindowChromeConfigurator.shouldUseCompatibilityChrome(
                osVersion: OperatingSystemVersion(majorVersion: 16, minorVersion: 0, patchVersion: 0)
            )
        )
        XCTAssertFalse(
            WindowChromeConfigurator.shouldUseCompatibilityChrome(
                osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
            )
        )
    }
}
