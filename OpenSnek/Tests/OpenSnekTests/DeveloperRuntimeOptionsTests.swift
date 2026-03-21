import Foundation
import XCTest
import OpenSnekAppSupport

final class DeveloperRuntimeOptionsTests: XCTestCase {
    func testDeveloperRuntimeOptionsDefaultToEnabled() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        XCTAssertTrue(DeveloperRuntimeOptions.pollingEnabled(defaults: defaults))
        XCTAssertTrue(DeveloperRuntimeOptions.passiveHIDUpdatesEnabled(defaults: defaults))
    }

    func testDeveloperRuntimeOptionsReadPersistedFalseValues() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: DeveloperRuntimeOptions.pollingEnabledDefaultsKey)
        defaults.set(false, forKey: DeveloperRuntimeOptions.passiveHIDUpdatesEnabledDefaultsKey)

        XCTAssertFalse(DeveloperRuntimeOptions.pollingEnabled(defaults: defaults))
        XCTAssertFalse(DeveloperRuntimeOptions.passiveHIDUpdatesEnabled(defaults: defaults))
    }
}
