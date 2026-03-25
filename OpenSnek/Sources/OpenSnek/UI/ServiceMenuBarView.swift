import AppKit
import OpenSnekCore
import SwiftUI

struct BatteryIconPresentation: Equatable {
    enum Accent: Equatable {
        case normal
        case low
    }

    let symbolName: String
    let variableValue: Double
    let accent: Accent
}

enum BatteryPresentation {
    static let lowBatteryColor = Color(hex: 0xFF5C64)

    static func icon(percent: Int, charging: Bool?, thresholdRaw: Int? = nil) -> BatteryIconPresentation {
        let clampedPercent = max(0, min(100, percent))
        let isLow = isLowBattery(percent: clampedPercent, charging: charging, thresholdRaw: thresholdRaw)
        return BatteryIconPresentation(
            symbolName: charging == true ? "battery.100percent.bolt" : (isLow ? "battery.25percent" : "battery.100percent"),
            variableValue: isLow ? 0.25 : Double(clampedPercent) / 100.0,
            accent: isLow ? .low : .normal
        )
    }

    static func isLowBattery(percent: Int, charging: Bool?, thresholdRaw: Int?) -> Bool {
        guard charging != true,
              let thresholdPercent = approximateThresholdPercent(raw: thresholdRaw) else {
            return false
        }
        return max(0, min(100, percent)) <= thresholdPercent
    }

    static func approximateThresholdPercent(raw: Int?) -> Int? {
        guard let raw else { return nil }
        let clamped = max(0x0C, min(0x3F, raw))
        let ratio = Double(clamped - 0x0C) / Double(0x3F - 0x0C)
        return Int(round(5.0 + (ratio * 20.0)))
    }
}

enum ServiceMenuBarPresentation {
    enum CompactDpiControlMode: Equatable {
        case scalar(Int)
        case split(DpiPair)
    }

    static func batteryIcon(percent: Int, charging: Bool?, thresholdRaw: Int? = nil) -> BatteryIconPresentation {
        BatteryPresentation.icon(percent: percent, charging: charging, thresholdRaw: thresholdRaw)
    }

    static func showsLowBatteryStatusGlyph(state: MouseState?) -> Bool {
        guard let state,
              let percent = state.battery_percent else {
            return false
        }
        return BatteryPresentation.isLowBattery(
            percent: percent,
            charging: state.charging,
            thresholdRaw: state.low_battery_threshold_raw
        )
    }

    static func compactDpiText(for dpi: Int?) -> String? {
        guard let dpi, dpi > 0 else { return nil }
        guard dpi >= 1000 else { return "\(dpi)" }

        let thousands = Double(dpi) / 1000.0
        if dpi < 10_000 {
            let rounded = (thousands * 10).rounded() / 10
            if rounded == rounded.rounded() {
                return "\(Int(rounded))k"
            }
            return String(format: "%.1fk", rounded)
        }

        return "\(Int(thousands.rounded()))k"
    }

    static func compactDpiControlMode(
        for pair: DpiPair,
        supportsIndependentXYDPI: Bool
    ) -> CompactDpiControlMode {
        guard supportsIndependentXYDPI, pair.x != pair.y else {
            return .scalar(pair.x)
        }
        return .split(pair)
    }
}

struct ServiceMenuBarView: View {
    private static let menuActionRowHeight: CGFloat = 34

    let deviceStore: DeviceStore
    let editorStore: EditorStore
    let runtimeStore: RuntimeStore

    private var showsDeviceControls: Bool {
        deviceStore.selectedDevice != nil && deviceStore.state != nil
    }

    private var controlsEnabled: Bool {
        deviceStore.selectedDeviceControlsEnabled
    }

    private var showsDevicePicker: Bool {
        deviceStore.devices.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusRow
            if showsDeviceControls {
                VStack(alignment: .leading, spacing: 10) {
                    if !controlsEnabled, let message = deviceStore.selectedDeviceInteractionMessage {
                        Text(message)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        stagePicker
                        dpiSlider
                    }
                    .disabled(!controlsEnabled)
                    .opacity(controlsEnabled ? 1.0 : 0.45)

                    if let message = runtimeStore.compactStatusMessage {
                        Text(message)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let message = deviceStore.selectedDeviceInteractionMessage {
                Text(message)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                Text("Connect a supported mouse to edit DPI from the menu bar.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Divider()
            actionRow("Show OpenSnek", systemImage: "rectangle.on.rectangle") {
                runtimeStore.openFullAppFromService()
            }
            actionRow("Settings…", systemImage: "gearshape") {
                runtimeStore.openSettingsFromService()
            }
            toggleRow("Start at login", systemImage: "checkmark.circle", isOn: Binding(
                get: { runtimeStore.launchAtStartupEnabled },
                set: { runtimeStore.setLaunchAtStartupEnabled($0) }
            ))
            actionRow("Quit", systemImage: "power") {
                runtimeStore.terminateServiceProcess()
            }
        }
        .padding(16)
        .frame(width: 320)
        .task {
            await runtimeStore.start()
            await refreshCompactMenuDiagnostics()
        }
        .task(id: deviceStore.selectedDeviceID) {
            await refreshCompactMenuDiagnostics()
        }
        .onAppear {
            runtimeStore.setCompactMenuPresented(true)
            Task {
                await refreshCompactMenuDiagnostics()
            }
        }
        .onDisappear {
            runtimeStore.setCompactMenuPresented(false)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: showsDevicePicker ? 8 : 3) {
            if showsDevicePicker {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Menu {
                        ForEach(deviceStore.devices) { device in
                            Button {
                                deviceStore.selectDevice(device.id)
                            } label: {
                                if device.id == deviceStore.selectedDeviceID {
                                    Label(devicePickerTitle(for: device), systemImage: "checkmark")
                                } else {
                                    Text(devicePickerTitle(for: device))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(selectedDevicePickerTitle)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.primary.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(deviceStore.selectedDevice?.product_name ?? "No device connected")
                    .font(.system(size: 15, weight: .black, design: .rounded))
            }
            Text(deviceStore.selectedDevice?.connectionLabel ?? "Waiting for a supported mouse")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Label(deviceStore.currentDeviceStatusIndicator.label, systemImage: "circle.fill")
                .foregroundStyle(deviceStore.currentDeviceStatusIndicator.color)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .help(deviceStore.currentDeviceStatusTooltip ?? "")

            Spacer()

            if let battery = deviceStore.state?.battery_percent {
                let batteryIcon = ServiceMenuBarPresentation.batteryIcon(
                    percent: battery,
                    charging: deviceStore.state?.charging,
                    thresholdRaw: deviceStore.state?.low_battery_threshold_raw
                )
                HStack(spacing: 4) {
                    Image(
                        systemName: batteryIcon.symbolName,
                        variableValue: batteryIcon.variableValue
                    )
                    Text("\(battery)%")
                }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(batteryIcon.accent == .low ? BatteryPresentation.lowBatteryColor : .secondary)
            }
        }
    }

    private var stagePicker: some View {
        HStack(spacing: 8) {
            ForEach(0..<max(1, editorStore.editableStageCount), id: \.self) { index in
                let stage = index + 1
                let stagePair = editorStore.stagePair(index)
                let isSelected = editorStore.editableActiveStage == stage
                Button {
                    if !isSelected {
                        editorStore.editableActiveStage = stage
                        editorStore.scheduleAutoApplyActiveStage()
                    }
                } label: {
                    Text(stageDisplayText(stagePair))
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                        )
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: 1)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var selectedDevicePickerTitle: String {
        guard let selected = deviceStore.selectedDevice else {
            return "No device connected"
        }
        return devicePickerTitle(for: selected)
    }

    private func devicePickerTitle(for device: MouseDevice) -> String {
        "\(device.product_name) (\(device.transport.shortLabel))"
    }

    private var dpiSlider: some View {
        let profileID = editorStore.selectedDeviceProfileID
        let activePair = editorStore.stagePair(editorStore.compactActiveStageIndex)
        let controlMode = ServiceMenuBarPresentation.compactDpiControlMode(
            for: activePair,
            supportsIndependentXYDPI: editorStore.selectedDeviceSupportsIndependentXYDPI
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dpiSliderTitle(for: controlMode))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Text(dpiSliderValueText(for: controlMode))
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            switch controlMode {
            case .scalar:
                compactDpiSlider(
                    currentValue: { editorStore.stageValue(editorStore.compactActiveStageIndex) },
                    update: { value in
                        editorStore.updateStage(editorStore.compactActiveStageIndex, value: value)
                    },
                    profileID: profileID
                )
            case .split:
                VStack(alignment: .leading, spacing: 10) {
                    compactDpiAxisSlider(
                        axisLabel: "X",
                        currentValue: { editorStore.stagePair(editorStore.compactActiveStageIndex).x },
                        update: { value in
                            editorStore.updateStageX(editorStore.compactActiveStageIndex, value: value)
                        },
                        profileID: profileID
                    )
                    compactDpiAxisSlider(
                        axisLabel: "Y",
                        currentValue: { editorStore.stagePair(editorStore.compactActiveStageIndex).y },
                        update: { value in
                            editorStore.updateStageY(editorStore.compactActiveStageIndex, value: value)
                        },
                        profileID: profileID
                    )
                }
            }
        }
    }

    private func dpiSliderTitle(for mode: ServiceMenuBarPresentation.CompactDpiControlMode) -> String {
        switch mode {
        case .scalar:
            return "Stage \(editorStore.editableActiveStage) DPI"
        case .split:
            return "Stage \(editorStore.editableActiveStage) X/Y DPI"
        }
    }

    private func dpiSliderValueText(for mode: ServiceMenuBarPresentation.CompactDpiControlMode) -> String {
        switch mode {
        case .scalar(let value):
            return "\(value)"
        case .split(let pair):
            return stageDisplayText(pair)
        }
    }

    private func compactDpiAxisSlider(
        axisLabel: String,
        currentValue: @escaping () -> Int,
        update: @escaping (Int) -> Void,
        profileID: DeviceProfileID?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(axisLabel)
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(currentValue())")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            compactDpiSlider(
                currentValue: currentValue,
                update: update,
                profileID: profileID
            )
        }
    }

    private func compactDpiSlider(
        currentValue: @escaping () -> Int,
        update: @escaping (Int) -> Void,
        profileID: DeviceProfileID?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Slider(
                value: Binding(
                    get: { DeviceProfiles.dpiSliderPosition(for: currentValue(), profileID: profileID) },
                    set: { newPosition in
                        update(DeviceProfiles.dpi(forSliderPosition: newPosition, profileID: profileID))
                        editorStore.scheduleAutoApplyDpi()
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    editorStore.isEditingDpiControl = editing
                }
            )
            DpiSliderScaleMarkers(
                profileID: profileID,
                markerColor: Color.primary.opacity(0.78),
                compact: true
            )
        }
    }

    private func stageDisplayText(_ pair: DpiPair) -> String {
        if editorStore.selectedDeviceSupportsIndependentXYDPI, pair.x != pair.y {
            return "\(pair.x)/\(pair.y)"
        }
        return "\(pair.x)"
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: Self.menuActionRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 10)
        .frame(height: Self.menuActionRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func refreshCompactMenuDiagnostics() async {
        // Reopening the compact menu should not tear down the shared HID discovery
        // manager; that can interrupt a passive stream when polling is disabled.
        await runtimeStore.refreshHIDAccessStatus(forceRefresh: false)
        guard let device = deviceStore.selectedDevice else { return }
        await deviceStore.refreshConnectionDiagnostics(for: device)
    }
}

struct ServiceMenuBarStatusItemLabel: View {
    let deviceStore: DeviceStore
    let editorStore: EditorStore
    let runtimeStore: RuntimeStore

    private var currentDpi: Int? {
        guard deviceStore.state != nil else { return nil }

        if let liveDpi = deviceStore.state?.dpi?.x, liveDpi > 0 {
            return liveDpi
        }

        let fallback = editorStore.compactActiveStageValue
        return fallback > 0 ? fallback : nil
    }

    var body: some View {
        Group {
            if let transientDpi = runtimeStore.statusItemTransientDpi {
                ServiceMenuBarStatusDpiBadge(dpi: transientDpi)
                    .frame(width: OpenSnekBranding.menuBarIconSide, height: OpenSnekBranding.menuBarIconSide)
            } else {
                ServiceMenuBarStatusGlyph(
                    isConnected: deviceStore.selectedDevice != nil,
                    showsLowBattery: ServiceMenuBarPresentation.showsLowBatteryStatusGlyph(state: deviceStore.state)
                )
                    .frame(width: OpenSnekBranding.menuBarIconSide, height: OpenSnekBranding.menuBarIconSide)
                    .fixedSize()
            }
        }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        if let device = deviceStore.selectedDevice, let currentDpi {
            return "\(device.product_name), \(currentDpi) DPI"
        }
        if let device = deviceStore.selectedDevice {
            return device.product_name
        }
        return "OpenSnek"
    }
}

private struct ServiceMenuBarStatusDpiBadge: View {
    let dpi: Int

    var body: some View {
        Image(nsImage: OpenSnekBranding.menuBarDpiBadge(dpi: dpi))
            .interpolation(.high)
            .antialiased(true)
    }
}

private struct ServiceMenuBarStatusGlyph: View {
    let isConnected: Bool
    let showsLowBattery: Bool

    private var iconOpacity: Double {
        isConnected ? 0.88 : 0.46
    }

    var body: some View {
        Group {
            if showsLowBattery {
                Image(nsImage: OpenSnekBranding.menuBarLowBatteryBadge())
                    .interpolation(.high)
                    .antialiased(true)
            } else if let menuIcon = OpenSnekBranding.menuIcon {
                Image(nsImage: menuIcon)
                    .renderingMode(.original)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(iconOpacity), lineWidth: 1.2)

                    Rectangle()
                        .fill(Color.primary.opacity(iconOpacity))
                        .frame(width: 1, height: 11)

                    Rectangle()
                        .fill(Color.primary.opacity(iconOpacity))
                        .frame(width: 11, height: 1)

                    Circle()
                        .fill(Color.primary.opacity(iconOpacity))
                        .frame(width: 3.5, height: 3.5)
                }
            }
        }
        .opacity(iconOpacity)
        .frame(width: OpenSnekBranding.menuBarIconSide, height: OpenSnekBranding.menuBarIconSide)
    }
}
