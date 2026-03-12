import AppKit
import XCTest
@testable import OpenSnek

final class BackgroundServiceCoordinatorTests: XCTestCase {
    func testFreshInstallDefaultsEnableMenuBarIcon() async {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: UserDefaults(suiteName: suiteName)!)
        }

        let backgroundServiceEnabled = await MainActor.run { coordinator.backgroundServiceEnabled }
        let launchAtStartupEnabled = await MainActor.run { coordinator.launchAtStartupEnabled }

        XCTAssertTrue(backgroundServiceEnabled)
        XCTAssertFalse(launchAtStartupEnabled)
    }

    func testExistingExplicitFalseSettingIsPreservedOnUpgrade() async {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: BackgroundServiceCoordinator.backgroundServiceEnabledDefaultsKey)

        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: UserDefaults(suiteName: suiteName)!)
        }

        let backgroundServiceEnabled = await MainActor.run { coordinator.backgroundServiceEnabled }
        XCTAssertFalse(backgroundServiceEnabled)
    }

    func testExistingExplicitTrueSettingIsPreservedOnUpgrade() async {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: BackgroundServiceCoordinator.backgroundServiceEnabledDefaultsKey)

        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: UserDefaults(suiteName: suiteName)!)
        }

        let backgroundServiceEnabled = await MainActor.run { coordinator.backgroundServiceEnabled }
        XCTAssertTrue(backgroundServiceEnabled)
    }

    func testQuittingCurrentServiceProcessDoesNotMutateStoredPreferences() async {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: BackgroundServiceCoordinator.backgroundServiceEnabledDefaultsKey)
        defaults.set(true, forKey: BackgroundServiceCoordinator.launchAtStartupDefaultsKey)

        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: UserDefaults(suiteName: suiteName)!)
        }
        let appState = await MainActor.run {
            AppState(launchRole: .service, serviceCoordinator: coordinator, autoStart: false)
        }

        await MainActor.run {
            appState.prepareForCurrentServiceProcessTermination()
        }

        let backgroundServiceEnabled = await MainActor.run { coordinator.backgroundServiceEnabled }
        let launchAtStartupEnabled = await MainActor.run { coordinator.launchAtStartupEnabled }
        XCTAssertTrue(backgroundServiceEnabled)
        XCTAssertTrue(launchAtStartupEnabled)
    }

    func testPreferredReusableApplicationPrefersActiveRegularApp() {
        let selected = BackgroundServiceCoordinator.preferredReusableApplication(
            in: [
                .init(processIdentifier: 101, activationPolicy: .accessory, isActive: true, isTerminated: false),
                .init(processIdentifier: 102, activationPolicy: .regular, isActive: false, isTerminated: false),
                .init(processIdentifier: 103, activationPolicy: .regular, isActive: true, isTerminated: false),
            ],
            excluding: 101
        )

        XCTAssertEqual(selected?.processIdentifier, 103)
    }

    func testPreferredReusableApplicationExcludesCurrentAndTerminatedProcesses() {
        let selected = BackgroundServiceCoordinator.preferredReusableApplication(
            in: [
                .init(processIdentifier: 201, activationPolicy: .regular, isActive: true, isTerminated: false),
                .init(processIdentifier: 202, activationPolicy: .regular, isActive: false, isTerminated: true),
                .init(processIdentifier: 203, activationPolicy: .accessory, isActive: false, isTerminated: false),
            ],
            excluding: 201
        )

        XCTAssertNil(selected)
    }
}
