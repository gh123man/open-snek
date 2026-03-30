import XCTest
import OpenSnekAppSupport
@testable import OpenSnek

@MainActor
final class WindowChromeConfiguratorTests: XCTestCase {
    func testConfigureAssignsMainWindowFrameAutosaveName() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        WindowChromeConfigurator.configure(window)

        XCTAssertEqual(window.frameAutosaveName, WindowChromeConfigurator.mainWindowFrameAutosaveName)
    }

    func testConfigureSkipsFrameAutosaveWhenDeveloperRememberWindowSizeIsDisabled() {
        let suiteName = "WindowChromeConfiguratorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: DeveloperRuntimeOptions.rememberWindowSizeEnabledDefaultsKey)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        WindowChromeConfigurator.configure(window, defaults: defaults)

        XCTAssertTrue(window.frameAutosaveName.isEmpty)
    }

    func testPersistFrameSkipsWritesWhenDeveloperRememberWindowSizeIsDisabled() {
        let suiteName = "WindowChromeConfiguratorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let autosaveName = "OpenSnekMainWindow.\(UUID().uuidString)"
        let key = WindowChromeConfigurator.framePersistenceKey(for: autosaveName)
        let appKitKey = "NSWindow Frame \(autosaveName)"

        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: DeveloperRuntimeOptions.rememberWindowSizeEnabledDefaultsKey)
        UserDefaults.standard.removeObject(forKey: appKitKey)
        defer { UserDefaults.standard.removeObject(forKey: appKitKey) }

        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 50, width: 1210, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        WindowChromeConfigurator.persistFrame(
            window,
            autosaveName: autosaveName,
            defaults: defaults
        )

        XCTAssertNil(defaults.string(forKey: key))
        XCTAssertNil(UserDefaults.standard.string(forKey: appKitKey))
    }

    func testConfigureRestoresPersistedFrameFromDefaults() {
        let suiteName = "WindowChromeConfiguratorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let autosaveName = "OpenSnekMainWindow.\(UUID().uuidString)"
        let key = WindowChromeConfigurator.framePersistenceKey(for: autosaveName)

        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosaveName)")
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosaveName)") }

        let persistedWindow = NSWindow(
            contentRect: NSRect(x: 120, y: 80, width: 1330, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let persistedFrame = persistedWindow.frame

        defaults.set(NSStringFromRect(persistedFrame), forKey: key)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        let restored = WindowChromeConfigurator.restorePersistedFrameIfNeeded(
            window,
            autosaveName: autosaveName,
            defaults: defaults
        )

        XCTAssertTrue(restored)
        XCTAssertEqual(window.frame, persistedFrame)
    }

    func testPersistFrameWritesFrameSnapshotToDefaults() {
        let suiteName = "WindowChromeConfiguratorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let autosaveName = "OpenSnekMainWindow.\(UUID().uuidString)"
        let key = WindowChromeConfigurator.framePersistenceKey(for: autosaveName)
        let appKitKey = "NSWindow Frame \(autosaveName)"

        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        UserDefaults.standard.removeObject(forKey: appKitKey)
        defer { UserDefaults.standard.removeObject(forKey: appKitKey) }

        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 50, width: 1210, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        WindowChromeConfigurator.persistFrame(
            window,
            autosaveName: autosaveName,
            defaults: defaults
        )

        XCTAssertEqual(defaults.string(forKey: key), NSStringFromRect(window.frame))
        XCTAssertNotNil(UserDefaults.standard.string(forKey: appKitKey))
    }
}
