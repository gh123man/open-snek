import AppKit
import OpenSnekAppSupport
import SwiftUI

struct SettingsView: View {
    let deviceStore: DeviceStore
    let runtimeStore: RuntimeStore
    @AppStorage(AppLog.levelDefaultsKey) private var logLevelRawValue = AppLog.currentLevel.rawValue
    @AppStorage(DeveloperRuntimeOptions.pollingEnabledDefaultsKey) private var developerPollingEnabled = true
    @AppStorage(DeveloperRuntimeOptions.passiveHIDUpdatesEnabledDefaultsKey) private var developerPassiveHIDUpdatesEnabled = true
    @State private var showsDiagnosticsSheet = false
    @State private var showsLocalStorageResetConfirmation = false

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

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Button("Open Settings") {
                            PermissionSupport.openInputMonitoringSettings()
                        }

                        Button("Reset Permissions") {
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
            }

            Section("General") {
                Toggle("Show menu bar icon", isOn: Binding(
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

                if let message = runtimeStore.compactStatusMessage ?? runtimeStore.serviceStatusMessage {
                    Text(message)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Reset App Data") {
                Text("Wipe OpenSnek's saved preferences, cached device settings, background-service state, and local logs. Relaunch the app after resetting.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Wipe Local Storage", role: .destructive) {
                        showsLocalStorageResetConfirmation = true
                    }
                    .disabled(runtimeStore.isResettingLocalStorage)

                    if runtimeStore.isResettingLocalStorage {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let message = runtimeStore.localStorageResetMessage {
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

                Text("Use Info or Debug before reproducing a bug. Changing the level starts a fresh log file.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                LabeledContent("Log file") {
                    Text(AppLog.path)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                }

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

            if deviceStore.currentBuildChannel == .dev {
                Section("Developer") {
                    Toggle("Enable runtime polling", isOn: Binding(
                        get: { developerPollingEnabled },
                        set: { newValue in
                            developerPollingEnabled = newValue
                            runtimeStore.developerTransportSettingsDidChange()
                        }
                    ))

                    Toggle("Enable passive HID DPI stream", isOn: Binding(
                        get: { developerPassiveHIDUpdatesEnabled },
                        set: { newValue in
                            developerPassiveHIDUpdatesEnabled = newValue
                            runtimeStore.developerTransportSettingsDidChange()
                        }
                    ))

                    Text("Use these switches to isolate polling from passive HID DPI callbacks during debugging.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Bug Reports") {
                Text("Include the failing action, whether reconnecting changed it, and a log captured at Info or Debug.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Preview Payload") {
                        showsDiagnosticsSheet = true
                    }

                    Button("Copy Payload") {
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
            await runtimeStore.refreshHIDAccessStatus(forceRefresh: false)
        }
        .sheet(isPresented: $showsDiagnosticsSheet) {
            IssueDiagnosticsSheet(payload: deviceStore.githubIssueDiagnosticsPayload())
        }
        .alert("Wipe OpenSnek local storage?", isPresented: $showsLocalStorageResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Wipe", role: .destructive) {
                Task {
                    let didReset = await runtimeStore.resetAllLocalStorage()
                    guard didReset else { return }
                    logLevelRawValue = AppLog.defaultLevel.rawValue
                    developerPollingEnabled = true
                    developerPassiveHIDUpdatesEnabled = true
                }
            }
        } message: {
            Text("This removes saved preferences, cached device settings, launch-at-login state, and local logs for OpenSnek.")
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

    private func copyDiagnosticsPayload() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deviceStore.githubIssueDiagnosticsPayload(), forType: .string)
    }

    private func openBugReport() {
        guard let url = URL(string: "https://github.com/gh123man/OpenSnek/issues/new?template=bug_report.md") else { return }
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
