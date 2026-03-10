import SwiftUI
import OpenSnekCore

struct DeviceDetailView: View {
    @Bindable var appState: AppState
    let selected: MouseDevice
    let state: MouseState
    private let cardSpacing: CGFloat = 14
    private let detailTwoColumnMinWidth: CGFloat = 360
    private let twoColumnBreakpointPadding: CGFloat = 100
    private let detailCardMaxWidth: CGFloat = 560
    private let detailContentMaxWidth: CGFloat = 1400
    private let horizontalPadding: CGFloat = 20
    private let verticalPadding: CGFloat = 18

    private let swatches: [LightingSwatch] = [
        LightingSwatch(hex: 0xFF3B30), LightingSwatch(hex: 0xFF9500), LightingSwatch(hex: 0xFFCC00), LightingSwatch(hex: 0x34C759),
        LightingSwatch(hex: 0x00C7BE), LightingSwatch(hex: 0x0A84FF), LightingSwatch(hex: 0xBF5AF2), LightingSwatch(hex: 0xFFFFFF),
    ]

    var body: some View {
        GeometryReader { proxy in
            let sections = detailSections
            let contentWidth = detailContentWidth(for: proxy.size.width)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    DeviceOverviewBar(appState: appState, selected: selected, state: state)
                    DetailColumnsLayout(
                        minTwoColumnCardWidth: detailTwoColumnMinWidth,
                        twoColumnBreakpointPadding: twoColumnBreakpointPadding,
                        spacing: cardSpacing,
                        maxCardWidth: detailCardMaxWidth
                    ) {
                        ForEach(sections, id: \.self) { section in
                            detailCard(for: section)
                                .layoutValue(key: PreferredDetailColumnLayoutKey.self, value: preferredColumn(for: section))
                                .layoutValue(key: DetailCardMaxWidthLayoutKey.self, value: section == .buttonRemap ? detailContentMaxWidth : detailCardMaxWidth)
                        }
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(WindowDragBlocker())
        }
    }

    private var detailSections: [DetailSection] {
        var sections: [DetailSection] = []
        if state.capabilities.dpi_stages {
            sections.append(.dpiStages)
        }
        if state.capabilities.lighting {
            sections.append(.lighting)
        }
        if state.capabilities.power_management {
            sections.append(.powerManagement)
        }
        if selected.transport != .bluetooth, state.capabilities.poll_rate {
            sections.append(.pollRate)
        }
        if selected.transport != .bluetooth, state.low_battery_threshold_raw != nil {
            sections.append(.lowBatteryThreshold)
        }
        if selected.transport != .bluetooth,
           state.scroll_mode != nil || state.scroll_acceleration != nil || state.scroll_smart_reel != nil {
            sections.append(.scrollControls)
        }
        if state.capabilities.button_remap {
            sections.append(.buttonRemap)
        }
        return sections
    }

    private func twoColumnActivationWidth() -> CGFloat {
        (detailTwoColumnMinWidth * 2) + cardSpacing + twoColumnBreakpointPadding
    }

    @ViewBuilder
    private func detailCard(for section: DetailSection) -> some View {
        switch section {
        case .dpiStages:
            DpiStagesCard(appState: appState)
        case .lighting:
            LightingCard(appState: appState, selected: selected, swatches: swatches)
        case .pollRate:
            PollRateCard(appState: appState)
        case .powerManagement:
            SleepTimeoutCard(appState: appState)
        case .lowBatteryThreshold:
            LowBatteryThresholdCard(appState: appState)
        case .scrollControls:
            ScrollControlsCard(appState: appState, state: state)
        case .buttonRemap:
            ButtonMappingTableCard(appState: appState, title: "Button Remap")
        }
    }

    private func detailContentWidth(for availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth - (horizontalPadding * 2), 0), detailContentMaxWidth)
    }

    private func preferredColumn(for section: DetailSection) -> Int {
        section == .buttonRemap ? 1 : -1
    }
}

private enum DetailSection: Hashable {
    case dpiStages
    case lighting
    case pollRate
    case powerManagement
    case lowBatteryThreshold
    case scrollControls
    case buttonRemap
}

struct LightingSwatch: Identifiable, Hashable {
    let hex: UInt32
    let color: Color
    let rgb: OpenSnekCore.RGBColor

    init(hex: UInt32) {
        self.hex = hex
        self.color = Color(hex: hex)
        self.rgb = OpenSnekCore.RGBColor(
            r: Int((hex >> 16) & 0xFF),
            g: Int((hex >> 8) & 0xFF),
            b: Int(hex & 0xFF)
        )
    }

    var id: UInt32 { hex }
}

private struct PreferredDetailColumnLayoutKey: LayoutValueKey {
    static let defaultValue = -1
}

private struct DetailCardMaxWidthLayoutKey: LayoutValueKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
}

private struct DetailColumnsLayout: Layout {
    let minTwoColumnCardWidth: CGFloat
    let twoColumnBreakpointPadding: CGFloat
    let spacing: CGFloat
    let maxCardWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(for: proposal, subviews: subviews)
        let width = proposal.width ?? frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(for: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, frame) in frames.enumerated() {
            let placed = CGRect(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY, width: frame.width, height: frame.height)
            subviews[index].place(
                at: placed.origin,
                proposal: ProposedViewSize(width: placed.width, height: placed.height)
            )
        }
    }

    private func frames(for proposal: ProposedViewSize, subviews: Subviews) -> [CGRect] {
        let availableWidth = proposal.width ?? 0
        let useTwoColumns = availableWidth >= ((minTwoColumnCardWidth * 2) + spacing + twoColumnBreakpointPadding)

        if !useTwoColumns {
            return singleColumnFrames(for: availableWidth, subviews: subviews)
        }

        return twoColumnFrames(for: availableWidth, subviews: subviews)
    }

    private func singleColumnFrames(for width: CGFloat, subviews: Subviews) -> [CGRect] {
        let resolvedWidth = max(width, 0)
        var y: CGFloat = 0
        var frames: [CGRect] = []

        for subview in subviews {
            let proposedWidth = resolvedWidth
            let size = subview.sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            let x = (resolvedWidth - proposedWidth) / 2
            frames.append(CGRect(x: x, y: y, width: proposedWidth, height: size.height))
            y += size.height + spacing
        }

        return frames
    }

    private func twoColumnFrames(for width: CGFloat, subviews: Subviews) -> [CGRect] {
        let totalWidth = max(width, 0)
        let nominalColumnWidth = min(maxCardWidth, floor((totalWidth - spacing) / 2))
        let contentWidth = (nominalColumnWidth * 2) + spacing
        let originX = max((totalWidth - contentWidth) / 2, 0)
        var columnHeights: [CGFloat] = [0, 0]
        var balancedColumn = 0
        var frames: [CGRect] = Array(repeating: .zero, count: subviews.count)

        for (index, subview) in subviews.enumerated() {
            let preferredColumn = subview[PreferredDetailColumnLayoutKey.self]
            let column = preferredColumn == 0 || preferredColumn == 1 ? preferredColumn : balancedColumn
            if preferredColumn != 0 && preferredColumn != 1 {
                balancedColumn = (balancedColumn + 1) % 2
            }

            let cardMaxWidth = min(subview[DetailCardMaxWidthLayoutKey.self], nominalColumnWidth)
            let proposedWidth = min(nominalColumnWidth, cardMaxWidth)
            let size = subview.sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            let x = originX + CGFloat(column) * (nominalColumnWidth + spacing) + ((nominalColumnWidth - proposedWidth) / 2)
            let y = columnHeights[column]
            frames[index] = CGRect(x: x, y: y, width: proposedWidth, height: size.height)
            columnHeights[column] += size.height + spacing
        }

        return frames
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
                }
            }

            HStack(spacing: 10) {
                Pill(
                    text: state.connection,
                    color: selected.transport == .bluetooth ? Color(hex: 0x66D9FF) : Color(hex: 0xA8F46A)
                )
                DeviceStatusBadge(indicator: appState.currentDeviceStatusIndicator)
            }

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
        }
    }
}

struct DeviceStatusBadge: View {
    let indicator: DeviceStatusIndicator

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicator.color)
                .frame(width: 9, height: 9)
                .shadow(color: indicator.color.opacity(0.45), radius: 6, y: 0)

            Text(indicator.label)
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }
}

struct LightingCard: View {
    @Bindable var appState: AppState
    let selected: MouseDevice
    let swatches: [LightingSwatch]

    private var accentBase: Color {
        Color(rgb: appState.editableColor)
    }

    private var accentOpacity: Double {
        let brightness = Double(max(0, min(255, appState.editableLedBrightness))) / 255.0
        return 0.10 + (brightness * 0.22)
    }

    private var zoneGradientColors: [Color] {
        guard selected.transport == .usb,
              appState.editableLightingEffect == .staticColor,
              appState.visibleUSBLightingZones.count > 1,
              appState.editableUSBLightingZoneID != "all"
        else {
            return [
                accentBase.opacity(accentOpacity),
                Color.white.opacity(0.05),
            ]
        }

        let zonePalette: [String: Color] = [
            "scroll_wheel": Color(hex: 0x61D9FF),
            "logo": Color(hex: 0x7FF2A5),
            "underglow": Color(hex: 0xFFD36B),
        ]
        let zones = appState.visibleUSBLightingZones.filter { $0.id == appState.editableUSBLightingZoneID }

        let overlayOpacity = max(0.10, accentOpacity * 0.9)
        let zoneColors = zones.map { zone in
            (zonePalette[zone.id] ?? accentBase)
                .opacity(0.16)
        }

        return [accentBase.opacity(overlayOpacity)] + zoneColors + [Color.white.opacity(0.05)]
    }

    private var brightnessPercent: Int {
        Int(round((Double(max(0, min(255, appState.editableLedBrightness))) / 255.0) * 100.0))
    }

    var body: some View {
        Card(title: "Lighting") {
            HStack {
                Text("Brightness")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Text("\(brightnessPercent)%")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
            }

            Slider(
                value: Binding(
                    get: { (Double(max(0, min(255, appState.editableLedBrightness))) / 255.0) * 100.0 },
                    set: { newValue in
                        let percent = max(0.0, min(100.0, newValue))
                        appState.editableLedBrightness = Int(round((percent / 100.0) * 255.0))
                        appState.scheduleAutoApplyLedBrightness()
                    }
                ),
                in: 0...100
            )
            .tint(accentBase)
            .padding(.vertical, 8)

            if !selected.supports_advanced_lighting_effects {
                LightingColorEditor(
                    title: "Color",
                    color: Binding(
                        get: { appState.editableColor },
                        set: {
                            appState.editableColor = $0
                            appState.scheduleAutoApplyLedColor()
                        }
                    ),
                    swatches: swatches
                )
            } else {
                HStack {
                    Text("Profile")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                    Spacer()
                    Picker(
                        "",
                        selection: Binding(
                            get: { appState.editableLightingEffect },
                            set: {
                                appState.updateLightingEffect($0)
                                appState.scheduleAutoApplyLightingEffect()
                            }
                        )
                    ) {
                        ForEach(appState.visibleLightingEffects) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .trailing)
                }

                if appState.editableLightingEffect.usesWaveDirection {
                    HStack {
                        Text("Direction")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                        Spacer()
                        Picker(
                            "Direction",
                            selection: Binding(
                                get: { appState.editableLightingWaveDirection },
                                set: {
                                    appState.updateLightingWaveDirection($0)
                                    appState.scheduleAutoApplyLightingEffect()
                                }
                            )
                        ) {
                            Text("Left").tag(LightingWaveDirection.left)
                            Text("Right").tag(LightingWaveDirection.right)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                }

                if appState.editableLightingEffect.usesReactiveSpeed {
                    HStack {
                        Text("Speed")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                        Spacer()
                        Picker(
                            "Speed",
                            selection: Binding(
                                get: { appState.editableLightingReactiveSpeed },
                                set: {
                                    appState.updateLightingReactiveSpeed($0)
                                    appState.scheduleAutoApplyLightingEffect()
                                }
                            )
                        ) {
                            Text("1").tag(1)
                            Text("2").tag(2)
                            Text("3").tag(3)
                            Text("4").tag(4)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                }

                if appState.editableLightingEffect.usesPrimaryColor {
                    if selected.transport == .usb,
                       appState.editableLightingEffect == .staticColor,
                       appState.visibleUSBLightingZones.count > 1 {
                        HStack {
                            Text("Static Zone")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.82))
                            Spacer()
                            Picker(
                                "",
                                selection: Binding(
                                    get: { appState.editableUSBLightingZoneID },
                                    set: {
                                        appState.updateUSBLightingZoneID($0)
                                        appState.scheduleAutoApplyLightingEffect()
                                    }
                                )
                            ) {
                                Text("All Zones").tag("all")
                                ForEach(appState.visibleUSBLightingZones) { zone in
                                    Text(zone.label).tag(zone.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 220, alignment: .trailing)
                        }
                    }

                    LightingColorEditor(
                        title: "Primary Color",
                        color: Binding(
                            get: { appState.editableColor },
                            set: {
                                appState.editableColor = $0
                                appState.scheduleAutoApplyLightingEffect()
                            }
                        ),
                        swatches: swatches
                    )
                }

                if appState.editableLightingEffect.usesSecondaryColor {
                    LightingColorEditor(
                        title: "Secondary Color",
                        color: Binding(
                            get: { appState.editableSecondaryColor },
                            set: {
                                appState.editableSecondaryColor = $0
                                appState.scheduleAutoApplyLightingEffect()
                            }
                        ),
                        swatches: swatches
                    )
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: zoneGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }
}

struct LightingColorEditor: View {
    let title: String
    @Binding var color: OpenSnekCore.RGBColor
    let swatches: [LightingSwatch]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.74))

            HStack(spacing: 8) {
                ForEach(swatches) { swatch in
                    ColorSwatchButton(
                        color: swatch.color,
                        isSelected: swatch.rgb == color,
                        action: { color = swatch.rgb }
                    )
                }
            }

            RGBSliderRow(
                label: "R",
                tint: Color.red,
                value: Binding(
                    get: { color.r },
                    set: { color.r = max(0, min(255, $0)) }
                )
            )

            RGBSliderRow(
                label: "G",
                tint: Color.green,
                value: Binding(
                    get: { color.g },
                    set: { color.g = max(0, min(255, $0)) }
                )
            )

            RGBSliderRow(
                label: "B",
                tint: Color.blue,
                value: Binding(
                    get: { color.b },
                    set: { color.b = max(0, min(255, $0)) }
                )
            )

            Text(String(format: "#%02X%02X%02X", color.r, color.g, color.b))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
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
                    set: { value = Int(round($0)) }
                ),
                in: 0...255
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
        let supportsMultiStage = true
        let stageCount = supportsMultiStage ? appState.editableStageCount : 1
        Card(title: "DPI Stages") {
            HStack {
                Text(supportsMultiStage ? "Enabled stages: \(appState.editableStageCount) / 5" : "Single-stage DPI")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        guard supportsMultiStage else { return }
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
                    .foregroundStyle(supportsMultiStage && appState.editableStageCount > 1 ? .white : .white.opacity(0.35))
                    .disabled(!supportsMultiStage || appState.editableStageCount <= 1)

                    Button {
                        guard supportsMultiStage else { return }
                        let next = min(5, appState.editableStageCount + 1)
                        guard next != appState.editableStageCount else { return }
                        appState.editableStageCount = next
                        appState.scheduleAutoApplyDpi()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(supportsMultiStage && appState.editableStageCount < 5 ? .white : .white.opacity(0.35))
                    .disabled(!supportsMultiStage || appState.editableStageCount >= 5)
                }
            }

            ForEach(0..<stageCount, id: \.self) { idx in
                let isSelectedStage = stageCount == 1 || appState.editableActiveStage == (idx + 1)
                let stageColor = stageAccent(for: idx, isSelected: isSelectedStage)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if stageCount == 1 {
                            Text("DPI")
                                .foregroundStyle(stageColor)
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
                            .foregroundStyle(isSelectedStage ? stageColor : .white)
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
                                let quantized = Int(round(newValue / 100.0) * 100.0)
                                appState.updateStage(idx, value: quantized)
                                appState.scheduleAutoApplyDpi()
                            }
                        ),
                        in: 100...30000,
                        onEditingChanged: { editing in
                            appState.isEditingDpiControl = editing
                        }
                    )
                    .tint(isSelectedStage ? stageColor : Color.white.opacity(0.80))
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelectedStage ? stageColor.opacity(0.24) : stageColor.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelectedStage ? stageColor.opacity(0.95) : stageColor.opacity(0.35), lineWidth: isSelectedStage ? 2 : 1)
                        )
                )
                .shadow(color: isSelectedStage ? stageColor.opacity(0.30) : .clear, radius: 12, y: 0)
            }
        }
    }

    private func stageAccent(for index: Int, isSelected: Bool) -> Color {
        switch index {
        case 0: return Color(hex: isSelected ? 0xFF6B61 : 0xFF3B30) // Red
        case 1: return Color(hex: isSelected ? 0x5BEB7E : 0x34C759) // Green
        case 2: return Color(hex: isSelected ? 0x4FA7FF : 0x0A84FF) // Blue
        case 3: return Color(hex: isSelected ? 0x36F0E8 : 0x00C7BE) // Teal
        default: return Color(hex: isSelected ? 0xFFE35A : 0xFFD60A) // Yellow
        }
    }
}

struct PollRateCard: View {
    @Bindable var appState: AppState

    var body: some View {
        Card(title: "Polling Rate") {
            LabeledControlRow(title: "Rate") {
                Picker("Rate", selection: $appState.editablePollRate) {
                    Text("125 Hz").tag(125)
                    Text("500 Hz").tag(500)
                    Text("1000 Hz").tag(1000)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
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
                        let quantized = Int(round(newValue / 15.0) * 15.0)
                        appState.editableSleepTimeout = max(60, min(900, quantized))
                        appState.scheduleAutoApplySleepTimeout()
                    }
                ),
                in: 60...900
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

struct LowBatteryThresholdCard: View {
    @Bindable var appState: AppState

    var body: some View {
        Card(title: "Low Battery Threshold") {
            HStack {
                Text("Threshold")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                let raw = max(0x0C, min(0x3F, appState.editableLowBatteryThresholdRaw))
                Text("~\(approxPercent(raw))%")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }

            Slider(
                value: Binding(
                    get: { Double(max(0x0C, min(0x3F, appState.editableLowBatteryThresholdRaw))) },
                    set: { newValue in
                        appState.editableLowBatteryThresholdRaw = max(0x0C, min(0x3F, Int(round(newValue))))
                        appState.scheduleAutoApplyLowBatteryThreshold()
                    }
                ),
                in: Double(0x0C)...Double(0x3F)
            )

            Text("Approximate warning level")
                .hintTextStyle()
        }
    }

    private func approxPercent(_ raw: Int) -> Int {
        let clamped = max(0x0C, min(0x3F, raw))
        let ratio = Double(clamped - 0x0C) / Double(0x3F - 0x0C)
        return Int(round(5.0 + (ratio * 20.0)))
    }
}

struct ScrollControlsCard: View {
    @Bindable var appState: AppState
    let state: MouseState

    var body: some View {
        Card(title: "Scroll Controls") {
            VStack(alignment: .leading, spacing: 12) {
                if state.scroll_mode != nil {
                    LabeledControlRow(title: "Wheel") {
                        Picker(
                            "Wheel",
                            selection: Binding(
                                get: { appState.editableScrollMode },
                                set: {
                                    appState.editableScrollMode = ($0 == 1 ? 1 : 0)
                                    appState.scheduleAutoApplyScrollMode()
                                }
                            )
                        ) {
                            Text("Tactile").tag(0)
                            Text("Free Spin").tag(1)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 220, alignment: .trailing)
                    }
                }

                if state.scroll_acceleration != nil {
                    LabeledControlRow(title: "Acceleration") {
                        Toggle(
                            "Acceleration",
                            isOn: Binding(
                                get: { appState.editableScrollAcceleration },
                                set: {
                                    appState.editableScrollAcceleration = $0
                                    appState.scheduleAutoApplyScrollAcceleration()
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                    }
                }

                if state.scroll_smart_reel != nil {
                    LabeledControlRow(title: "Smart Reel") {
                        Toggle(
                            "Smart Reel",
                            isOn: Binding(
                                get: { appState.editableScrollSmartReel },
                                set: {
                                    appState.editableScrollSmartReel = $0
                                    appState.scheduleAutoApplyScrollSmartReel()
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ButtonMappingTableCard: View {
    @Bindable var appState: AppState
    let title: String

    private var rows: [ButtonBindingRowModel] {
        appState.visibleButtonSlots.map { slot in
            let kind = appState.buttonBindingKind(for: slot.slot)
            let turboEnabled = appState.buttonBindingTurboEnabled(for: slot.slot)
            let turboRate = appState.buttonBindingTurboRatePressesPerSecond(for: slot.slot)
            return ButtonBindingRowModel(
                slot: slot.slot,
                friendlyName: slot.friendlyName,
                isEditable: appState.isButtonSlotEditable(slot.slot),
                selectedKind: kind,
                turboEligible: kind != .default && kind.supportsTurbo,
                keyboardDraft: kind == .keyboardSimple ? appState.keyboardTextDraft(for: slot.slot) : "",
                turboEnabled: turboEnabled,
                turboRatePressesPerSecond: turboRate,
                notice: appState.buttonSlotNotice(slot.slot)
            )
        }
    }

    var body: some View {
        Card(title: title) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        ButtonBindingRow(appState: appState, row: row)
                    }
                }

                if !appState.hiddenUnsupportedButtonSlots.isEmpty {
                    UnsupportedButtonsFootnote(entries: appState.hiddenUnsupportedButtonSlots)
                }
            }
        }
    }
}

private struct UnsupportedButtonsFootnote: View {
    let entries: [DocumentedButtonSlot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))
                Text("Some buttons can't be changed yet")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
            }

            Text("Open Snek can still use the rest of the device normally.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.60))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(entries) { entry in
                    Text("\(entry.descriptor.friendlyName): \(entry.note ?? entry.access.defaultNotice ?? "Unsupported")")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

private struct LabeledControlRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))

            Spacer(minLength: 12)

            control()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ButtonBindingRowModel: Identifiable, Equatable {
    let slot: Int
    let friendlyName: String
    let isEditable: Bool
    let selectedKind: ButtonBindingKind
    let turboEligible: Bool
    let keyboardDraft: String
    let turboEnabled: Bool
    let turboRatePressesPerSecond: Int
    let notice: String?

    var id: Int { slot }
}

private struct ButtonBindingRow: View {
    @Bindable var appState: AppState
    let row: ButtonBindingRowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text(row.friendlyName)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer(minLength: 12)

                Picker(
                    "",
                    selection: Binding(
                        get: { appState.buttonBindingKind(for: row.slot) },
                        set: { appState.updateButtonBindingKind(slot: row.slot, kind: $0) }
                    )
                ) {
                    ForEach(ButtonBindingKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220, alignment: .trailing)
                .disabled(!row.isEditable)
            }

            if row.selectedKind == .keyboardSimple {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Text("Key")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                        TextField(
                            "a",
                            text: Binding(
                                get: { appState.keyboardTextDraft(for: row.slot) },
                                set: { appState.updateKeyboardTextDraft(slot: row.slot, text: $0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .multilineTextAlignment(.center)
                        .disabled(!row.isEditable)
                    }
                    .frame(width: 300, alignment: .trailing)
                }

                HStack {
                    Spacer()
                    Text("Type: a-z, 0-9, punctuation, enter, tab, space, esc")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                }
            }

            if row.turboEligible {
                HStack(spacing: 8) {
                    Spacer()
                    Toggle(
                        "Turbo",
                        isOn: Binding(
                            get: { appState.buttonBindingTurboEnabled(for: row.slot) },
                            set: { appState.updateButtonBindingTurboEnabled(slot: row.slot, enabled: $0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
                    .disabled(!row.isEditable)

                    if row.turboEnabled {
                        Text("Slow")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))

                        Slider(
                            value: Binding(
                                get: { Double(appState.buttonBindingTurboRatePressesPerSecond(for: row.slot)) },
                                set: { appState.updateButtonBindingTurboPressesPerSecond(slot: row.slot, pressesPerSecond: Int(round($0))) }
                            ),
                            in: 1...20
                        )
                        .frame(width: 140)
                        .disabled(!row.isEditable)

                        Text("Fast")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))

                        Text("\(row.turboRatePressesPerSecond)/s")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.78))
                            .frame(width: 54, alignment: .trailing)
                    }
                }
                .disabled(!row.isEditable)

                if row.turboEnabled {
                    HStack {
                        Spacer()
                        Text("Turbo rate: 1..20 presses per second")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }
            }

            if let notice = row.notice {
                HStack {
                    Spacer()
                    Text(notice)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                }
            }
        }
        .padding(8)
        .opacity(row.isEditable ? 1.0 : 0.75)
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
