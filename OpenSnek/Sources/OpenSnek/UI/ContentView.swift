import SwiftUI
import AppKit
import OpenSnekCore

struct ContentView: View {
    @Bindable var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            DeviceSidebarView(appState: appState)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.automatic)
        .task {
            async let deviceRefresh: Void = appState.refreshDevices()
            async let updateCheck: Void = appState.checkForUpdates()
            _ = await (deviceRefresh, updateCheck)
        }
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
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .overlay(alignment: .topLeading) {
            if !noticeItems.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(noticeItems.enumerated()), id: \.offset) { _, notice in
                        StatusNoticeCard(
                            title: notice.title,
                            message: notice.message,
                            detailLines: notice.detailLines,
                            tone: notice.tone,
                            actions: notice.actions
                        )
                    }
                }
                .padding(.top, 10)
                .padding(.leading, 12)
                .frame(maxWidth: 520, alignment: .leading)
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
        guard appState.selectedDevice?.transport == .usb else { return false }
        if isInputMonitoringError(appState.errorMessage) {
            return true
        }
        if appState.warningMessage != nil {
            return true
        }
        guard let state = appState.state else { return false }
        return state.dpi_stages.values == nil || state.poll_rate == nil || state.led_value == nil
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

    private var noticeItems: [NoticeItem] {
        var notices: [NoticeItem] = []

        if showsUSBAccessCallout {
            var detailLines: [String] = []
            var actions: [NoticeAction] = [
                NoticeAction(title: "Refresh") {
                    Task { await appState.refreshDevices() }
                }
            ]

            if isInputMonitoringError(appState.errorMessage) {
                detailLines = [
                    "Grant Input Monitoring for the app host (Open Snek, Terminal, or Xcode), then relaunch.",
                    "If already granted but still blocked, reset stale TCC grant: tccutil reset ListenEvent \(Bundle.main.bundleIdentifier ?? "io.opensnek.OpenSnek")",
                    "Denied host: \(currentHostLabel)"
                ]
                actions.insert(
                    NoticeAction(title: "Open Settings", isProminent: true) {
                        openInputMonitoringSettings()
                    },
                    at: 0
                )
            }

            notices.append(
                NoticeItem(
                    title: usbCalloutTitle,
                    message: usbCalloutMessage,
                    detailLines: detailLines,
                    tone: isInputMonitoringError(appState.errorMessage) ? .error : .warning,
                    actions: actions
                )
            )
        }

        if let error = appState.errorMessage, shouldShowSeparateErrorNotice {
            notices.append(
                NoticeItem(
                    title: errorNoticeTitle(for: error),
                    message: error,
                    tone: .error,
                    actions: []
                )
            )
        }

        if let warning = appState.warningMessage, shouldShowSeparateWarningNotice {
            notices.append(
                NoticeItem(
                    title: "Warning",
                    message: warning,
                    tone: .warning,
                    actions: []
                )
            )
        }

        return notices
    }

    private var shouldShowSeparateErrorNotice: Bool {
        guard appState.errorMessage != nil else { return false }
        if isInputMonitoringError(appState.errorMessage), showsUSBAccessCallout {
            return false
        }
        return true
    }

    private var shouldShowSeparateWarningNotice: Bool {
        guard appState.warningMessage != nil else { return false }
        return !showsUSBAccessCallout
    }

    private func errorNoticeTitle(for message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("device read is failing repeatedly") {
            return "Device Read Unstable"
        }
        if lowered.contains("failed") || lowered.contains("error") {
            return "Action Required"
        }
        return "Notice"
    }

    private var supportedDeviceRows: [SupportedDeviceRow] {
        let grouped = Dictionary(grouping: DeviceProfiles.all, by: \.id)
        return grouped.values
            .compactMap { profiles in
                guard let first = profiles.first else { return nil }
                let transports = profiles
                    .map(\.transport)
                    .sorted { lhs, rhs in
                        transportSortKey(lhs) < transportSortKey(rhs)
                    }
                return SupportedDeviceRow(
                    id: first.id.rawValue,
                    name: first.productName,
                    transports: transports
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func transportSortKey(_ transport: DeviceTransportKind) -> Int {
        switch transport {
        case .usb:
            0
        case .bluetooth:
            1
        }
    }

    private var emptyState: some View {
        EmptyDeviceState(rows: supportedDeviceRows)
    }
}

private struct EmptyDeviceState: View {
    let rows: [SupportedDeviceRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect a device")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("Supported devices")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(rows) { row in
                    SupportedDeviceRowView(row: row)
                }
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }
}

private struct SupportedDeviceRowView: View {
    let row: SupportedDeviceRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.name)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            HStack(spacing: 8) {
                ForEach(row.transports, id: \.self) { transport in
                    Pill(
                        text: transport.shortLabel,
                        color: transport == .bluetooth ? Color(hex: 0x66D9FF) : Color(hex: 0xA8F46A)
                    )
                }
            }
            .frame(alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

private struct SupportedDeviceRow: Identifiable {
    let id: String
    let name: String
    let transports: [DeviceTransportKind]
}

private struct NoticeItem {
    let title: String
    let message: String
    var detailLines: [String] = []
    let tone: StatusNoticeTone
    var actions: [NoticeAction] = []
}

private struct NoticeAction {
    let title: String
    var isProminent: Bool = false
    let handler: () -> Void
}

private enum StatusNoticeTone {
    case error
    case warning

    var backgroundColor: Color {
        switch self {
        case .error:
            Color(hex: 0xB3261E)
        case .warning:
            Color(hex: 0x8A6A00)
        }
    }

    var borderColor: Color {
        switch self {
        case .error:
            Color(hex: 0xFF8A80)
        case .warning:
            Color(hex: 0xF4C65D)
        }
    }
}

private struct StatusNoticeCard: View {
    let title: String
    let message: String
    let detailLines: [String]
    let tone: StatusNoticeTone
    let actions: [NoticeAction]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.90))

            detailLinesView

            actionButtons
        }
        .padding(12)
        .background(cardBackground)
        .shadow(color: .black.opacity(0.20), radius: 12, y: 4)
    }

    @ViewBuilder
    private var detailLinesView: some View {
        ForEach(Array(detailLines.enumerated()), id: \.offset) { _, line in
            detailLineView(for: line)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if !actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    if action.isProminent {
                        Button(action.title, action: action.handler)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    } else {
                        Button(action.title, action: action.handler)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func detailLineView(for line: String) -> some View {
        let usesMonospace = line.contains("tccutil") || line.contains("Denied host:")
        let fontSize = usesMonospace ? 11.0 : 12.0
        let fontDesign: Font.Design = usesMonospace ? .monospaced : .rounded

        return Text(line)
            .font(.system(size: fontSize, weight: .medium, design: fontDesign))
            .foregroundStyle(.white.opacity(0.80))
            .textSelection(.enabled)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(tone.backgroundColor.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(tone.borderColor.opacity(0.55), lineWidth: 1)
            )
    }
}
