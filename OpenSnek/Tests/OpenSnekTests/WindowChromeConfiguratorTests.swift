import XCTest
@testable import OpenSnek

@MainActor
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

    func testConfigureAssignsMainWindowFrameAutosaveName() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        WindowChromeConfigurator.configure(
            window,
            osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 5)
        )

        XCTAssertEqual(window.frameAutosaveName, WindowChromeConfigurator.mainWindowFrameAutosaveName)
    }
}
