import SwiftUI

@main
struct OpenSnekApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appLifecycle
    @State private var appState: AppState

    init() {
        let launchRole = OpenSnekProcessRole.current
        _appState = State(initialValue: AppState(launchRole: launchRole))
    }

    var body: some Scene {
        WindowGroup("") {
            if appState.isServiceProcess {
                ServiceWindowSuppressorView()
            } else {
                ContentView(appState: appState)
                    .frame(minWidth: 900, minHeight: 600)
                    .background(SettingsOpenBridgeView().frame(width: 0, height: 0))
            }
        }

        MenuBarExtra(isInserted: .constant(appState.isServiceProcess)) {
            ServiceMenuBarView(appState: appState)
        } label: {
            ServiceMenuBarStatusItemLabel(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState)
        }
    }
}

private struct ServiceWindowSuppressorView: View {
    @State private var didCloseStartupWindow = false

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                guard !didCloseStartupWindow else { return }
                didCloseStartupWindow = true
                DispatchQueue.main.async {
                    NSApp.windows
                        .filter { !($0 is NSPanel) && $0.standardWindowButton(.closeButton) != nil }
                        .forEach { $0.close() }
                }
            }
    }
}

private struct SettingsOpenBridgeView: View {
    @Environment(\.openSettings) private var openSettings
    @State private var didHandleLaunchSettingsRequest = false
    @State private var observer: NSObjectProtocol?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                installObserverIfNeeded()
                handleLaunchSettingsRequestIfNeeded()
            }
            .onDisappear {
                if let observer {
                    DistributedNotificationCenter.default().removeObserver(observer)
                    self.observer = nil
                }
            }
    }

    private func installObserverIfNeeded() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: BackgroundServiceCoordinator.openSettingsNotificationName,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                openSettings()
            }
        }
    }

    private func handleLaunchSettingsRequestIfNeeded() {
        guard !didHandleLaunchSettingsRequest else { return }
        guard ProcessInfo.processInfo.arguments.contains("--open-settings") else { return }
        didHandleLaunchSettingsRequest = true
        DispatchQueue.main.async {
            openSettings()
        }
    }
}
