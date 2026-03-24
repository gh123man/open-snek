import SwiftUI
import AppKit
import OpenSnekCore

struct ContentView: View {
    let deviceStore: DeviceStore
    let editorStore: EditorStore
    let runtimeStore: RuntimeStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var dismissedPermissionNoticeKey: String?

    var body: some View {
        NavigationSplitView {
            DeviceSidebarView(deviceStore: deviceStore)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.automatic)
        .task {
            await runtimeStore.start()
            await runtimeStore.refreshHIDAccessStatus(forceRefresh: false)
        }
        .onChange(of: deviceStore.selectedDeviceID) { _, _ in
            guard !deviceStore.usesRemoteServiceTransport || deviceStore.state == nil else { return }
            Task { await deviceStore.refreshState() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await runtimeStore.refreshHIDAccessStatus(forceRefresh: false)
                    if deviceStore.usesRemoteServiceTransport {
                        runtimeStore.sendRemoteClientPresence()
                    } else {
                        await deviceStore.refreshDevices()
                    }
                }
            }
        }
        .onChange(of: runtimeStore.hidAccessStatus.authorization) { _, authorization in
            if authorization != .denied {
                dismissedPermissionNoticeKey = nil
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

            if let selected = deviceStore.selectedDevice {
                if deviceStore.selectedDeviceIsStrictlyUnsupported || deviceStore.selectedDeviceIsUnsupportedUSB {
                    GenericDeviceDetailView(deviceStore: deviceStore, selected: selected)
                } else if let state = deviceStore.state,
                          state.device.id == nil || state.device.id == selected.id {
                    DeviceDetailView(
                        deviceStore: deviceStore,
                        editorStore: editorStore,
                        selected: selected,
                        state: state
                    )
                } else if shouldShowLoadingDetail(for: selected) {
                    DeviceConnectingDetailView(deviceStore: deviceStore, selected: selected)
                } else {
                    DeviceUnavailableDetailView(deviceStore: deviceStore, selected: selected)
                }
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

    private func shouldShowLoadingDetail(for selected: MouseDevice) -> Bool {
        guard deviceStore.selectedDeviceID == selected.id else { return false }
        if deviceStore.isRefreshingState {
            return true
        }

        switch deviceStore.connectionState(for: selected) {
        case .connected, .reconnecting:
            return true
        case .disconnected, .unsupported, .error:
            return false
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

    private var permissionGuidanceDetailLines: [String] {
        [
            "Open Input Monitoring settings and turn on OpenSnek.",
            "If it still looks stuck, use Reset Permissions and try again.",
            "After changing the permission, quit and reopen OpenSnek.",
            "Current app host: \(runtimeStore.hidAccessStatus.hostLabel)"
        ]
    }

    private var activePermissionNoticeKey: String? {
        guard runtimeStore.hidAccessStatus.isDenied,
              let selectedDevice = deviceStore.selectedDevice else {
            return nil
        }
        if selectedDevice.transport == .bluetooth, deviceStore.selectedDeviceSupportsPassiveDPIInput {
            return "bt:\(selectedDevice.id):\(runtimeStore.hidAccessStatus.authorization.rawValue)"
        }
        if selectedDevice.transport == .usb, isInputMonitoringError(deviceStore.errorMessage) {
            return "usb:\(selectedDevice.id):\(runtimeStore.hidAccessStatus.authorization.rawValue)"
        }
        return nil
    }

    private var shouldShowPermissionNotice: Bool {
        guard let activePermissionNoticeKey else { return false }
        return dismissedPermissionNoticeKey != activePermissionNoticeKey
    }

    private var showsBluetoothHIDAccessCallout: Bool {
        guard runtimeStore.hidAccessStatus.isDenied else { return false }
        guard let selectedDevice = deviceStore.selectedDevice, selectedDevice.transport == .bluetooth else { return false }
        return deviceStore.selectedDeviceSupportsPassiveDPIInput && shouldShowPermissionNotice
    }

    private var showsUSBAccessCallout: Bool {
        guard deviceStore.selectedDevice?.transport == .usb else { return false }
        if isInputMonitoringError(deviceStore.errorMessage) {
            return shouldShowPermissionNotice
        }
        if deviceStore.warningMessage != nil {
            return true
        }
        guard let state = deviceStore.state else { return false }
        return state.dpi_stages.values == nil || state.poll_rate == nil || state.led_value == nil
    }

    private var usbCalloutTitle: String {
        if isInputMonitoringError(deviceStore.errorMessage) {
            return "USB Access Blocked"
        }
        return "USB Telemetry Limited"
    }

    private var usbCalloutMessage: String {
        if let warning = deviceStore.warningMessage {
            return warning
        }
        return "DPI, polling, or lighting readback is unavailable for this device session."
    }

    private var noticeItems: [NoticeItem] {
        var notices: [NoticeItem] = []

        if showsBluetoothHIDAccessCallout, let selectedDevice = deviceStore.selectedDevice {
            notices.append(
                NoticeItem(
                    title: "Allow Input Monitoring",
                    message: "OpenSnek can talk to \(selectedDevice.product_name), but macOS is still blocking the permission that lets instant on-device DPI changes show up right away.",
                    detailLines: permissionGuidanceDetailLines,
                    tone: .permission,
                    actions: [
                        NoticeAction(title: "Open Settings", isProminent: true) {
                            PermissionSupport.openInputMonitoringSettings()
                        },
                        NoticeAction(title: "Reset Permissions") {
                            Task { await runtimeStore.resetAllPermissions() }
                        },
                        NoticeAction(title: "Refresh") {
                            Task {
                                await runtimeStore.refreshHIDAccessStatus(forceRefresh: true)
                                await deviceStore.refreshDevices()
                            }
                        },
                        NoticeAction(title: "Dismiss") {
                            dismissedPermissionNoticeKey = activePermissionNoticeKey
                        }
                    ]
                )
            )
        }

        if showsUSBAccessCallout {
            var detailLines: [String] = []
            var actions: [NoticeAction] = [
                NoticeAction(title: "Refresh") {
                    Task {
                        await runtimeStore.refreshHIDAccessStatus(forceRefresh: true)
                        await deviceStore.refreshDevices()
                    }
                }
            ]

            if isInputMonitoringError(deviceStore.errorMessage) {
                detailLines = permissionGuidanceDetailLines
                actions.insert(
                    NoticeAction(title: "Open Settings", isProminent: true) {
                        PermissionSupport.openInputMonitoringSettings()
                    },
                    at: 0
                )
                actions.insert(
                    NoticeAction(title: "Reset Permissions") {
                        Task { await runtimeStore.resetAllPermissions() }
                    },
                    at: 1
                )
                actions.append(
                    NoticeAction(title: "Dismiss") {
                        dismissedPermissionNoticeKey = activePermissionNoticeKey
                    }
                )
            }

            notices.append(
                NoticeItem(
                    title: isInputMonitoringError(deviceStore.errorMessage) ? "Allow Input Monitoring" : usbCalloutTitle,
                    message: isInputMonitoringError(deviceStore.errorMessage)
                        ? "OpenSnek needs one more macOS permission before it can read all USB settings from this mouse."
                        : usbCalloutMessage,
                    detailLines: detailLines,
                    tone: isInputMonitoringError(deviceStore.errorMessage) ? .permission : .warning,
                    actions: actions
                )
            )
        }

        if let error = deviceStore.errorMessage, shouldShowSeparateErrorNotice {
            notices.append(
                NoticeItem(
                    title: errorNoticeTitle(for: error),
                    message: error,
                    tone: .error,
                    actions: []
                )
            )
        }

        if let warning = deviceStore.warningMessage, shouldShowSeparateWarningNotice {
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
        guard deviceStore.errorMessage != nil else { return false }
        if isInputMonitoringError(deviceStore.errorMessage), showsUSBAccessCallout {
            return false
        }
        return true
    }

    private var shouldShowSeparateWarningNotice: Bool {
        guard deviceStore.warningMessage != nil else { return false }
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
    @State private var showsWaitingState = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                if showsWaitingState {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white.opacity(0.9))
                        Text("Waiting for devices")
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                    }
                } else {
                    Text("Connect a device")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
                Text("Supported devices")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
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
        .task {
            guard showsWaitingState else { return }
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            withAnimation(.easeInOut(duration: 0.18)) {
                showsWaitingState = false
            }
        }
    }
}

private struct SupportedDeviceRowView: View {
    let row: SupportedDeviceRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)

            ForEach(row.transports, id: \.self) { transport in
                Pill(
                    text: transport.shortLabel,
                    color: transport == .bluetooth ? Color(hex: 0x66D9FF) : Color(hex: 0xA8F46A),
                    fontSize: 10,
                    horizontalPadding: 8,
                    verticalPadding: 4
                )
            }

            Spacer(minLength: 0)
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
    case permission

    var backgroundColor: Color {
        switch self {
        case .error:
            Color(hex: 0xB3261E)
        case .warning:
            Color(hex: 0x8A6A00)
        case .permission:
            Color(hex: 0x8D6B2C)
        }
    }

    var borderColor: Color {
        switch self {
        case .error:
            Color(hex: 0xFF8A80)
        case .warning:
            Color(hex: 0xF4C65D)
        case .permission:
            Color(hex: 0xF1CA82)
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
