import SwiftUI

struct ContentView: View {
    @Bindable var appState: AppState

    var body: some View {
        NavigationSplitView {
            DeviceSidebarView(appState: appState)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.automatic)
        .task { await appState.refreshDevices() }
        .onChange(of: appState.selectedDeviceID) { _, _ in
            Task { await appState.refreshState() }
        }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            Task { await appState.refreshState() }
        }
        .onReceive(Timer.publish(every: 0.20, on: .main, in: .common).autoconnect()) { _ in
            Task { await appState.refreshDpiFast() }
        }
    }

    private var detail: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x0E1218), Color(hex: 0x121D15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let selected = appState.selectedDevice, let state = appState.state {
                DeviceDetailView(appState: appState, selected: selected, state: state)
            } else {
                VStack(spacing: 10) {
                    Text("Choose a device")
                        .font(.system(size: 26, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Telemetry and controls appear here when read succeeds.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
        .overlay(alignment: .top) {
            if let error = appState.errorMessage {
                Text(error)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(hex: 0xB3261E), in: Capsule())
                    .padding(.top, 10)
            }
        }
    }
}
