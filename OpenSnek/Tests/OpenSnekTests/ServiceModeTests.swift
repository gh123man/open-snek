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

        let initial = await MainActor.run { appState.runtimeStore.currentPollingProfile }
        XCTAssertEqual(initial, .serviceIdle)

        await MainActor.run {
            appState.runtimeStore.setCompactMenuPresented(true)
        }
        let interactive = await MainActor.run { appState.runtimeStore.currentPollingProfile }
        XCTAssertEqual(interactive, .serviceInteractive)

        await MainActor.run {
            appState.runtimeStore.setCompactMenuPresented(false)
        }
        let afterClose = await MainActor.run { appState.runtimeStore.currentPollingProfile }
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

        let profile = await MainActor.run { appState.runtimeStore.currentPollingProfile }
        XCTAssertEqual(profile, .foreground)
    }

    func testRuntimeWakeScheduleBacksOffToIdlePresenceDeadline() {
        let now = Date(timeIntervalSince1970: 1_773_400_000)

        let sleep = RuntimeWakeSchedule.nextSleepInterval(
            now: now,
            profile: .serviceIdle,
            usesRemoteServiceUpdates: false,
            lastDevicePresencePollAt: now,
            lastRefreshStatePollAt: now,
            lastFastDpiPollAt: now,
            lastRemoteClientPresencePingAt: .distantPast,
            transientStatusUntil: nil,
            nextRemoteClientPresenceExpiry: nil
        )

        XCTAssertEqual(sleep, 4.0, accuracy: 0.001)
    }

    func testRuntimeWakeScheduleKeepsInteractiveFastPollingCadence() {
        let now = Date(timeIntervalSince1970: 1_773_400_100)

        let sleep = RuntimeWakeSchedule.nextSleepInterval(
            now: now,
            profile: .serviceInteractive,
            usesRemoteServiceUpdates: false,
            lastDevicePresencePollAt: now,
            lastRefreshStatePollAt: now,
            lastFastDpiPollAt: now,
            lastRemoteClientPresencePingAt: .distantPast,
            transientStatusUntil: nil,
            nextRemoteClientPresenceExpiry: nil
        )

        XCTAssertEqual(sleep, 0.25, accuracy: 0.001)
    }

    func testRuntimeWakeScheduleUsesRemotePresencePingDeadline() {
        let now = Date(timeIntervalSince1970: 1_773_400_200)

        let sleep = RuntimeWakeSchedule.nextSleepInterval(
            now: now,
            profile: .foreground,
            usesRemoteServiceUpdates: true,
            lastDevicePresencePollAt: .distantPast,
            lastRefreshStatePollAt: .distantPast,
            lastFastDpiPollAt: .distantPast,
            lastRemoteClientPresencePingAt: now,
            transientStatusUntil: nil,
            nextRemoteClientPresenceExpiry: nil
        )

        XCTAssertEqual(sleep, 1.0, accuracy: 0.001)
    }

    func testHIDAccessStatusDeniedUsesExpectedDiagnosticsAndResetCommand() {
        let status = HIDAccessStatus(
            authorization: .denied,
            hostLabel: "Open Snek (io.opensnek.OpenSnek)",
            bundleIdentifier: "io.opensnek.OpenSnek",
            detail: "Input Monitoring is required."
        )

        XCTAssertTrue(status.isDenied)
        XCTAssertEqual(status.diagnosticsLabel, "Denied")
        XCTAssertEqual(
            PermissionSupport.permissionResetCommand(bundleIdentifier: status.bundleIdentifier),
            "tccutil reset All io.opensnek.OpenSnek"
        )
    }
}
