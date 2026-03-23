import AppKit
import OpenSnekCore
import SwiftUI

struct BatteryIconPresentation: Equatable {
    let symbolName: String
    let variableValue: Double
}

enum BatteryPresentation {
    static func icon(percent: Int, charging: Bool?) -> BatteryIconPresentation {
        let clampedPercent = max(0, min(100, percent))
        return BatteryIconPresentation(
            symbolName: charging == true ? "battery.100percent.bolt" : "battery.100percent",
            variableValue: Double(clampedPercent) / 100.0
        )
    }
}

enum ServiceMenuBarPresentation {
    static func batteryIcon(percent: Int, charging: Bool?) -> BatteryIconPresentation {
        BatteryPresentation.icon(percent: percent, charging: charging)
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
                    charging: deviceStore.state?.charging
                )
                HStack(spacing: 4) {
                    Image(
                        systemName: batteryIcon.symbolName,
                        variableValue: batteryIcon.variableValue
                    )
                    Text("\(battery)%")
                }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var stagePicker: some View {
        HStack(spacing: 8) {
            ForEach(0..<max(1, editorStore.editableStageCount), id: \.self) { index in
                let stage = index + 1
                let stageValue = editorStore.stageValue(index)
                let isSelected = editorStore.editableActiveStage == stage
                Button {
                    if !isSelected {
                        editorStore.editableActiveStage = stage
                        editorStore.scheduleAutoApplyActiveStage()
                    }
                } label: {
                    Text("\(stageValue)")
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
        let sliderRange = DeviceProfiles.sliderDpiRange(for: editorStore.selectedDeviceProfileID)
        let sliderDoubleRange = Double(sliderRange.lowerBound)...Double(sliderRange.upperBound)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stage \(editorStore.editableActiveStage) DPI")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Text("\(editorStore.compactActiveStageValue)")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(min(editorStore.compactActiveStageValue, sliderRange.upperBound)) },
                    set: { newValue in
                        let quantized = Int(round(newValue / 100.0) * 100.0)
                        editorStore.updateStage(editorStore.compactActiveStageIndex, value: quantized)
                        editorStore.scheduleAutoApplyDpi()
                    }
                ),
                in: sliderDoubleRange,
                onEditingChanged: { editing in
                    editorStore.isEditingDpiControl = editing
                }
            )
        }
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
            if runtimeStore.isServiceProcess {
                serviceLabel
            } else {
                // Workaround: MenuBarExtra(isInserted: .constant(false)) still
                // creates a visible NSStatusItem on some macOS versions (see
                // FB10185325, orchetect/MenuBarExtraAccess#1). Suppress it.
                SpuriousStatusItemSuppressor()
            }
        }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var serviceLabel: some View {
        Group {
            if let transientDpi = runtimeStore.statusItemTransientDpi {
                ServiceMenuBarStatusDpiBadge(dpi: transientDpi)
                    .frame(width: OpenSnekBranding.menuBarIconSide, height: OpenSnekBranding.menuBarIconSide)
            } else {
                ServiceMenuBarStatusGlyph(isConnected: deviceStore.selectedDevice != nil)
                    .frame(width: OpenSnekBranding.menuBarIconSide, height: OpenSnekBranding.menuBarIconSide)
                    .fixedSize()
            }
        }
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

/// Hides the status-item window that SwiftUI's MenuBarExtra erroneously
/// creates when `isInserted` is `.constant(false)` on some macOS versions.
///
/// This is a known class of SwiftUI MenuBarExtra bugs: the scene machinery
/// eagerly instantiates the underlying NSStatusItem regardless of the
/// `isInserted` binding value. Related reports include FB10185325 (MenuBarExtra
/// needs a non-presenting style) and orchetect/MenuBarExtraAccess discussions
/// #1 and #10 which document phantom status items and inverted state. No
/// first-party fix exists as of macOS 15.
///
/// When the label view is rendered inside the spurious status item, this
/// NSViewRepresentable walks up the view hierarchy to the containing
/// NSStatusBarButton and hides its window, making the item invisible.
/// If the status item is never created (bug doesn't manifest), this view
/// is never rendered — so it's a no-op in that case.
private struct SpuriousStatusItemSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SuppressorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class SuppressorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            suppress()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            guard newWindow != nil else { return }
            suppress()
        }

        private func suppress() {
            var current: NSView? = self
            while let view = current {
                if view is NSStatusBarButton {
                    view.window?.orderOut(nil)
                    view.isHidden = true
                    return
                }
                current = view.superview
            }
        }
    }
}

private struct ServiceMenuBarStatusGlyph: View {
    let isConnected: Bool

    private var iconOpacity: Double {
        isConnected ? 0.88 : 0.46
    }

    var body: some View {
        Group {
            if let menuIcon = OpenSnekBranding.menuIcon {
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
