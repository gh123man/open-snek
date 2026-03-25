import AppKit
import OpenSnekAppSupport
import SwiftUI
import OpenSnekCore

struct DeviceDetailView: View {
    let deviceStore: DeviceStore
    let editorStore: EditorStore
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
            let controlsEnabled = deviceStore.selectedDeviceControlsEnabled

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    DeviceOverviewBar(deviceStore: deviceStore, selected: selected, state: state)
                    VStack(alignment: .leading, spacing: 12) {
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
                        .disabled(!controlsEnabled)
                        .opacity(controlsEnabled ? 1.0 : 0.44)
                    }
                    DiagnosticsFooter(deviceStore: deviceStore, device: selected, state: state)
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(WindowDragBlocker())
            .task(id: selected.id) {
                await deviceStore.refreshConnectionDiagnostics(for: selected)
            }
        }
    }

    private var detailSections: [DetailSection] {
        var sections: [DetailSection] = []
        if state.capabilities.dpi_stages {
            sections.append(.dpiStages)
        }
        if selected.showsLightingControls, state.capabilities.lighting {
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

    @ViewBuilder
    private func detailCard(for section: DetailSection) -> some View {
        switch section {
        case .dpiStages:
            DpiStagesCard(editorStore: editorStore)
        case .lighting:
            LightingCard(editorStore: editorStore, selected: selected, swatches: swatches)
        case .pollRate:
            PollRateCard(editorStore: editorStore)
        case .powerManagement:
            SleepTimeoutCard(editorStore: editorStore)
        case .lowBatteryThreshold:
            LowBatteryThresholdCard(editorStore: editorStore)
        case .scrollControls:
            ScrollControlsCard(editorStore: editorStore, state: state)
        case .buttonRemap:
            ButtonMappingTableCard(deviceStore: deviceStore, editorStore: editorStore, title: "Buttons")
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
    let deviceStore: DeviceStore
    let selected: MouseDevice
    let state: MouseState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.product_name)
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    if showsUnsupportedUSBMarker {
                        UnsupportedUSBInlineBanner()
                    }
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
                        let batteryIcon = BatteryPresentation.icon(
                            percent: battery,
                            charging: state.charging
                        )
                        HStack(spacing: 8) {
                            Image(
                                systemName: batteryIcon.symbolName,
                                variableValue: batteryIcon.variableValue
                            )
                            Text("\(battery)%")
                        }
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    }
                }
            }

            HStack(spacing: 10) {
                Pill(
                    text: state.connection,
                    color: selected.transport == .bluetooth ? Color(hex: 0x66D9FF) : Color(hex: 0xA8F46A),
                    helpText: deviceStore.currentDeviceConnectionTooltip
                )
                DeviceStatusBadge(
                    indicator: deviceStore.currentDeviceStatusIndicator,
                    helpText: deviceStore.currentDeviceStatusTooltip
                )
            }

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
        }
        .zIndex(6)
    }

    private var showsUnsupportedUSBMarker: Bool {
        deviceStore.selectedDeviceIsUnsupportedUSB && deviceStore.selectedDeviceID == selected.id
    }
}

struct GenericDeviceDetailView: View {
    let deviceStore: DeviceStore
    let selected: MouseDevice

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                GenericDeviceOverviewBar(deviceStore: deviceStore, selected: selected)

                if resolvedProfile == nil {
                    Card(title: "Limited Support") {
                        Text(primaryMessage)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(secondaryMessage)
                            .hintTextStyle()
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 6) {
                            diagnosticRow(label: "Vendor ID", value: String(format: "0x%04X", selected.vendor_id))
                            diagnosticRow(label: "Product ID", value: String(format: "0x%04X", selected.product_id))
                            diagnosticRow(label: "Location ID", value: String(format: "0x%08X", selected.location_id))
                            diagnosticRow(label: "Transport", value: selected.transport.connectionLabel)
                            diagnosticRow(label: "Resolved profile", value: "None")
                        }
                        .padding(.top, 2)
                    }
                }

                DiagnosticsFooter(deviceStore: deviceStore, device: selected, state: nil)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowDragBlocker())
    }

    private var resolvedProfile: DeviceProfile? {
        DeviceProfiles.resolve(
            vendorID: selected.vendor_id,
            productID: selected.product_id,
            transport: selected.transport
        )
    }

    private var primaryMessage: String {
        "This mouse is not fully supported yet."
    }

    private var secondaryMessage: String {
        "OpenSnek will show the controls it can verify safely. Use Diagnostics in bug reports so unsupported devices are easier to map."
    }

    @ViewBuilder
    private func diagnosticRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DeviceUnavailableDetailView: View {
    let deviceStore: DeviceStore
    let selected: MouseDevice

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                GenericDeviceOverviewBar(deviceStore: deviceStore, selected: selected)

                Card(title: deviceStore.currentDeviceStatusIndicator.label) {
                    Text(deviceStore.selectedDeviceInteractionMessage ?? "Live telemetry is unavailable for this device right now.")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("The controls stay locked until the device reconnects and OpenSnek is receiving live updates again.")
                        .hintTextStyle()
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(deviceStore.diagnosticsConnectionLines(for: selected), id: \.self) { line in
                            Text(line)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                    }
                    .padding(.top, 2)
                }

                DiagnosticsFooter(deviceStore: deviceStore, device: selected, state: nil)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowDragBlocker())
        .task(id: selected.id) {
            await deviceStore.refreshConnectionDiagnostics(for: selected)
        }
    }
}

struct DeviceConnectingDetailView: View {
    let deviceStore: DeviceStore
    let selected: MouseDevice

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                GenericDeviceOverviewBar(deviceStore: deviceStore, selected: selected)

                VStack(spacing: 18) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white.opacity(0.92))

                    VStack(spacing: 8) {
                        Text(headline)
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundStyle(.white)

                        Text(subtitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.68))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 42)
                .background(
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 28)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                )

                DiagnosticsFooter(deviceStore: deviceStore, device: selected, state: nil)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowDragBlocker())
        .task(id: selected.id) {
            await deviceStore.refreshConnectionDiagnostics(for: selected)
        }
    }

    private var headline: String {
        switch selected.transport {
        case .bluetooth:
            "Connecting to \(selected.product_name)"
        case .usb:
            "Loading \(selected.product_name)"
        }
    }

    private var subtitle: String {
        switch selected.transport {
        case .bluetooth:
            "Establishing the Bluetooth control link and reading your settings."
        case .usb:
            "Reading device settings and preparing controls."
        }
    }
}

struct GenericDeviceOverviewBar: View {
    let deviceStore: DeviceStore
    let selected: MouseDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.product_name)
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    if showsUnsupportedUSBMarker {
                        UnsupportedUSBInlineBanner()
                    }
                    if let serial = selected.serial {
                        Text("Serial \(serial)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Pill(
                    text: selected.connectionLabel,
                    color: selected.transport == .bluetooth ? Color(hex: 0x66D9FF) : Color(hex: 0xA8F46A),
                    helpText: deviceStore.currentDeviceConnectionTooltip
                )
                DeviceStatusBadge(
                    indicator: deviceStore.currentDeviceStatusIndicator,
                    helpText: deviceStore.currentDeviceStatusTooltip
                )
            }

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
        }
        .zIndex(6)
    }

    private var showsUnsupportedUSBMarker: Bool {
        deviceStore.selectedDeviceIsUnsupportedUSB && deviceStore.selectedDeviceID == selected.id
    }
}

private struct UnsupportedUSBInlineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("⚠️")
                .font(.system(size: 12))
            Text("Unsupported USB device. Only verified controls are shown.")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(hex: 0xFF9F0A).opacity(0.18))
                .overlay(
                    Capsule()
                        .stroke(Color(hex: 0xFF9F0A).opacity(0.42), lineWidth: 1)
                )
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DiagnosticsFooter: View {
    let deviceStore: DeviceStore
    let device: MouseDevice
    let state: MouseState?

    var body: some View {
        HStack {
            Spacer()
            DeviceDiagnosticsButton(deviceStore: deviceStore, device: device, state: state)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}

struct DeviceStatusBadge: View {
    let indicator: DeviceStatusIndicator
    var helpText: String?

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
        .contentShape(Capsule())
        .hoverTooltip(helpText, xOffset: 6, yOffset: 34, maxWidth: 360)
    }
}

struct DeviceDiagnosticsButton: View {
    let deviceStore: DeviceStore
    let device: MouseDevice
    let state: MouseState?
    @State private var showsDiagnostics = false

    var body: some View {
        Button {
            showsDiagnostics = true
        } label: {
            Label("Diagnostics", systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 11, weight: .black, design: .rounded))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.white.opacity(0.2))
        .sheet(isPresented: $showsDiagnostics) {
            DeviceDiagnosticsSheet(deviceStore: deviceStore, device: device, state: state)
        }
    }
}

struct DeviceDiagnosticsSheet: View {
    let deviceStore: DeviceStore
    let device: MouseDevice
    let state: MouseState?
    @Environment(\.dismiss) private var dismiss

    private var diagnosticsText: String {
        deviceStore.diagnosticsDump(for: device, state: state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device Diagnostics")
                        .font(.system(size: 21, weight: .black, design: .rounded))
                    Text(device.product_name)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Copy") {
                    copyDiagnostics()
                }
                .buttonStyle(.borderedProminent)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            Text("Use this dump in bug reports when a device is unsupported, partially supported, or behaving unexpectedly.")
                .hintTextStyle()

            VStack(alignment: .leading, spacing: 6) {
                Text("Connection Paths")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                ForEach(deviceStore.diagnosticsConnectionLines(for: device), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )

            ScrollView {
                Text(diagnosticsText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
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
        .frame(minWidth: 760, minHeight: 540, alignment: .topLeading)
        .task(id: device.id) {
            await deviceStore.refreshConnectionDiagnostics(for: device)
        }
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsText, forType: .string)
    }
}

struct LightingCard: View {
    let editorStore: EditorStore
    let selected: MouseDevice
    let swatches: [LightingSwatch]

    private var accentBase: Color {
        Color(rgb: editorStore.editableColor)
    }

    private var accentOpacity: Double {
        let brightness = Double(max(0, min(255, editorStore.editableLedBrightness))) / 255.0
        return 0.10 + (brightness * 0.22)
    }

    private var showsStaticLightingZonePicker: Bool {
        editorStore.editableLightingEffect == .staticColor &&
            editorStore.visibleUSBLightingZones.count > 1
    }

    private var zoneGradientColors: [Color] {
        guard showsStaticLightingZonePicker,
              editorStore.editableUSBLightingZoneID != "all"
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
        let zones = editorStore.visibleUSBLightingZones.filter { $0.id == editorStore.editableUSBLightingZoneID }

        let overlayOpacity = max(0.10, accentOpacity * 0.9)
        let zoneColors = zones.map { zone in
            (zonePalette[zone.id] ?? accentBase)
                .opacity(0.16)
        }

        return [accentBase.opacity(overlayOpacity)] + zoneColors + [Color.white.opacity(0.05)]
    }

    private var brightnessPercent: Int {
        Int(round((Double(max(0, min(255, editorStore.editableLedBrightness))) / 255.0) * 100.0))
    }

    @ViewBuilder
    private func staticLightingZonePicker(applyOnChange: Bool) -> some View {
        if showsStaticLightingZonePicker {
            HStack {
                Text("Zone")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { editorStore.editableUSBLightingZoneID },
                        set: {
                            editorStore.updateUSBLightingZoneID($0)
                            if applyOnChange {
                                editorStore.scheduleAutoApplyLightingEffect()
                            }
                        }
                    )
                ) {
                    Text("All Zones").tag("all")
                    ForEach(editorStore.visibleUSBLightingZones) { zone in
                        Text(zone.label).tag(zone.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220, alignment: .trailing)
            }
        }
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
                    get: { (Double(max(0, min(255, editorStore.editableLedBrightness))) / 255.0) * 100.0 },
                    set: { newValue in
                        let percent = max(0.0, min(100.0, newValue))
                        editorStore.editableLedBrightness = Int(round((percent / 100.0) * 255.0))
                        editorStore.scheduleAutoApplyLedBrightness()
                    }
                ),
                in: 0...100
            )
            .tint(accentBase)
            .padding(.vertical, 8)

            if !selected.supports_advanced_lighting_effects {
                staticLightingZonePicker(applyOnChange: false)

                LightingColorEditor(
                    title: "Color",
                    color: Binding(
                        get: { editorStore.editableColor },
                        set: {
                            editorStore.editableColor = $0
                            editorStore.scheduleAutoApplyLedColor()
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
                            get: { editorStore.editableLightingEffect },
                            set: {
                                editorStore.updateLightingEffect($0)
                                editorStore.scheduleAutoApplyLightingEffect()
                            }
                        )
                    ) {
                        ForEach(editorStore.visibleLightingEffects) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .trailing)
                }

                if editorStore.editableLightingEffect.usesWaveDirection {
                    HStack {
                        Text("Direction")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                        Spacer()
                        Picker(
                            "Direction",
                            selection: Binding(
                                get: { editorStore.editableLightingWaveDirection },
                                set: {
                                    editorStore.updateLightingWaveDirection($0)
                                    editorStore.scheduleAutoApplyLightingEffect()
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

                if editorStore.editableLightingEffect.usesReactiveSpeed {
                    HStack {
                        Text("Speed")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                        Spacer()
                        Picker(
                            "Speed",
                            selection: Binding(
                                get: { editorStore.editableLightingReactiveSpeed },
                                set: {
                                    editorStore.updateLightingReactiveSpeed($0)
                                    editorStore.scheduleAutoApplyLightingEffect()
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

                if editorStore.editableLightingEffect.usesPrimaryColor {
                    staticLightingZonePicker(applyOnChange: true)

                    LightingColorEditor(
                        title: "Primary Color",
                        color: Binding(
                            get: { editorStore.editableColor },
                            set: {
                                editorStore.editableColor = $0
                                editorStore.scheduleAutoApplyLightingEffect()
                            }
                        ),
                        swatches: swatches
                    )
                }

                if editorStore.editableLightingEffect.usesSecondaryColor {
                    LightingColorEditor(
                        title: "Secondary Color",
                        color: Binding(
                            get: { editorStore.editableSecondaryColor },
                            set: {
                                editorStore.editableSecondaryColor = $0
                                editorStore.scheduleAutoApplyLightingEffect()
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
    let editorStore: EditorStore

    var body: some View {
        let sliderRange = DeviceProfiles.sliderDpiRange(for: editorStore.selectedDeviceProfileID)
        let sliderDoubleRange = Double(sliderRange.lowerBound)...Double(sliderRange.upperBound)
        let supportsIndependentXYDPI = editorStore.selectedDeviceSupportsIndependentXYDPI
        let supportsMultiStage = true
        let stageCount = supportsMultiStage ? editorStore.editableStageCount : 1
        return Card(title: "DPI Stages") {
            HStack {
                Text(
                    supportsMultiStage
                        ? "Enabled stages: \(editorStore.editableStageCount) / 5"
                        : "Single-stage DPI"
                )
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        guard supportsMultiStage else { return }
                        let next = max(1, editorStore.editableStageCount - 1)
                        guard next != editorStore.editableStageCount else { return }
                        editorStore.editableStageCount = next
                        editorStore.editableActiveStage = min(editorStore.editableActiveStage, editorStore.editableStageCount)
                        editorStore.normalizeExpandedXYStages()
                        editorStore.scheduleAutoApplyDpi()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(supportsMultiStage && editorStore.editableStageCount > 1 ? .white : .white.opacity(0.35))
                    .disabled(!supportsMultiStage || editorStore.editableStageCount <= 1)

                    Button {
                        guard supportsMultiStage else { return }
                        let next = min(5, editorStore.editableStageCount + 1)
                        guard next != editorStore.editableStageCount else { return }
                        editorStore.editableStageCount = next
                        editorStore.normalizeExpandedXYStages()
                        editorStore.scheduleAutoApplyDpi()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(supportsMultiStage && editorStore.editableStageCount < 5 ? .white : .white.opacity(0.35))
                    .disabled(!supportsMultiStage || editorStore.editableStageCount >= 5)
                }
            }

            ForEach(0..<stageCount, id: \.self) { idx in
                let isSelectedStage = stageCount == 1 || editorStore.editableActiveStage == (idx + 1)
                let stageColor = stageAccent(for: idx, isSelected: isSelectedStage)
                let stagePair = editorStore.stagePair(idx)
                let isXYExpanded = supportsIndependentXYDPI && editorStore.isStageXYExpanded(idx)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        stageHeader(for: idx, stageCount: stageCount, stageColor: stageColor, isSelectedStage: isSelectedStage)

                        Spacer()

                        if isXYExpanded {
                            HStack(spacing: 8) {
                                axisTextField(label: "X", value: stagePair.x) { parsed in
                                    editorStore.updateStageX(idx, value: parsed)
                                    editorStore.scheduleAutoApplyDpi()
                                }
                                axisTextField(label: "Y", value: stagePair.y) { parsed in
                                    editorStore.updateStageY(idx, value: parsed)
                                    editorStore.scheduleAutoApplyDpi()
                                }
                            }
                        } else {
                            DpiValueField(
                                placeholder: "DPI",
                                value: editorStore.stageValue(idx),
                                width: 100
                            ) { parsed in
                                editorStore.updateStage(idx, value: parsed)
                                editorStore.scheduleAutoApplyDpi()
                            }
                        }

                        if supportsIndependentXYDPI {
                            xyToggleButton(isExpanded: isXYExpanded, tint: stageColor) {
                                if editorStore.toggleStageXYExpansion(idx) {
                                    editorStore.scheduleAutoApplyDpi()
                                }
                            }
                        }
                    }

                    if supportsIndependentXYDPI && !isXYExpanded && stagePair.x != stagePair.y {
                        Text("Current split: X \(stagePair.x) / Y \(stagePair.y)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.62))
                    }

                    if isXYExpanded {
                        axisSlider(
                            label: "X",
                            value: stagePair.x,
                            sliderRange: sliderRange,
                            sliderDoubleRange: sliderDoubleRange,
                            tint: isSelectedStage ? stageColor : Color.white.opacity(0.80)
                        ) { quantized in
                            editorStore.updateStageX(idx, value: quantized)
                            editorStore.scheduleAutoApplyDpi()
                        }
                        axisSlider(
                            label: "Y",
                            value: stagePair.y,
                            sliderRange: sliderRange,
                            sliderDoubleRange: sliderDoubleRange,
                            tint: isSelectedStage ? stageColor.opacity(0.8) : Color.white.opacity(0.65)
                        ) { quantized in
                            editorStore.updateStageY(idx, value: quantized)
                            editorStore.scheduleAutoApplyDpi()
                        }
                    } else {
                        Slider(
                            value: Binding(
                                get: { Double(min(editorStore.stageValue(idx), sliderRange.upperBound)) },
                                set: { newValue in
                                    let quantized = Int(round(newValue / 100.0) * 100.0)
                                    editorStore.updateStage(idx, value: quantized)
                                    editorStore.scheduleAutoApplyDpi()
                                }
                            ),
                            in: sliderDoubleRange,
                            onEditingChanged: { editing in
                                editorStore.isEditingDpiControl = editing
                            }
                        )
                        .tint(isSelectedStage ? stageColor : Color.white.opacity(0.80))
                    }
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

    private func axisTextField(label: String, value: Int, onCommit: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            DpiValueField(
                placeholder: label,
                value: value,
                width: 88
            ) { parsed in
                onCommit(parsed)
            }
        }
    }

    private func xyToggleButton(isExpanded: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("X/Y")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(isExpanded ? tint : .white.opacity(0.78))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isExpanded ? tint.opacity(0.18) : Color.white.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .stroke(isExpanded ? tint.opacity(0.95) : Color.white.opacity(0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func axisSlider(
        label: String,
        value: Int,
        sliderRange: ClosedRange<Int>,
        sliderDoubleRange: ClosedRange<Double>,
        tint: Color,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label)-Axis")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Slider(
                value: Binding(
                    get: { Double(min(value, sliderRange.upperBound)) },
                    set: { newValue in
                        onChange(Int(round(newValue / 100.0) * 100.0))
                    }
                ),
                in: sliderDoubleRange,
                onEditingChanged: { editing in
                    editorStore.isEditingDpiControl = editing
                }
            )
            .tint(tint)
        }
    }

    @ViewBuilder
    private func stageHeader(for index: Int, stageCount: Int, stageColor: Color, isSelectedStage: Bool) -> some View {
        if stageCount == 1 {
            Text("DPI")
                .foregroundStyle(stageColor)
        } else {
            Button {
                let selected = index + 1
                if editorStore.editableActiveStage != selected {
                    editorStore.editableActiveStage = selected
                    editorStore.scheduleAutoApplyActiveStage()
                }
            } label: {
                Label(
                    "Stage \(index + 1)",
                    systemImage: editorStore.editableActiveStage == (index + 1) ? "checkmark.square.fill" : "square"
                )
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelectedStage ? stageColor.opacity(0.18) : Color.white.opacity(0.05))
                )
                .overlay(
                    Capsule()
                        .stroke(isSelectedStage ? stageColor.opacity(0.95) : Color.white.opacity(0.16), lineWidth: 1)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelectedStage ? stageColor : .white)
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

private struct DpiValueField: View {
    let placeholder: String
    let value: Int
    let width: CGFloat
    var alignment: TextAlignment = .leading
    var isDisabled: Bool = false
    let onCommit: (Int) -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(
        placeholder: String,
        value: Int,
        width: CGFloat,
        alignment: TextAlignment = .leading,
        isDisabled: Bool = false,
        onCommit: @escaping (Int) -> Void
    ) {
        self.placeholder = placeholder
        self.value = value
        self.width = width
        self.alignment = alignment
        self.isDisabled = isDisabled
        self.onCommit = onCommit
        _draft = State(initialValue: String(value))
    }

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .multilineTextAlignment(alignment)
            .disabled(isDisabled)
            .focused($isFocused)
            .onSubmit {
                commitDraft()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commitDraft()
                }
            }
            .onChange(of: value) { _, newValue in
                let resolved = String(newValue)
                if !isFocused && draft != resolved {
                    draft = resolved
                }
            }
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            draft = String(value)
            return
        }
        guard let parsed = Int(trimmed) else {
            draft = String(value)
            return
        }
        onCommit(parsed)
        draft = String(parsed)
    }
}

struct PollRateCard: View {
    let editorStore: EditorStore

    var body: some View {
        Card(title: "Polling Rate") {
            LabeledControlRow(title: "Rate") {
                Picker(
                    "Rate",
                    selection: Binding(
                        get: { editorStore.editablePollRate },
                        set: { editorStore.editablePollRate = $0 }
                    )
                ) {
                    Text("125 Hz").tag(125)
                    Text("500 Hz").tag(500)
                    Text("1000 Hz").tag(1000)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
        }
        .onChange(of: editorStore.editablePollRate) { _, _ in
            editorStore.scheduleAutoApplyPollRate()
        }
    }
}

struct SleepTimeoutCard: View {
    let editorStore: EditorStore

    var body: some View {
        Card(title: "Power Management") {
            HStack {
                Text("Sleep timeout")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(formatTimeout(editorStore.editableSleepTimeout))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }

            Slider(
                value: Binding(
                    get: { Double(editorStore.editableSleepTimeout) },
                    set: { newValue in
                        let quantized = Int(round(newValue / 15.0) * 15.0)
                        editorStore.editableSleepTimeout = max(60, min(900, quantized))
                        editorStore.scheduleAutoApplySleepTimeout()
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
    let editorStore: EditorStore

    var body: some View {
        Card(title: "Low Battery Threshold") {
            HStack {
                Text("Threshold")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                let raw = max(0x0C, min(0x3F, editorStore.editableLowBatteryThresholdRaw))
                Text("~\(approxPercent(raw))%")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }

            Slider(
                value: Binding(
                    get: { Double(max(0x0C, min(0x3F, editorStore.editableLowBatteryThresholdRaw)) ) },
                    set: { newValue in
                        editorStore.editableLowBatteryThresholdRaw = max(0x0C, min(0x3F, Int(round(newValue))))
                        editorStore.scheduleAutoApplyLowBatteryThreshold()
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
    let editorStore: EditorStore
    let state: MouseState

    var body: some View {
        Card(title: "Scroll Controls") {
            VStack(alignment: .leading, spacing: 12) {
                if state.scroll_mode != nil {
                    LabeledControlRow(title: "Wheel") {
                        Picker(
                            "Wheel",
                            selection: Binding(
                                get: { editorStore.editableScrollMode },
                                set: {
                                    editorStore.editableScrollMode = ($0 == 1 ? 1 : 0)
                                    editorStore.scheduleAutoApplyScrollMode()
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
                                get: { editorStore.editableScrollAcceleration },
                                set: {
                                    editorStore.editableScrollAcceleration = $0
                                    editorStore.scheduleAutoApplyScrollAcceleration()
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
                                get: { editorStore.editableScrollSmartReel },
                                set: {
                                    editorStore.editableScrollSmartReel = $0
                                    editorStore.scheduleAutoApplyScrollSmartReel()
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
    let deviceStore: DeviceStore
    let editorStore: EditorStore
    let title: String

    private var isBusy: Bool {
        editorStore.isButtonProfileOperationInFlight
    }

    private var rows: [ButtonBindingRowModel] {
        deviceStore.visibleButtonSlots.map { slot in
            let kind = editorStore.buttonBindingKind(for: slot.slot)
            let turboEnabled = editorStore.buttonBindingTurboEnabled(for: slot.slot)
            let turboRate = editorStore.buttonBindingTurboRatePressesPerSecond(for: slot.slot)
            return ButtonBindingRowModel(
                slot: slot.slot,
                friendlyName: slot.friendlyName,
                isEditable: deviceStore.isButtonSlotEditable(slot.slot) && !isBusy,
                selectedKind: kind,
                turboEligible: kind != .default && kind.supportsTurbo,
                clutchDPI: editorStore.buttonBindingClutchDPI(for: slot.slot),
                keyboardHidKey: editorStore.buttonBindingHidKey(for: slot.slot),
                turboEnabled: turboEnabled,
                turboRatePressesPerSecond: turboRate,
                notice: deviceStore.buttonSlotNotice(slot.slot)
            )
        }
    }

    var body: some View {
        Card(title: title) {
            VStack(alignment: .leading, spacing: 12) {
                ButtonProfileWorkspaceStrip(
                    deviceStore: deviceStore,
                    editorStore: editorStore,
                    isBusy: isBusy
                )

                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        ButtonBindingRow(editorStore: editorStore, row: row)
                    }
                }

                if !deviceStore.hiddenUnsupportedButtonSlots.isEmpty {
                    UnsupportedButtonsFootnote(entries: deviceStore.hiddenUnsupportedButtonSlots)
                }
            }
        }
    }
}

private struct ButtonProfileWorkspaceStrip: View {
    let deviceStore: DeviceStore
    let editorStore: EditorStore
    let isBusy: Bool

    @State private var saveProfileName = ""
    @State private var showsLoadPopover = false
    @State private var showsManageProfiles = false
    @State private var showsSaveProfileSheet = false
    @State private var showsStorePopover = false

    private var currentSource: ButtonProfileSource? {
        editorStore.currentButtonProfileSource
    }

    private var currentMouseSlot: Int? {
        guard case .mouseSlot(let slot)? = currentSource else { return nil }
        return slot
    }

    private var loadedFromLabel: String? {
        guard let currentSource else { return nil }
        return loadedFromDisplayLabel(for: currentSource)
    }

    private var statusLabel: String? {
        editorStore.buttonProfileOperationStatusText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Profiles")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))

                headerControls
            }

            if let statusLabel {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.64))
                }
            }

            if let loadedFromLabel {
                Text("Loaded from \(loadedFromLabel)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if editorStore.currentButtonProfileHasUnsupportedBindings {
                Text("Some bindings in this saved profile aren't available on this mouse. OpenSnek will keep them in the profile, but only supported buttons can be applied here.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
        )
        .sheet(isPresented: $showsSaveProfileSheet) {
            SaveButtonProfileSheet(
                initialName: saveProfileName,
                existingProfiles: editorStore.savedButtonProfiles,
                onSaveNew: { name in
                    _ = editorStore.saveCurrentButtonWorkspaceAsNewProfile(name: name)
                },
                onOverwrite: { id in
                    _ = editorStore.updateOpenSnekButtonProfile(id: id)
                }
            )
        }
        .sheet(isPresented: $showsManageProfiles) {
            ManageButtonProfilesSheet(
                profiles: editorStore.savedButtonProfiles,
                onRename: { id, name in
                    _ = editorStore.renameOpenSnekButtonProfile(id: id, name: name)
                },
                onDelete: { id in
                    editorStore.deleteOpenSnekButtonProfile(id: id)
                }
            )
        }
    }

    @ViewBuilder
    private var headerControls: some View {
        HStack(alignment: .center, spacing: 10) {
            loadButton
            storeButton
            Button("Manage") {
                showsManageProfiles = true
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
    }

    private var loadButton: some View {
        Button {
            showsLoadPopover.toggle()
        } label: {
            Text("Load")
        }
        .buttonStyle(.bordered)
        .disabled(isBusy)
        .popover(isPresented: $showsLoadPopover, arrowEdge: .bottom) {
            LoadButtonProfilePopover(
                editorStore: editorStore,
                pickerLabel: { source in
                    sourceDisplayLabel(for: source)
                },
                onSelect: { source in
                    Task {
                        await MainActor.run { showsLoadPopover = false }
                        await editorStore.loadButtonProfileSourceIntoLive(source)
                    }
                }
            )
        }
        .onChange(of: showsLoadPopover) { _, isPresented in
            if isPresented {
                editorStore.refreshButtonProfilePresentation()
            }
        }
    }

    private var storeButton: some View {
        Button {
            showsStorePopover.toggle()
        } label: {
            Text("Store")
        }
        .buttonStyle(.bordered)
        .disabled(isBusy)
        .popover(isPresented: $showsStorePopover, arrowEdge: .bottom) {
            StoreButtonProfilePopover(
                editorStore: editorStore,
                currentMouseSlot: currentMouseSlot,
                pickerLabel: { source in
                    pickerLabel(for: source)
                },
                onSave: {
                    showsStorePopover = false
                    prepareSaveProfileSheet()
                },
                onWriteStoredSlot: { slot in
                    showsStorePopover = false
                    Task {
                        await editorStore.writeCurrentButtonWorkspaceToMouseSlot(slot)
                    }
                },
                onReplaceCurrentSlot: {
                    guard let currentMouseSlot else { return }
                    showsStorePopover = false
                    Task {
                        await editorStore.writeCurrentButtonWorkspaceToMouseSlot(currentMouseSlot)
                    }
                },
                onRevertToSource: {
                    showsStorePopover = false
                    editorStore.revertButtonWorkspaceToSource()
                }
            )
        }
    }

    private func prepareSaveProfileSheet() {
        saveProfileName = suggestedProfileName()
        showsSaveProfileSheet = true
    }

    private func suggestedProfileName() -> String {
        if let currentSource {
            return editorStore.buttonProfileSourceDisplayName(currentSource)
        }
        return "Live Buttons"
    }

    private func pickerLabel(for source: ButtonProfileSource) -> String {
        switch source {
        case .openSnekProfile:
            return sourceDisplayLabel(for: source)
        case .mouseSlot(let slot):
            return sourceDisplayLabel(for: .mouseSlot(slot))
        }
    }

    private func sourceDisplayLabel(for source: ButtonProfileSource) -> String {
        let baseLabel: String
        switch source {
        case .openSnekProfile:
            baseLabel = editorStore.buttonProfileSourceDisplayName(source)
        case .mouseSlot(let slot):
            baseLabel = slot == 1 ? "Current Buttons (Slot 1)" : "Stored Slot \(slot)"
        }

        if source == currentSource, editorStore.buttonWorkspaceHasUnsavedSourceChanges {
            return baseLabel
        }

        guard let matchDescription = editorStore.buttonProfileSourceMatchDescription(source) else {
            return baseLabel
        }
        return "\(baseLabel) (\(matchDescription))"
    }

    private func loadedFromDisplayLabel(for source: ButtonProfileSource) -> String {
        switch source {
        case .openSnekProfile:
            return editorStore.buttonProfileSourceDisplayName(source)
        case .mouseSlot(let slot):
            return slot == 1 ? "Current Buttons" : "Stored Slot \(slot)"
        }
    }

}

private struct LoadButtonProfilePopover: View {
    let editorStore: EditorStore
    let pickerLabel: (ButtonProfileSource) -> String
    let onSelect: (ButtonProfileSource) -> Void
    @State private var showsSavedProfiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsSavedProfiles {
                savedProfilesView
            } else {
                rootView
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }

    private var rootView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Saved in OpenSnek")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))

                if editorStore.savedButtonProfiles.isEmpty {
                    Text("No saved local profiles yet.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                } else {
                    loadActionButton(
                        "Saved Profiles",
                        trailingDetail: "\(editorStore.savedButtonProfiles.count)",
                        trailingSystemImage: "chevron.right"
                    ) {
                        showsSavedProfiles = true
                    }
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 6) {
                Text("On This Mouse")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))

                ForEach(editorStore.loadableMouseButtonSources, id: \.id) { source in
                    loadActionButton(
                        pickerLabel(source),
                        isDisabled: source == .mouseSlot(1)
                    ) {
                        onSelect(source)
                    }
                }
            }
        }
    }

    private var savedProfilesView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showsSavedProfiles = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Saved Profiles")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.72))
            }
            .buttonStyle(.plain)

            ForEach(editorStore.savedButtonProfiles) { profile in
                let source = ButtonProfileSource.openSnekProfile(profile.id)
                loadActionButton(pickerLabel(source)) {
                    onSelect(source)
                }
            }
        }
    }

    private func loadActionButton(
        _ title: String,
        isDisabled: Bool = false,
        trailingDetail: String? = nil,
        trailingSystemImage: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            popoverRowLabel(
                title,
                trailingDetail: trailingDetail,
                trailingSystemImage: trailingSystemImage
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1.0)
    }

    private func popoverRowLabel(
        _ title: String,
        trailingDetail: String? = nil,
        trailingSystemImage: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            if let trailingDetail {
                Text(trailingDetail)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
            }
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.52))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }
}

private struct StoreButtonProfilePopover: View {
    let editorStore: EditorStore
    let currentMouseSlot: Int?
    let pickerLabel: (ButtonProfileSource) -> String
    let onSave: () -> Void
    let onWriteStoredSlot: (Int) -> Void
    let onReplaceCurrentSlot: () -> Void
    let onRevertToSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Saved in OpenSnek")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))

                storeActionButton("Save", action: onSave)
            }

            if editorStore.supportsMultipleOnboardProfiles {
                Divider().overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Stored Slots")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))

                    ForEach(editorStore.writableMouseButtonSources, id: \.id) { source in
                        if case .mouseSlot(let slot) = source {
                            storeActionButton(pickerLabel(source)) {
                                onWriteStoredSlot(slot)
                            }
                        }
                    }

                    if let currentMouseSlot, currentMouseSlot > 1, editorStore.canReplaceCurrentMouseSlot {
                        storeActionButton("Replace Current Stored Slot", action: onReplaceCurrentSlot)
                    }
                }
            }

            if editorStore.buttonWorkspaceHasUnsavedSourceChanges {
                Divider().overlay(Color.white.opacity(0.08))
                storeActionButton("Revert to Source", action: onRevertToSource)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }

    private func storeActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SaveButtonProfileSheet: View {
    let initialName: String
    let existingProfiles: [OpenSnekButtonProfile]
    let onSaveNew: (String) -> Void
    let onOverwrite: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: SaveButtonProfileMode = .newProfile
    @State private var name = ""
    @State private var selectedProfileID: UUID?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        switch mode {
        case .newProfile:
            return !trimmedName.isEmpty
        case .overwriteExisting:
            return selectedProfileID != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Button Profile")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Saved profiles live in OpenSnek and can be reused across devices.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))

            Picker("Save Mode", selection: $mode) {
                Text("New").tag(SaveButtonProfileMode.newProfile)
                Text("Overwrite").tag(SaveButtonProfileMode.overwriteExisting)
            }
            .pickerStyle(.segmented)

            if mode == .newProfile {
                TextField("Profile Name", text: $name)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker(
                    "Existing Profile",
                    selection: Binding(
                        get: { selectedProfileID ?? existingProfiles.first?.id },
                        set: { selectedProfileID = $0 }
                    )
                ) {
                    ForEach(existingProfiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Save") {
                    switch mode {
                    case .newProfile:
                        onSaveNew(trimmedName)
                    case .overwriteExisting:
                        if let selectedProfileID {
                            onOverwrite(selectedProfileID)
                        }
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if name.isEmpty {
                name = initialName
            }
            if selectedProfileID == nil {
                selectedProfileID = existingProfiles.first?.id
            }
            if existingProfiles.isEmpty {
                mode = .newProfile
            }
        }
    }
}

private enum SaveButtonProfileMode: Hashable {
    case newProfile
    case overwriteExisting
}

private struct ManageButtonProfilesSheet: View {
    let profiles: [OpenSnekButtonProfile]
    let onRename: (UUID, String) -> Void
    let onDelete: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftNames: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved Button Profiles")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Manage your OpenSnek profile library.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            if profiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No saved profiles yet.")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Use Store to save the current button layout into OpenSnek.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.04))
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(profiles) { profile in
                            HStack(spacing: 10) {
                                TextField(
                                    "Profile Name",
                                    text: Binding(
                                        get: { draftNames[profile.id] ?? profile.name },
                                        set: { draftNames[profile.id] = $0 }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)

                                Button("Rename") {
                                    onRename(profile.id, draftNames[profile.id] ?? profile.name)
                                }
                                .disabled((draftNames[profile.id] ?? profile.name).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                Button("Delete", role: .destructive) {
                                    onDelete(profile.id)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white.opacity(0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                    )
                            )
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            draftNames = profiles.reduce(into: [:]) { partialResult, profile in
                partialResult[profile.id] = profile.name
            }
        }
        .onChange(of: profiles) { _, newValue in
            draftNames = newValue.reduce(into: [:]) { partialResult, profile in
                partialResult[profile.id] = draftNames[profile.id] ?? profile.name
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

            Text("OpenSnek can still use the rest of the device normally.")
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
    let clutchDPI: Int
    let keyboardHidKey: Int
    let turboEnabled: Bool
    let turboRatePressesPerSecond: Int
    let notice: String?

    var id: Int { slot }
}

private struct ButtonBindingRow: View {
    let editorStore: EditorStore
    let row: ButtonBindingRowModel

    var body: some View {
        let sliderRange = DeviceProfiles.sliderDpiRange(for: editorStore.selectedDeviceProfileID)
        let sliderDoubleRange = Double(sliderRange.lowerBound)...Double(sliderRange.upperBound)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text(row.friendlyName)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer(minLength: 12)

                Picker(
                    "",
                    selection: Binding(
                        get: { editorStore.buttonBindingKind(for: row.slot) },
                        set: { editorStore.updateButtonBindingKind(slot: row.slot, kind: $0) }
                    )
                ) {
                    ForEach(ButtonBindingSupport.availableButtonBindingKinds(profileID: editorStore.selectedDeviceProfileID)) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220, alignment: .trailing)
                .disabled(!row.isEditable)
            }

            if row.selectedKind == .keyboardSimple {
                HStack(alignment: .center, spacing: 12) {
                    Spacer()
                    KeyboardBindingEditor(
                        hidKey: row.keyboardHidKey,
                        isEditable: row.isEditable,
                        onSelect: { editorStore.updateButtonBindingHidKey(slot: row.slot, hidKey: $0) }
                    )
                }
            }

            if row.selectedKind == .dpiClutch {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Text("Clutch DPI")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                        DpiValueField(
                            placeholder: "400",
                            value: editorStore.buttonBindingClutchDPI(for: row.slot),
                            width: 120,
                            alignment: .center,
                            isDisabled: !row.isEditable
                        ) { parsed in
                            editorStore.updateButtonBindingClutchDPI(slot: row.slot, dpi: parsed)
                        }
                    }
                    .frame(width: 300, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Spacer()
                    Text("100")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))

                    Slider(
                        value: Binding(
                            get: { Double(min(editorStore.buttonBindingClutchDPI(for: row.slot), sliderRange.upperBound)) },
                            set: { newValue in
                                let quantized = Int(round(newValue / 100.0) * 100.0)
                                editorStore.updateButtonBindingClutchDPI(slot: row.slot, dpi: quantized)
                            }
                        ),
                        in: sliderDoubleRange
                    )
                    .frame(width: 140)
                    .disabled(!row.isEditable)

                    Text("\(sliderRange.upperBound)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))

                    Text("\(row.clutchDPI)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.76))
                        .frame(width: 56, alignment: .trailing)
                }
            }

            if row.turboEligible {
                HStack(spacing: 8) {
                    Spacer()
                    turboToggle
                }

                if row.turboEnabled {
                    HStack(spacing: 8) {
                        Spacer()
                        Text("Slow")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))

                        Slider(
                            value: Binding(
                                get: { Double(editorStore.buttonBindingTurboRatePressesPerSecond(for: row.slot)) },
                                set: { editorStore.updateButtonBindingTurboPressesPerSecond(slot: row.slot, pressesPerSecond: Int(round($0))) }
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

    private var turboToggle: some View {
        Toggle(
            "Turbo",
            isOn: Binding(
                get: { editorStore.buttonBindingTurboEnabled(for: row.slot) },
                set: { editorStore.updateButtonBindingTurboEnabled(slot: row.slot, enabled: $0) }
            )
        )
        .toggleStyle(.switch)
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.76))
        .disabled(!row.isEditable)
    }
}
