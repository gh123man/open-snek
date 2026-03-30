import XCTest
import OpenSnekAppSupport
@testable import OpenSnek

@MainActor
final class WindowChromeConfiguratorTests: XCTestCase {
    func testConfigureUsesCustomFramePersistenceInsteadOfAppKitAutosave() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        WindowChromeConfigurator.configure(window)

        XCTAssertTrue(window.frameAutosaveName.isEmpty)
    }

    func testConfigureLeavesFrameAutosaveDisabledWhenDeveloperRememberWindowSizeIsDisabled() {
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
            defaults: defaults,
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1600, height: 1000)]
        )

        XCTAssertTrue(restored)
        XCTAssertEqual(window.frame, persistedFrame)
    }

    func testRestorePersistedFrameClampsOffscreenOriginIntoVisibleBounds() {
        let suiteName = "WindowChromeConfiguratorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let autosaveName = "OpenSnekMainWindow.\(UUID().uuidString)"
        let key = WindowChromeConfigurator.framePersistenceKey(for: autosaveName)

        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistedFrame = NSRect(x: -700, y: -300, width: 1330, height: 840)
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
            defaults: defaults,
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1600, height: 1000)]
        )

        XCTAssertTrue(restored)
        XCTAssertEqual(window.frame, NSRect(x: 0, y: 0, width: 1330, height: 840))
    }

    func testRestorePersistedFrameShrinksFrameToFitVisibleScreen() {
        let suiteName = "WindowChromeConfiguratorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let autosaveName = "OpenSnekMainWindow.\(UUID().uuidString)"
        let key = WindowChromeConfigurator.framePersistenceKey(for: autosaveName)

        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistedFrame = NSRect(x: 100, y: 80, width: 1800, height: 1200)
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
            defaults: defaults,
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        )

        XCTAssertTrue(restored)
        XCTAssertEqual(window.frame, NSRect(x: 0, y: 0, width: 1440, height: 900))
    }

    func testNormalizedPersistedFrameRepositionsCurrentWindowFrame() {
        let normalized = WindowChromeConfigurator.normalizedPersistedFrame(
            NSRect(x: -900, y: -200, width: 1200, height: 828),
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        )

        XCTAssertEqual(normalized, NSRect(x: 0, y: 0, width: 1200, height: 828))
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
        XCTAssertNil(UserDefaults.standard.string(forKey: appKitKey))
    }
}
