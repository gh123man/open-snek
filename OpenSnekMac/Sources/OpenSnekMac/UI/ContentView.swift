import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var didAutoOpenInputMonitoringSettings = false

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
        .onReceive(Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()) { _ in
            Task { await appState.pollDevicePresence() }
        }
        .onReceive(Timer.publish(every: 0.20, on: .main, in: .common).autoconnect()) { _ in
            Task { await appState.refreshDpiFast() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await appState.refreshDevices() }
            }
        }
        .onChange(of: appState.errorMessage) { _, newValue in
            guard isInputMonitoringError(newValue) else { return }
            guard !didAutoOpenInputMonitoringSettings else { return }
            didAutoOpenInputMonitoringSettings = true
            openInputMonitoringSettings()
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
        .overlay(alignment: .topLeading) {
            if showsUSBAccessCallout {
                VStack(alignment: .leading, spacing: 8) {
                    Text(usbCalloutTitle)
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text(usbCalloutMessage)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                    if isInputMonitoringError(appState.errorMessage) {
                        Text("Grant Input Monitoring for the app host (Open Snek, Terminal, or Xcode), then relaunch.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.80))
                        Text("If already granted but still blocked, reset stale TCC grant: tccutil reset ListenEvent \(Bundle.main.bundleIdentifier ?? "io.opensnek.OpenSnekMac")")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.78))
                        Text("Denied host: \(currentHostLabel)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    HStack(spacing: 8) {
                        if isInputMonitoringError(appState.errorMessage) {
                            Button("Open Settings") {
                                openInputMonitoringSettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        Button("Refresh") {
                            Task { await appState.refreshDevices() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill((isInputMonitoringError(appState.errorMessage) ? Color(hex: 0xB3261E) : Color(hex: 0x8A6A00)).opacity(0.92))
                )
                .padding(.top, 10)
                .padding(.leading, 12)
                .frame(maxWidth: 520, alignment: .leading)
            }
        }
        .overlay(alignment: .top) {
            if let error = appState.errorMessage, showTopErrorBanner {
                HStack(spacing: 10) {
                    Text(error)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    if isInputMonitoringError(error) {
                        Button("Open Settings") {
                            openInputMonitoringSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(hex: 0xB3261E), in: Capsule())
                .padding(.top, 10)
                .padding(.horizontal, 14)
            }
        }
        .overlay(alignment: .top) {
            if appState.errorMessage == nil, let warning = appState.warningMessage, showTopWarningBanner {
                HStack(spacing: 10) {
                    Text(warning)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(hex: 0x8A6A00), in: Capsule())
                .padding(.top, 10)
                .padding(.horizontal, 14)
            }
        }
    }

    private func isInputMonitoringError(_ message: String?) -> Bool {
        guard let message else { return false }
        let lowered = message.lowercased()
        return lowered.contains("input monitoring") ||
            lowered.contains("usb hid access denied") ||
            lowered.contains("usb hid feature reports are blocked") ||
            lowered.contains("kioreturnnotpermitted")
    }

    private func openInputMonitoringSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_InputMonitoring",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private var currentHostLabel: String {
        let process = ProcessInfo.processInfo.processName
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown.bundle"
        return "\(process) (\(bundleID))"
    }

    private var showsUSBAccessCallout: Bool {
        guard appState.selectedDevice?.transport == "usb" else { return false }
        if isInputMonitoringError(appState.errorMessage) {
            return true
        }
        if appState.warningMessage != nil {
            return true
        }
        guard let state = appState.state else { return false }
        return state.dpi_stages.values == nil || state.poll_rate == nil || state.led_value == nil
    }

    private var showTopErrorBanner: Bool {
        if appState.selectedDevice?.transport == "usb", isInputMonitoringError(appState.errorMessage), showsUSBAccessCallout {
            return false
        }
        return true
    }

    private var showTopWarningBanner: Bool {
        if appState.selectedDevice?.transport == "usb", showsUSBAccessCallout {
            return false
        }
        return true
    }

    private var usbCalloutTitle: String {
        if isInputMonitoringError(appState.errorMessage) {
            return "USB Access Blocked"
        }
        return "USB Telemetry Limited"
    }

    private var usbCalloutMessage: String {
        if let warning = appState.warningMessage {
            return warning
        }
        return "DPI, polling, or lighting readback is unavailable for this device session."
    }
}
