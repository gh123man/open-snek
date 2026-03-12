import Foundation
import XCTest
@testable import OpenSnek

final class ServiceModeTests: XCTestCase {
    func testPollingProfileIntervalsMatchExpectedCadence() {
        XCTAssertEqual(PollingProfile.foreground.refreshStateInterval, 2.0)
        XCTAssertEqual(PollingProfile.foreground.devicePresenceInterval, 1.2)
        XCTAssertEqual(PollingProfile.foreground.fastDpiInterval, 0.20)

        XCTAssertEqual(PollingProfile.serviceIdle.refreshStateInterval, 8.0)
        XCTAssertEqual(PollingProfile.serviceIdle.devicePresenceInterval, 4.0)
        XCTAssertNil(PollingProfile.serviceIdle.fastDpiInterval)

        XCTAssertEqual(PollingProfile.serviceInteractive.refreshStateInterval, 2.0)
        XCTAssertEqual(PollingProfile.serviceInteractive.devicePresenceInterval, 1.2)
        XCTAssertEqual(PollingProfile.serviceInteractive.fastDpiInterval, 0.25)
    }

    func testServiceRoleTransitionsBetweenIdleAndInteractiveProfiles() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: defaults)
        }
        let appState = await MainActor.run {
            AppState(launchRole: .service, serviceCoordinator: coordinator, autoStart: false)
        }

        let initial = await MainActor.run { appState.currentPollingProfile }
        XCTAssertEqual(initial, .serviceIdle)

        await MainActor.run {
            appState.setCompactMenuPresented(true)
        }
        let interactive = await MainActor.run { appState.currentPollingProfile }
        XCTAssertEqual(interactive, .serviceInteractive)

        await MainActor.run {
            appState.setCompactMenuPresented(false)
        }
        let afterClose = await MainActor.run { appState.currentPollingProfile }
        XCTAssertEqual(afterClose, .serviceInteractive)
    }

    func testWindowedAppAlwaysUsesForegroundProfile() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: defaults)
        }
        let appState = await MainActor.run {
            AppState(launchRole: .app, serviceCoordinator: coordinator, autoStart: false)
        }

        let profile = await MainActor.run { appState.currentPollingProfile }
        XCTAssertEqual(profile, .foreground)
    }
}
