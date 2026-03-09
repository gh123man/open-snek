import SwiftUI

@main
struct OpenSnekApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appLifecycle
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("") {
            ContentView(appState: appState)
                .frame(minWidth: 900, minHeight: 600)
                .background(WindowChromeConfigurator().frame(width: 0, height: 0))
        }
    }
}
