import XCTest
@testable import OpenSnek

final class AppLifecycleDelegateTests: XCTestCase {
    func testServiceLaunchUsesAccessoryActivationPolicy() {
        XCTAssertEqual(
            AppLifecycleDelegate.launchActivationPolicy(launchRole: .service),
            .accessory
        )
    }

    func testForegroundLaunchUsesRegularActivationPolicy() {
        XCTAssertEqual(
            AppLifecycleDelegate.launchActivationPolicy(launchRole: .app),
            .regular
        )
    }

    func testServiceReopenLaunchesFullApp() {
        XCTAssertEqual(
            AppLifecycleDelegate.reopenBehavior(launchRole: .service, hasVisibleWindows: false),
            .launchFullApp
        )
        XCTAssertEqual(
            AppLifecycleDelegate.reopenBehavior(launchRole: .service, hasVisibleWindows: true),
            .launchFullApp
        )
    }

    func testWindowedAppReopenRestoresHiddenWindowsOnlyWhenNeeded() {
        XCTAssertEqual(
            AppLifecycleDelegate.reopenBehavior(launchRole: .app, hasVisibleWindows: false),
            .reopenWindows
        )
        XCTAssertEqual(
            AppLifecycleDelegate.reopenBehavior(launchRole: .app, hasVisibleWindows: true),
            .noop
        )
    }
}
