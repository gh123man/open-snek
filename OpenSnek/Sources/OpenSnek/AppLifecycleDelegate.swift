import AppKit

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        AppLog.info("App", "launch version=\(version) build=\(build) logLevel=\(AppLog.currentLevel.shortLabel)")

        if OpenSnekProcessRole.current.isService {
            NSApp.setActivationPolicy(.accessory)
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.windows.forEach { $0.makeKeyAndOrderFront(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if OpenSnekProcessRole.current.isService {
            return false
        }
        if !flag {
            sender.windows.forEach { $0.makeKeyAndOrderFront(nil) }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !OpenSnekProcessRole.current.isService
    }

    func applicationWillTerminate(_ notification: Notification) {
        BackgroundServiceCoordinator.shared.stopCurrentServiceHostIfNeeded()
    }
}
