import AppKit
import SwiftUI

enum ServiceMenuBarPresentation {
    static func batterySymbolName(percent: Int, charging: Bool?) -> String {
        if charging == true {
            return "battery.100percent.bolt"
        }

        switch percent {
        case ..<13:
            return "battery.0"
        case ..<38:
            return "battery.25"
        case ..<63:
            return "battery.50"
        case ..<88:
            return "battery.75"
        default:
            return "battery.100percent"
        }
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
    @Bindable var appState: AppState

    private var showsDeviceControls: Bool {
        appState.selectedDevice != nil && appState.state != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusRow
            if showsDeviceControls {
                stagePicker
                dpiSlider
                if let message = appState.compactStatusMessage {
                    Text(message)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Connect a supported mouse to edit DPI from the menu bar.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Divider()
            actionRow("Show Open Snek", systemImage: "rectangle.on.rectangle") {
                appState.openFullAppFromService()
            }
            actionRow("Settings…", systemImage: "gearshape") {
                appState.openSettingsFromService()
            }
            actionRow("Quit", systemImage: "power") {
                appState.terminateServiceProcess()
            }
        }
        .padding(16)
        .frame(width: 320)
        .task {
            await appState.start()
        }
        .onAppear {
            appState.setCompactMenuPresented(true)
        }
        .onDisappear {
            appState.setCompactMenuPresented(false)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(appState.selectedDevice?.product_name ?? "No device connected")
                .font(.system(size: 15, weight: .black, design: .rounded))
            Text(appState.selectedDevice?.connectionLabel ?? "Waiting for a supported mouse")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Label(appState.currentDeviceStatusIndicator.label, systemImage: "circle.fill")
                .foregroundStyle(appState.currentDeviceStatusIndicator.color)
                .font(.system(size: 11, weight: .bold, design: .rounded))

            Spacer()

            if let battery = appState.state?.battery_percent {
                HStack(spacing: 4) {
                    Image(
                        systemName: ServiceMenuBarPresentation.batterySymbolName(
                            percent: battery,
                            charging: appState.state?.charging
                        )
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
            ForEach(0..<max(1, appState.editableStageCount), id: \.self) { index in
                let stage = index + 1
                let isSelected = appState.editableActiveStage == stage
                Button {
                    if !isSelected {
                        appState.editableActiveStage = stage
                        appState.scheduleAutoApplyActiveStage()
                    }
                } label: {
                    Text("\(stage)")
                        .font(.system(size: 11, weight: .black, design: .rounded))
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

    private var dpiSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stage \(appState.editableActiveStage) DPI")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Text("\(appState.compactActiveStageValue)")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(appState.compactActiveStageValue) },
                    set: { newValue in
                        let quantized = Int(round(newValue / 100.0) * 100.0)
                        appState.updateStage(appState.compactActiveStageIndex, value: quantized)
                        appState.scheduleAutoApplyDpi()
                    }
                ),
                in: 100...30000,
                onEditingChanged: { editing in
                    appState.isEditingDpiControl = editing
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
            .padding(.vertical, 8)
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
}

struct ServiceMenuBarStatusItemLabel: View {
    @Bindable var appState: AppState

    private var currentDpi: Int? {
        guard appState.state != nil else { return nil }

        if let liveDpi = appState.state?.dpi?.x, liveDpi > 0 {
            return liveDpi
        }

        let fallback = appState.compactActiveStageValue
        return fallback > 0 ? fallback : nil
    }

    var body: some View {
        ServiceMenuBarStatusGlyph(isConnected: appState.selectedDevice != nil)
            .frame(width: OpenSnekBranding.menuBarIconSide, height: OpenSnekBranding.menuBarIconSide)
            .fixedSize()
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        if let device = appState.selectedDevice, let currentDpi {
            return "\(device.product_name), \(currentDpi) DPI"
        }
        if let device = appState.selectedDevice {
            return device.product_name
        }
        return "Open Snek"
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
