import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var appState: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .task { await appState.refreshDevices() }
        .onChange(of: appState.selectedDeviceID) { _, _ in
            Task { await appState.refreshState() }
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            Task { await appState.refreshState() }
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            Task { await appState.refreshDpiFast() }
        }
    }

    private var sidebar: some View {
        ZStack {
            AngularGradient(
                gradient: Gradient(colors: [Color(hex: 0x102532), Color(hex: 0x223319), Color(hex: 0x332114), Color(hex: 0x102532)]),
                center: .topLeading
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: 0xA8F46A))
                    Text("OpenSnek")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        Task { await appState.refreshDevices() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: 0x9BEA5D))
                    .controlSize(.small)
                }

                Text("Devices")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .textCase(.uppercase)

                List(selection: $appState.selectedDeviceID) {
                    ForEach(appState.devices) { device in
                        DeviceRow(device: device)
                            .tag(device.id)
                            .listRowBackground(Color.clear)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .padding(12)
        }
        .frame(minWidth: 220)
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
                ScrollView {
                    VStack(spacing: 16) {
                        header(for: selected, state: state)
                        statsGrid(state: state)
                        controls(state: state)
                    }
                    .padding(18)
                }
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
        .overlay(alignment: .top) {
            if let error = appState.errorMessage {
                Text(error)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(hex: 0xB3261E), in: Capsule())
                    .padding(.top, 10)
            }
        }
    }

    private func header(for device: MouseDevice, state: MouseState) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(device.product_name)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                HStack(spacing: 10) {
                    Pill(text: state.connection, color: state.connection == "Bluetooth" ? Color(hex: 0x66D9FF) : Color(hex: 0xA8F46A))
                    if let fw = state.device.firmware {
                        Pill(text: "FW \(fw)", color: Color(hex: 0xE7B566))
                    }
                }
                if let serial = state.device.serial {
                    Text("Serial \(serial)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                if let battery = state.battery_percent {
                    Label("\(battery)%", systemImage: state.charging == true ? "battery.100percent.bolt" : "battery.75")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
                if let updated = appState.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.18), lineWidth: 1))
        )
    }

    private func statsGrid(state: MouseState) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatCard(title: "DPI", value: state.dpi.map { "\($0.x) x \($0.y)" } ?? "unavailable")
            StatCard(title: "Poll", value: state.poll_rate.map { "\($0) Hz" } ?? "unavailable")
            StatCard(title: "Stage", value: state.dpi_stages.active_stage.map { "\($0 + 1)" } ?? "unavailable")
            StatCard(title: "Lighting", value: state.led_value.map { "\($0) / 255" } ?? "unavailable")
        }
    }

    private func controls(state: MouseState) -> some View {
        VStack(spacing: 14) {
            if state.capabilities.dpi_stages { dpiCard() }
            if state.capabilities.poll_rate { pollCard() }
            if state.capabilities.lighting { lightingCard(state: state) }
            if state.capabilities.button_remap { buttonCard(state: state) }
        }
    }

    private func dpiCard() -> some View {
        Card(title: "DPI Stages") {
            Picker("Mode", selection: $appState.singleStageMode) {
                Text("Single Stage").tag(true)
                Text("Multiple Stages").tag(false)
            }
            .pickerStyle(.segmented)
            .onChange(of: appState.singleStageMode) { _, single in
                if single {
                    appState.editableStageCount = 1
                    appState.editableActiveStage = 1
                } else {
                    appState.editableStageCount = max(2, appState.editableStageCount)
                }
                appState.scheduleAutoApplyDpi()
            }

            if !appState.singleStageMode {
                Stepper("Enabled stages: \(appState.editableStageCount)", value: $appState.editableStageCount, in: 2...5)
                    .onChange(of: appState.editableStageCount) { _, _ in
                        appState.editableActiveStage = min(appState.editableActiveStage, appState.editableStageCount)
                        appState.scheduleAutoApplyDpi()
                    }

                Stepper("Active stage: \(appState.editableActiveStage)", value: $appState.editableActiveStage, in: 1...appState.editableStageCount)
                    .onChange(of: appState.editableActiveStage) { _, _ in appState.scheduleAutoApplyActiveStage() }
            }

            ForEach(0..<(appState.singleStageMode ? 1 : appState.editableStageCount), id: \.self) { idx in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(appState.singleStageMode ? "DPI" : "Stage \(idx + 1)")
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
                        .frame(width: 90)
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
                        step: 100
                    )
                }
            }
            Text("Auto-apply enabled")
                .hintText()
        }
    }

    private func pollCard() -> some View {
        Card(title: "Polling Rate") {
            Picker("Rate", selection: $appState.editablePollRate) {
                Text("125 Hz").tag(125)
                Text("500 Hz").tag(500)
                Text("1000 Hz").tag(1000)
            }
            .pickerStyle(.segmented)
            Text("Auto-apply enabled")
                .hintText()
        }
        .onChange(of: appState.editablePollRate) { _, _ in appState.scheduleAutoApplyPollRate() }
    }

    private func lightingCard(state: MouseState) -> some View {
        Card(title: state.connection == "Bluetooth" ? "Lighting (Vendor BLE)" : "Lighting") {
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(appState.editableLedBrightness) },
                        set: { appState.editableLedBrightness = Int($0) }
                    ),
                    in: 0...255,
                    step: 1
                )
                Text("\(appState.editableLedBrightness)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }

            if state.connection == "Bluetooth" {
                HStack(spacing: 12) {
                    ColorPicker(
                        "LED Color",
                        selection: Binding(
                            get: {
                                Color(
                                    red: Double(appState.editableColor.r) / 255.0,
                                    green: Double(appState.editableColor.g) / 255.0,
                                    blue: Double(appState.editableColor.b) / 255.0
                                )
                            },
                            set: { color in
                                let ns = NSColor(color)
                                let rgb = ns.usingColorSpace(.sRGB) ?? ns
                                appState.editableColor.r = Int(round(rgb.redComponent * 255))
                                appState.editableColor.g = Int(round(rgb.greenComponent * 255))
                                appState.editableColor.b = Int(round(rgb.blueComponent * 255))
                            }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    Text(
                        String(
                            format: "#%02X%02X%02X",
                            appState.editableColor.r,
                            appState.editableColor.g,
                            appState.editableColor.b
                        )
                    )
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
            Text("Auto-apply enabled")
                .hintText()
        }
        .onChange(of: appState.editableLedBrightness) { _, _ in appState.scheduleAutoApplyLedBrightness() }
        .onChange(of: appState.editableColor.r) { _, _ in appState.scheduleAutoApplyLedColor() }
        .onChange(of: appState.editableColor.g) { _, _ in appState.scheduleAutoApplyLedColor() }
        .onChange(of: appState.editableColor.b) { _, _ in appState.scheduleAutoApplyLedColor() }
    }

    private func buttonCard(state: MouseState) -> some View {
        Card(title: state.connection == "Bluetooth" ? "Button Remap (Broad)" : "Button Remap") {
            Stepper("Slot \(appState.editableButtonSlot)", value: $appState.editableButtonSlot, in: 1...12)
            Picker("Action", selection: $appState.editableButtonKind) {
                ForEach(ButtonBindingKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.menu)

            if appState.editableButtonKind == .keyboardSimple {
                Stepper("HID Key \(appState.editableHidKey)", value: $appState.editableHidKey, in: 4...231)
            }

            Text("Auto-apply enabled")
                .hintText()
        }
        .onChange(of: appState.editableButtonSlot) { _, _ in appState.scheduleAutoApplyButton() }
        .onChange(of: appState.editableButtonKind) { _, _ in appState.scheduleAutoApplyButton() }
        .onChange(of: appState.editableHidKey) { _, _ in appState.scheduleAutoApplyButton() }
    }
}

private struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.78))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color, in: Capsule())
    }
}

struct DeviceRow: View {
    let device: MouseDevice

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.product_name)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(device.connectionLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Text(device.transport == "bluetooth" ? "BT" : "USB")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(Color(hex: 0x101010))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(device.transport == "bluetooth" ? Color(hex: 0x66D9FF) : Color(hex: 0x9BEA5D), in: Capsule())
        }
        .padding(.vertical, 2)
    }
}

struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15), lineWidth: 1))
        )
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.18), lineWidth: 1))
        )
    }
}

private extension Text {
    func hintText() -> some View {
        font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.58))
    }
}

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
