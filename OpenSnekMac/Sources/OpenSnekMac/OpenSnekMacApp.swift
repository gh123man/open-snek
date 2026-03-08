import SwiftUI

@main
struct OpenSnekMacApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
