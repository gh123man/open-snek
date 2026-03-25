import Foundation

public struct DeviceDiagnosticsFormatter {
    public static func format(
        device: MouseDevice,
        state: MouseState?,
        profile: DeviceProfile?,
        generatedAt: Date = Date(),
        appContextLines: [String] = []
    ) -> String {
        var lines: [String] = []
        lines.append("OpenSnek Device Diagnostics")
        lines.append("Generated: \(iso8601(generatedAt))")
        lines.append("")

        appendSection("Device", to: &lines) {
            [
                "Name: \(device.product_name)",
                "Transport: \(device.transport.connectionLabel)",
                "Connection: \(state?.connection ?? device.connectionLabel)",
                "Device ID: \(device.id)",
                "Vendor ID: \(hex(device.vendor_id, width: 4))",
                "Product ID: \(hex(device.product_id, width: 4))",
                "Location ID: \(hex(device.location_id, width: 8))",
                "Serial: \(display(device.serial))",
                "Firmware: \(display(state?.device.firmware ?? device.firmware))",
                "Path (base64): \(display(device.path_b64))",
            ]
        }

        appendSection("Support", to: &lines) {
            let supportStatus: String
            if let profile {
                supportStatus = profile.isLocallyValidated ? "Validated profile" : "Mapped profile (not locally validated)"
            } else {
                supportStatus = "Generic best-effort"
            }
            return [
                "Support status: \(supportStatus)",
                "Resolved profile: \(profile?.id.rawValue ?? "none")",
                "Reported profile ID: \(device.profile_id?.rawValue ?? "none")",
                "Advanced lighting effects: \(yesNo(device.supports_advanced_lighting_effects))",
                "Onboard profile count: \(device.onboard_profile_count)",
            ]
        }

        appendSection("Capabilities", to: &lines) {
            guard let state else {
                return ["Live state unavailable"]
            }
            return [
                "DPI stages: \(yesNo(state.capabilities.dpi_stages))",
                "Polling rate: \(yesNo(state.capabilities.poll_rate))",
                "Power management: \(yesNo(state.capabilities.power_management))",
                "Button remap: \(yesNo(state.capabilities.button_remap))",
                "Lighting: \(yesNo(state.capabilities.lighting))",
            ]
        }

        appendSection("Button Layout", to: &lines) {
            guard let layout = device.button_layout ?? profile?.buttonLayout else {
                return ["No mapped button layout"]
            }

            var sectionLines: [String] = [
                "Visible slots: \(formatSlots(layout.visibleSlots))",
                "Writable slots: \(formatInts(layout.writableSlots))",
            ]

            let hiddenReadOnly = layout.documentedSlots.filter { slot in
                slot.access != .editable && !layout.visibleSlots.contains(where: { $0.slot == slot.slot })
            }
            if hiddenReadOnly.isEmpty {
                sectionLines.append("Hidden unsupported buttons: none")
            } else {
                sectionLines.append("Hidden unsupported buttons:")
                sectionLines.append(contentsOf: hiddenReadOnly.map { slot in
                    let note = slot.note ?? slot.access.defaultNotice ?? "Unsupported"
                    return "- \(slot.slot): \(slot.descriptor.friendlyName) (\(note))"
                })
            }
            return sectionLines
        }

        appendSection("Lighting", to: &lines) {
            let effects = profile?.supportedLightingEffects.map(\.label).joined(separator: ", ") ?? "Unknown"
            let zones = (profile?.usbLightingZones ?? []).map { zone in
                "\(zone.label) [\(zone.ledIDs.map { hex(Int($0), width: 2) }.joined(separator: ", "))]"
            }
            return [
                "Supported effects: \(effects)",
                "USB zones: \(zones.isEmpty ? "None mapped" : zones.joined(separator: "; "))",
            ]
        }

        appendSection("Live State", to: &lines) {
            guard let state else {
                return ["Live state unavailable"]
            }
            return [
                "Battery: \(formatBattery(percent: state.battery_percent, charging: state.charging))",
                "Current DPI: \(formatDpi(state.dpi))",
                "DPI stages: \(formatStages(state.dpi_stages))",
                "Polling rate: \(displayInt(state.poll_rate, suffix: " Hz"))",
                "Sleep timeout: \(displayInt(state.sleep_timeout, suffix: " s"))",
                "Device mode: \(formatDeviceMode(state.device_mode))",
                "Low battery threshold: \(displayInt(state.low_battery_threshold_raw))",
                "Scroll mode: \(formatScrollMode(state.scroll_mode))",
                "Scroll acceleration: \(displayBool(state.scroll_acceleration))",
                "Smart reel: \(displayBool(state.scroll_smart_reel))",
                "Active onboard profile: \(displayInt(state.active_onboard_profile))",
                "Reported onboard profile count: \(displayInt(state.onboard_profile_count))",
                "LED brightness: \(displayInt(state.led_value))",
            ]
        }

        if !appContextLines.isEmpty {
            appendSection("App Context", to: &lines) {
                appContextLines
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func appendSection(_ title: String, to lines: inout [String], body: () -> [String]) {
        lines.append(title)
        lines.append(String(repeating: "-", count: title.count))
        lines.append(contentsOf: body())
        lines.append("")
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private static func hex(_ value: Int, width: Int) -> String {
        String(format: "0x%0\(width)X", value)
    }

    private static func display(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Unknown" }
        return value
    }

    private static func displayInt(_ value: Int?, suffix: String = "") -> String {
        guard let value else { return "Unknown" }
        return "\(value)\(suffix)"
    }

    private static func displayBool(_ value: Bool?) -> String {
        guard let value else { return "Unknown" }
        return value ? "On" : "Off"
    }

    private static func formatBattery(percent: Int?, charging: Bool?) -> String {
        let chargeState: String
        switch charging {
        case true:
            chargeState = "charging"
        case false:
            chargeState = "not charging"
        case nil:
            chargeState = "charging state unknown"
        }

        guard let percent else {
            return "Unknown (\(chargeState))"
        }
        return "\(percent)% (\(chargeState))"
    }

    private static func formatDpi(_ dpi: DpiPair?) -> String {
        guard let dpi else { return "Unknown" }
        return "\(dpi.x) x \(dpi.y)"
    }

    private static func formatStages(_ stages: DpiStages) -> String {
        guard let values = stages.values, !values.isEmpty else { return "Unknown" }
        let active = stages.active_stage.map { max(0, min(values.count - 1, $0)) }
        let pairs = values.enumerated().map { index, value in
            let marker = active == index ? "*" : ""
            return "\(index + 1):\(value)\(marker)"
        }
        return pairs.joined(separator: ", ")
    }

    private static func formatDeviceMode(_ mode: DeviceMode?) -> String {
        guard let mode else { return "Unknown" }
        return "mode=\(hex(mode.mode, width: 2)) param=\(hex(mode.param, width: 2))"
    }

    private static func formatScrollMode(_ mode: Int?) -> String {
        guard let mode else { return "Unknown" }
        switch mode {
        case 0:
            return "Tactile"
        case 1:
            return "Free-spin"
        default:
            return "\(mode)"
        }
    }

    private static func formatInts(_ values: [Int]) -> String {
        guard !values.isEmpty else { return "None" }
        return values.map(String.init).joined(separator: ", ")
    }

    private static func formatSlots(_ slots: [ButtonSlotDescriptor]) -> String {
        guard !slots.isEmpty else { return "None" }
        return slots.map { "\($0.slot): \($0.friendlyName)" }.joined(separator: "; ")
    }
}
