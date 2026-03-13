import AppKit
import SwiftUI

struct SettingsView: View {
    let deviceStore: DeviceStore
    let runtimeStore: RuntimeStore
    @AppStorage(AppLog.levelDefaultsKey) private var logLevelRawValue = AppLog.currentLevel.rawValue
    @State private var showsDiagnosticsSheet = false

    private var selectedLevel: Binding<AppLogLevel> {
        Binding(
            get: { AppLogLevel(rawValue: logLevelRawValue) ?? AppLog.defaultLevel },
            set: {
                logLevelRawValue = $0.rawValue
                AppLog.updateLevel($0)
            }
        )
    }

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Input Monitoring") {
                    Text(runtimeStore.hidAccessStatus.diagnosticsLabel)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(permissionStatusColor)
                }

                Text(permissionSummary)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(runtimeStore.hidAccessStatus.isDenied ? .red : .secondary)

                Text("Current host: \(runtimeStore.hidAccessStatus.hostLabel)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)

                if let detail = runtimeStore.hidAccessStatus.detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("Open Input Monitoring Settings") {
                        PermissionSupport.openInputMonitoringSettings()
                    }

                    Button("Reset All Permissions") {
                        Task { await runtimeStore.resetAllPermissions() }
                    }
                    .disabled(runtimeStore.isResettingPermissions)

                    if runtimeStore.isResettingPermissions {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let message = runtimeStore.permissionStatusMessage {
                    Text(message)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Menu bar icon", isOn: Binding(
                    get: { runtimeStore.backgroundServiceEnabled },
                    set: { newValue in
                        Task { await runtimeStore.setBackgroundServiceEnabled(newValue) }
                    }
                ))

                Toggle("Start at login", isOn: Binding(
                    get: { runtimeStore.launchAtStartupEnabled },
                    set: { runtimeStore.setLaunchAtStartupEnabled($0) }
                ))
                .disabled(!runtimeStore.backgroundServiceEnabled)

                Text("When enabled, Open Snek keeps a compact menu bar icon running as a separate background instance. The full app can still be launched at any time.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                if let message = runtimeStore.compactStatusMessage ?? runtimeStore.serviceStatusMessage {
                    Text(message)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Logging") {
                Picker("Log level", selection: selectedLevel) {
                    ForEach(AppLogLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.menu)

                Text("Default is Warning. Raise this to Info or Debug before reproducing a bug if you need a more detailed log.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text("Changing the level starts a fresh log file so the captured output matches the selected threshold.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(AppLog.path)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    Button("Open Log File") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: AppLog.path))
                    }

                    Button("Open Log Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: AppLog.path)])
                    }

                    Button("Clear Log") {
                        AppLog.clear()
                    }
                }
            }

            Section("Bug Reports") {
                Text("Useful reports include the active protocol, the exact action that failed, whether it reproduced after reconnect, and a log captured at Info or Debug level.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text("Use the diagnostics payload below for GitHub issues. It includes app info, connected devices, support profile details, and live device state.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Preview Diagnostics Payload") {
                        showsDiagnosticsSheet = true
                    }

                    Button("Copy GitHub Issue Payload") {
                        copyDiagnosticsPayload()
                    }

                    Button("Open Bug Report") {
                        openBugReport()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520)
        .task {
            await runtimeStore.refreshHIDAccessStatus()
        }
        .sheet(isPresented: $showsDiagnosticsSheet) {
            IssueDiagnosticsSheet(payload: deviceStore.githubIssueDiagnosticsPayload())
        }
        .onAppear {
            AppLog.updateLevel(AppLogLevel(rawValue: logLevelRawValue) ?? AppLog.defaultLevel, resetLog: false)
        }
    }

    private var permissionStatusColor: Color {
        switch runtimeStore.hidAccessStatus.authorization {
        case .granted:
            return Color.green
        case .denied:
            return Color(hex: 0xD59A2B)
        case .unknown, .unavailable:
            return Color.secondary
        }
    }

    private var permissionSummary: String {
        switch runtimeStore.hidAccessStatus.authorization {
        case .granted:
            return "Input Monitoring is enabled, so Open Snek can attach real-time HID listeners for supported USB and Bluetooth devices."
        case .denied:
            return "macOS still needs you to allow Input Monitoring for this Open Snek host before instant DPI updates and some USB reads can work normally."
        case .unknown:
            return "Open Snek is still checking macOS HID permission state."
        case .unavailable:
            return "Open Snek could not confirm the current HID permission state. Use the controls below to reopen the settings pane or reset the app's TCC grants."
        }
    }

    private func copyDiagnosticsPayload() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deviceStore.githubIssueDiagnosticsPayload(), forType: .string)
    }

    private func openBugReport() {
        guard let url = URL(string: "https://github.com/gh123man/open-snek/issues/new?template=bug_report.md") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct IssueDiagnosticsSheet: View {
    let payload: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GitHub Issue Payload")
                        .font(.system(size: 21, weight: .black, design: .rounded))
                    Text("Paste this into a GitHub bug report.")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload, forType: .string)
                }
                .buttonStyle(.borderedProminent)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            ScrollView {
                Text(payload)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 560, alignment: .topLeading)
    }
}
