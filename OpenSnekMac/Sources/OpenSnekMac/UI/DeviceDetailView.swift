import SwiftUI

struct DeviceDetailView: View {
    @Bindable var appState: AppState
    let selected: MouseDevice
    let state: MouseState

    private let swatches: [Color] = [
        Color(hex: 0xFF3B30), Color(hex: 0xFF9500), Color(hex: 0xFFCC00), Color(hex: 0x34C759),
        Color(hex: 0x00C7BE), Color(hex: 0x0A84FF), Color(hex: 0xBF5AF2), Color(hex: 0xFFFFFF),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DeviceOverviewBar(appState: appState, selected: selected, state: state)

                VStack(spacing: 14) {
                    if state.capabilities.dpi_stages {
                        DpiStagesCard(appState: appState)
                    }
                    if state.capabilities.lighting {
                        LightingCard(appState: appState, state: state, swatches: swatches)
                    }
                    if state.capabilities.poll_rate {
                        PollRateCard(appState: appState)
                    }
                    if state.capabilities.power_management {
                        SleepTimeoutCard(appState: appState)
                    }
                    if state.capabilities.button_remap {
                        ButtonMappingTableCard(
                            appState: appState,
                            title: state.connection == "Bluetooth" ? "Button Remap (Broad)" : "Button Remap"
                        )
                    }
                }
            }
            .frame(maxWidth: 1020, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct DeviceOverviewBar: View {
    @Bindable var appState: AppState
    let selected: MouseDevice
    let state: MouseState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.product_name)
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    if let serial = state.device.serial {
                        Text("Serial \(serial)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    if let dpi = state.dpi {
                        Text("DPI \(dpi.x)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.76))
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    if let battery = state.battery_percent {
                        Label(
                            "\(battery)%",
                            systemImage: state.charging == true ? "battery.100percent.bolt" : "battery.75"
                        )
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    }

                    if let updated = appState.lastUpdated {
                        Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }

            HStack(spacing: 10) {
                Pill(
                    text: state.connection,
                    color: state.connection == "Bluetooth" ? Color(hex: 0x66D9FF) : Color(hex: 0xA8F46A)
                )
                if let fw = state.device.firmware {
                    Pill(text: "FW \(fw)", color: Color(hex: 0xE7B566))
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
        }
    }
}

struct LightingCard: View {
    @Bindable var appState: AppState
    let state: MouseState
    let swatches: [Color]

    private var accentBase: Color {
        Color(rgb: appState.editableColor)
    }

    private var accentOpacity: Double {
        let brightness = Double(max(0, min(255, appState.editableLedBrightness))) / 255.0
        return 0.10 + (brightness * 0.22)
    }

    var body: some View {
        Card(title: "Lighting") {
            HStack {
                Text("Brightness")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Text("\(appState.editableLedBrightness)")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
            }

            Slider(
                value: Binding(
                    get: { Double(appState.editableLedBrightness) },
                    set: { newValue in
                        appState.editableLedBrightness = Int(newValue)
                        appState.scheduleAutoApplyLedBrightness()
                    }
                ),
                in: 0...255,
                step: 1
            )
            .tint(accentBase)
            .scaleEffect(y: 1.9, anchor: .center)
            .padding(.vertical, 8)

            if state.connection == "Bluetooth" {
                HStack(spacing: 8) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, swatch in
                        ColorSwatchButton(
                            color: swatch,
                            isSelected: RGBColor.fromColor(swatch) == appState.editableColor,
                            action: {
                                appState.editableColor = RGBColor.fromColor(swatch)
                                appState.scheduleAutoApplyLedColor()
                            }
                        )
                    }
                }

                RGBSliderRow(
                    label: "R",
                    tint: Color.red,
                    value: Binding(
                        get: { appState.editableColor.r },
                        set: {
                            appState.editableColor.r = max(0, min(255, $0))
                            appState.scheduleAutoApplyLedColor()
                        }
                    )
                )

                RGBSliderRow(
                    label: "G",
                    tint: Color.green,
                    value: Binding(
                        get: { appState.editableColor.g },
                        set: {
                            appState.editableColor.g = max(0, min(255, $0))
                            appState.scheduleAutoApplyLedColor()
                        }
                    )
                )

                RGBSliderRow(
                    label: "B",
                    tint: Color.blue,
                    value: Binding(
                        get: { appState.editableColor.b },
                        set: {
                            appState.editableColor.b = max(0, min(255, $0))
                            appState.scheduleAutoApplyLedColor()
                        }
                    )
                )

                Text(
                    String(
                        format: "#%02X%02X%02X",
                        appState.editableColor.r,
                        appState.editableColor.g,
                        appState.editableColor.b
                    )
                )
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [
                            accentBase.opacity(accentOpacity),
                            Color.white.opacity(0.05),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }
}

struct RGBSliderRow: View {
    let label: String
    let tint: Color
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 16, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0) }
                ),
                in: 0...255,
                step: 1
            )
            .tint(tint)
            Text("\(value)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 34, alignment: .trailing)
        }
    }
}

struct DpiStagesCard: View {
    @Bindable var appState: AppState

    var body: some View {
        Card(title: "DPI Stages") {
            HStack {
                Text("Enabled stages: \(appState.editableStageCount)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        let next = max(1, appState.editableStageCount - 1)
                        guard next != appState.editableStageCount else { return }
                        appState.editableStageCount = next
                        appState.editableActiveStage = min(appState.editableActiveStage, appState.editableStageCount)
                        appState.scheduleAutoApplyDpi()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appState.editableStageCount > 1 ? .white : .white.opacity(0.35))
                    .disabled(appState.editableStageCount <= 1)

                    Button {
                        let next = min(5, appState.editableStageCount + 1)
                        guard next != appState.editableStageCount else { return }
                        appState.editableStageCount = next
                        appState.scheduleAutoApplyDpi()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appState.editableStageCount < 5 ? .white : .white.opacity(0.35))
                    .disabled(appState.editableStageCount >= 5)
                }
            }

            ForEach(0..<appState.editableStageCount, id: \.self) { idx in
                let stageColor = stageAccent(for: idx)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if appState.editableStageCount == 1 {
                            Text("DPI")
                                .foregroundStyle(.white)
                        } else {
                            Button {
                                let selected = idx + 1
                                if appState.editableActiveStage != selected {
                                    appState.editableActiveStage = selected
                                    appState.scheduleAutoApplyActiveStage()
                                }
                            } label: {
                                Label(
                                    "Stage \(idx + 1)",
                                    systemImage: appState.editableActiveStage == (idx + 1) ? "checkmark.square.fill" : "square"
                                )
                                .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                        }

                        Spacer()

                        TextField(
                            "DPI",
                            text: Binding(
                                get: { String(appState.stageValue(idx)) },
                                set: { newValue in
                                    if let parsed = Int(newValue) {
                                        appState.updateStage(idx, value: parsed)
                                        appState.scheduleAutoApplyDpi()
                                    }
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(appState.stageValue(idx)) },
                            set: { newValue in
                                appState.updateStage(idx, value: Int(newValue))
                                appState.scheduleAutoApplyDpi()
                            }
                        ),
                        in: 100...30000,
                        step: 100,
                        onEditingChanged: { editing in
                            appState.isEditingDpiControl = editing
                        }
                    )
                    .tint(Color.white.opacity(0.85))
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(stageColor.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(stageColor.opacity(0.35), lineWidth: 1)
                        )
                )
            }
        }
    }

    private func stageAccent(for index: Int) -> Color {
        switch index {
        case 0: return Color(hex: 0xFF3B30) // Red
        case 1: return Color(hex: 0x34C759) // Green
        case 2: return Color(hex: 0x0A84FF) // Blue
        case 3: return Color(hex: 0x00C7BE) // Teal
        default: return Color(hex: 0xFFD60A) // Yellow
        }
    }
}

struct PollRateCard: View {
    @Bindable var appState: AppState

    var body: some View {
        Card(title: "Polling Rate") {
            Picker("Rate", selection: $appState.editablePollRate) {
                Text("125 Hz").tag(125)
                Text("500 Hz").tag(500)
                Text("1000 Hz").tag(1000)
            }
            .pickerStyle(.segmented)
        }
        .onChange(of: appState.editablePollRate) { _, _ in
            appState.scheduleAutoApplyPollRate()
        }
    }
}

struct SleepTimeoutCard: View {
    @Bindable var appState: AppState

    var body: some View {
        Card(title: "Power Management") {
            HStack {
                Text("Sleep timeout")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(formatTimeout(appState.editableSleepTimeout))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }

            Slider(
                value: Binding(
                    get: { Double(appState.editableSleepTimeout) },
                    set: { newValue in
                        appState.editableSleepTimeout = Int(newValue)
                        appState.scheduleAutoApplySleepTimeout()
                    }
                ),
                in: 60...900,
                step: 15
            )
        }
    }

    private func formatTimeout(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let mins = clamped / 60
        let secs = clamped % 60
        return "\(mins)m \(String(format: "%02d", secs))s"
    }
}

struct ButtonMappingTableCard: View {
    @Bindable var appState: AppState
    let title: String

    var body: some View {
        Card(title: title) {
            ForEach(appState.buttonSlots) { slot in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("\(slot.slot). \(slot.friendlyName)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Spacer(minLength: 12)

                        Picker(
                            "",
                            selection: Binding(
                                get: { appState.buttonBindingKind(for: slot.slot) },
                                set: { appState.updateButtonBindingKind(slot: slot.slot, kind: $0) }
                            )
                        ) {
                            ForEach(ButtonBindingKind.allCases) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220, alignment: .trailing)
                    }

                    if appState.buttonBindingKind(for: slot.slot) == .keyboardSimple {
                        HStack {
                            Spacer()
                            Stepper(
                                "Keyboard HID \(appState.buttonBindingHidKey(for: slot.slot))",
                                value: Binding(
                                    get: { appState.buttonBindingHidKey(for: slot.slot) },
                                    set: { appState.updateButtonBindingHidKey(slot: slot.slot, hidKey: $0) }
                                ),
                                in: 4...231
                            )
                            .frame(width: 300, alignment: .trailing)
                        }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
            }
        }
    }
}
