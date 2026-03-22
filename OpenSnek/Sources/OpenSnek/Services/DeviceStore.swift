import Foundation
import Observation
import OpenSnekCore
import SwiftUI

@MainActor
@Observable
final class DeviceStore {
    let environment: AppEnvironment
    var devices: [MouseDevice] = []
    var selectedDeviceID: String?
    var state: MouseState?
    var availableUpdate: ReleaseAvailability?
    var isLoading = false
    var isApplying = false
    var isRefreshingState = false
    var errorMessage: String?
    var warningMessage: String?
    var lastUpdated: Date?
    var connectionDiagnosticsRevision = 0

    @ObservationIgnored private weak var deviceControllerStorage: AppStateDeviceController?
    @ObservationIgnored private weak var applyControllerStorage: AppStateApplyController?
    @ObservationIgnored private weak var runtimeControllerStorage: AppStateRuntimeController?
    @ObservationIgnored private weak var runtimeStoreStorage: RuntimeStore?
    @ObservationIgnored private weak var editorStoreStorage: EditorStore?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func bind(
        deviceController: AppStateDeviceController,
        applyController: AppStateApplyController,
        runtimeController: AppStateRuntimeController,
        runtimeStore: RuntimeStore,
        editorStore: EditorStore
    ) {
        self.deviceControllerStorage = deviceController
        self.applyControllerStorage = applyController
        self.runtimeControllerStorage = runtimeController
        self.runtimeStoreStorage = runtimeStore
        self.editorStoreStorage = editorStore
    }

    private var deviceController: AppStateDeviceController {
        guard let deviceControllerStorage else {
            preconditionFailure("DeviceStore accessed before deviceController was bound")
        }
        return deviceControllerStorage
    }

    private var applyController: AppStateApplyController {
        guard let applyControllerStorage else {
            preconditionFailure("DeviceStore accessed before applyController was bound")
        }
        return applyControllerStorage
    }

    private var runtimeController: AppStateRuntimeController {
        guard let runtimeControllerStorage else {
            preconditionFailure("DeviceStore accessed before runtimeController was bound")
        }
        return runtimeControllerStorage
    }

    private var editorStore: EditorStore {
        guard let editorStoreStorage else {
            preconditionFailure("DeviceStore accessed before editorStore was bound")
        }
        return editorStoreStorage
    }

    private var runtimeStore: RuntimeStore {
        guard let runtimeStoreStorage else {
            preconditionFailure("DeviceStore accessed before runtimeStore was bound")
        }
        return runtimeStoreStorage
    }

    var selectedDevice: MouseDevice? {
        guard let selectedDeviceID else { return nil }
        return devices.first(where: { $0.id == selectedDeviceID })
    }

    var usesRemoteServiceTransport: Bool {
        environment.usesRemoteServiceTransport
    }

    var selectedDeviceIsStrictlyUnsupported: Bool {
        guard let selectedDevice else { return false }
        return deviceController.isStrictlyUnsupported(selectedDevice)
    }

    var selectedDeviceIsUnsupportedUSB: Bool {
        guard let selectedDevice else { return false }
        return selectedDevice.transport == .usb && resolvedProfile(for: selectedDevice) == nil
    }

    var selectedDeviceControlsEnabled: Bool {
        _ = connectionDiagnosticsRevision
        guard let selectedDevice else { return false }
        return deviceController.connectionState(for: selectedDevice).allowsInteraction
    }

    var selectedDeviceSupportsPassiveDPIInput: Bool {
        guard let selectedDevice else { return false }
        return resolvedProfile(for: selectedDevice)?.passiveDPIInput != nil
    }

    var currentBuildChannel: AppBuildChannel {
        ReleaseUpdateChecker.currentBuildChannel()
    }

    var selectedDeviceInteractionMessage: String? {
        _ = connectionDiagnosticsRevision
        guard let selectedDevice else { return nil }
        switch deviceController.connectionState(for: selectedDevice) {
        case .reconnecting:
            return "Reconnecting to live telemetry. Controls will unlock automatically."
        case .disconnected:
            return "This device is disconnected. Controls will unlock after it reconnects."
        case .error:
            return errorMessage ?? "Live telemetry is unavailable right now."
        case .unsupported, .connected:
            return nil
        }
    }

    var currentDeviceStatusIndicator: DeviceStatusIndicator {
        _ = connectionDiagnosticsRevision
        guard let selectedDevice else { return DeviceConnectionState.disconnected.indicator }
        let base = deviceController.statusIndicator(for: selectedDevice)
        guard deviceController.connectionState(for: selectedDevice) == .connected,
              selectedDeviceSupportsPassiveDPIInput,
              deviceController.dpiUpdateTransportStatus(for: selectedDevice) == .pollingFallback else {
            return base
        }
        return DeviceStatusIndicator(label: base.label, color: Color(hex: 0xF4C65D))
    }

    var currentDeviceStatusTooltip: String? {
        _ = connectionDiagnosticsRevision
        guard let selectedDevice else { return nil }
        let telemetryStatus = deviceController.connectionState(for: selectedDevice)
        let realtimeStatus = deviceController.dpiUpdateTransportStatus(for: selectedDevice)
        let controlTransport = state?.connection ?? selectedDevice.connectionLabel

        let realtimeLabel: String
        if selectedDeviceSupportsPassiveDPIInput {
            realtimeLabel = realtimeStatus.diagnosticsLabel
        } else {
            realtimeLabel = "Not used on this device"
        }

        return [
            "Control transport: \(controlTransport)",
            "Telemetry: \(telemetryStatus.diagnosticsLabel)",
            "Real-time HID: \(realtimeLabel)",
            "Input Monitoring: \(runtimeStore.hidAccessStatus.diagnosticsLabel)"
        ].joined(separator: "\n")
    }

    var currentDeviceConnectionTooltip: String? {
        _ = connectionDiagnosticsRevision
        guard let selectedDevice else { return nil }
        let telemetryStatus = deviceController.connectionState(for: selectedDevice)
        let realtimeStatus = deviceController.dpiUpdateTransportStatus(for: selectedDevice)
        let controlTransport = state?.connection ?? selectedDevice.connectionLabel

        var lines = [
            "Transport: \(selectedDevice.connectionLabel)",
            "Connection state: \(telemetryStatus.diagnosticsLabel)",
            "Control transport: \(controlTransport)"
        ]

        if selectedDeviceSupportsPassiveDPIInput {
            lines.append("Real-time HID: \(realtimeStatus.diagnosticsLabel)")
            lines.append("Input Monitoring: \(runtimeStore.hidAccessStatus.diagnosticsLabel)")
        }

        return lines.joined(separator: "\n")
    }

    var visibleButtonSlots: [ButtonSlotDescriptor] {
        selectedDevice?.button_layout?.visibleSlots ?? ButtonSlotDescriptor.defaults
    }

    var hiddenUnsupportedButtonSlots: [DocumentedButtonSlot] {
        guard let layout = selectedDevice?.button_layout else { return [] }
        let visible = Set(layout.visibleSlots.map(\.slot))
        return layout.documentedSlots.filter { slot in
            slot.access != .editable && !visible.contains(slot.slot)
        }
    }

    func selectDevice(_ deviceID: String) {
        deviceController.selectDevice(deviceID)
    }

    func refreshDevices() async {
        await runtimeController.ensureBackendStateUpdatesStarted()
        await runtimeController.refreshHIDAccessStatus(forceRefresh: false)
        await deviceController.refreshDevices()
    }

    func refreshState() async {
        await runtimeController.ensureBackendStateUpdatesStarted()
        await deviceController.refreshState()
    }

    func pollDevicePresence() async {
        await runtimeController.ensureBackendStateUpdatesStarted()
        await deviceController.pollDevicePresence()
    }

    func refreshDpiFast() async {
        await runtimeController.ensureBackendStateUpdatesStarted()
        await deviceController.refreshDpiFast()
    }

    func applyRemoteServiceSnapshot(_ snapshot: SharedServiceSnapshot) {
        deviceController.applyRemoteServiceSnapshot(snapshot)
    }

    func refreshConnectionDiagnostics(for device: MouseDevice) async {
        await deviceController.refreshConnectionDiagnostics(for: device)
    }

    func diagnosticsConnectionLines(for device: MouseDevice) -> [String] {
        _ = connectionDiagnosticsRevision
        return deviceController.diagnosticsConnectionLines(for: device)
    }

    func invalidateConnectionDiagnostics() {
        connectionDiagnosticsRevision &+= 1
    }

    func diagnosticsDump(for device: MouseDevice, state explicitState: MouseState? = nil) -> String {
        let resolvedProfile = resolvedProfile(for: device)
        let liveState = explicitState ?? deviceController.cachedState(for: device.id) ?? (device.id == selectedDeviceID ? state : nil)
        let deviceStatusIndicator = deviceController.statusIndicator(for: device)
        let deviceConnectionState = deviceController.connectionState(for: device)
        let deviceLastUpdated = deviceController.lastUpdatedTimestamp(for: device)
        let appContextLines: [String] = [
            "App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")",
            "Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")",
            "Selected device ID: \(selectedDeviceID ?? "none")",
            "Refreshing state: \(isRefreshingState ? "Yes" : "No")",
            "Applying changes: \(isApplying ? "Yes" : "No")",
            "Pending local edits: \(applyController.hasPendingLocalEdits ? "Yes" : "No")",
            "Current status badge: \(deviceStatusIndicator.label)",
            "Current connection state: \(deviceConnectionState.diagnosticsLabel)",
            "Last updated: \(deviceLastUpdated.map(diagnosticsTimestamp) ?? "Never")",
            "Last selected-state update: \(lastUpdated.map(diagnosticsTimestamp) ?? "Never")",
            "Current error: \(errorMessage ?? "none")",
            "Current warning: \(warningMessage ?? "none")",
            "Input Monitoring: \(runtimeStore.hidAccessStatus.diagnosticsLabel)",
            "Input Monitoring host: \(runtimeStore.hidAccessStatus.hostLabel)",
            "Polling profile: \(pollingProfileLabel(runtimeController.pollingProfile(at: Date())))",
            "Remote service transport: \(usesRemoteServiceTransport ? "Enabled" : "Disabled")",
            "Compact menu service: \(runtimeStore.backgroundServiceEnabled ? "Enabled" : "Disabled")",
        ]
        var lines = appContextLines
        if let hidAccessDetail = runtimeStore.hidAccessStatus.detail {
            lines.append("Input Monitoring detail: \(hidAccessDetail)")
        }
        if device.id == selectedDeviceID {
            lines.append("Editable lighting effect: \(editorStore.editableLightingEffect.label)")
            lines.append("Editable lighting zone: \(editorStore.editableUSBLightingZoneID)")
            lines.append("Editable button profile: \(editorStore.editableUSBButtonProfile)")
            lines.append("Editable color: \(diagnosticsRGB(editorStore.editableColor))")
            lines.append("Editable secondary color: \(diagnosticsRGB(editorStore.editableSecondaryColor))")
        }
        return DeviceDiagnosticsFormatter.format(
            device: device,
            state: liveState,
            profile: resolvedProfile,
            appContextLines: lines
        )
    }

    func githubIssueDiagnosticsPayload() -> String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        let deviceEntries = devices.map { device in
            let resolvedProfile = resolvedProfile(for: device)
            let summary = "\(device.product_name) (\(device.transport.connectionLabel), " +
                "\(String(format: "0x%04X", device.vendor_id)):\(String(format: "0x%04X", device.product_id)), " +
                "profile \(resolvedProfile?.id.rawValue ?? "generic"))"
            let stateForDevice = device.id == selectedDeviceID ? state : deviceController.cachedState(for: device.id)
            return IssueReportDeviceEntry(
                title: "\(device.product_name) [\(device.transport.connectionLabel)]",
                summary: summary,
                diagnostics: diagnosticsDump(for: device, state: stateForDevice)
            )
        }

        return IssueReportFormatter.format(
            appVersion: appVersion,
            build: build,
            logLevel: AppLog.currentLevel.label,
            logPath: AppLog.path,
            selectedDevice: selectedDevice.map { "\($0.product_name) [\($0.transport.connectionLabel)]" },
            warning: warningMessage,
            error: errorMessage,
            devices: deviceEntries
        )
    }

    func isButtonSlotEditable(_ slot: Int) -> Bool {
        selectedDevice?.button_layout?.isEditable(slot) ?? true
    }

    func buttonSlotNotice(_ slot: Int) -> String? {
        selectedDevice?.button_layout?.notice(for: slot)
    }

    private func resolvedProfile(for device: MouseDevice) -> DeviceProfile? {
        DeviceProfiles.resolve(
            vendorID: device.vendor_id,
            productID: device.product_id,
            transport: device.transport
        )
    }

    private func diagnosticsTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func diagnosticsRGB(_ color: RGBColor) -> String {
        String(format: "#%02X%02X%02X", color.r, color.g, color.b)
    }

    private func pollingProfileLabel(_ profile: PollingProfile) -> String {
        switch profile {
        case .foreground:
            "foreground"
        case .serviceIdle:
            "serviceIdle"
        case .serviceInteractive:
            "serviceInteractive"
        }
    }
}
