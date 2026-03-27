import SwiftUI

@main
struct OpenSnekApp: App {
    private static let minimumMainWindowWidth: CGFloat = 900
    private static let minimumMainWindowHeight: CGFloat = 600
    private static let defaultMainWindowWidth: CGFloat = 1134
    private static let defaultMainWindowHeight: CGFloat = 600

    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appLifecycle
    @State private var appState: AppState

    init() {
        let launchRole = OpenSnekProcessRole.current
        _appState = State(initialValue: AppState(launchRole: launchRole))
    }

    var body: some Scene {
        WindowGroup("") {
            if appState.runtimeStore.isServiceProcess {
                ServiceWindowSuppressorView()
            } else {
                ContentView(
                    deviceStore: appState.deviceStore,
                    editorStore: appState.editorStore,
                    runtimeStore: appState.runtimeStore
                )
                    .frame(minWidth: Self.minimumMainWindowWidth, minHeight: Self.minimumMainWindowHeight)
                    .background(WindowChromeConfigurator().frame(width: 0, height: 0))
                    .background(SettingsOpenBridgeView(runtimeStore: appState.runtimeStore).frame(width: 0, height: 0))
            }
        }
        .defaultSize(width: Self.defaultMainWindowWidth, height: Self.defaultMainWindowHeight)

        MenuBarExtra(isInserted: .constant(appState.runtimeStore.isServiceProcess)) {
            ServiceMenuBarView(
                deviceStore: appState.deviceStore,
                editorStore: appState.editorStore,
                runtimeStore: appState.runtimeStore
            )
        } label: {
            ServiceMenuBarStatusItemLabel(
                deviceStore: appState.deviceStore,
                editorStore: appState.editorStore,
                runtimeStore: appState.runtimeStore
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                deviceStore: appState.deviceStore,
                runtimeStore: appState.runtimeStore
            )
        }
    }
}

private struct ServiceWindowSuppressorView: NSViewRepresentable {
    func makeNSView(context: Context) -> SuppressorView {
        SuppressorView()
    }

    func updateNSView(_ nsView: SuppressorView, context: Context) {}

    final class SuppressorView: NSView {
        private weak var suppressedWindow: NSWindow?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            guard let newWindow else { return }
            suppress(window: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            suppress(window: window)
        }

        private func suppress(window: NSWindow) {
            guard suppressedWindow !== window else { return }
            suppressedWindow = window

            // The service process uses a WindowGroup only to satisfy SwiftUI scene
            // requirements. Hide that transient window before AppKit can present it.
            window.alphaValue = 0
            window.hasShadow = false
            window.animationBehavior = .none
            window.ignoresMouseEvents = true
            window.orderOut(nil)

            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                window.orderOut(nil)
                window.close()
            }
        }
    }
}

private struct SettingsOpenBridgeView: View {
    let runtimeStore: RuntimeStore

    @Environment(\.openSettings) private var openSettings
    @State private var didHandleLaunchSettingsRequest = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                handleLaunchSettingsRequestIfNeeded()
            }
            .onChange(of: runtimeStore.openSettingsRequestCount) { _, count in
                guard count > 0 else { return }
                openSettings()
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
