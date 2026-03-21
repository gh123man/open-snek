import Foundation
import OpenSnekAppSupport
import OpenSnekCore
import SwiftUI

struct DeviceStatusIndicator {
    let label: String
    let color: Color
}

enum DeviceConnectionState: Equatable {
    case disconnected
    case reconnecting
    case connected
    case unsupported
    case error

    var indicator: DeviceStatusIndicator {
        switch self {
        case .disconnected:
            DeviceStatusIndicator(label: "Disconnected", color: Color(hex: 0xFF453A))
        case .reconnecting:
            DeviceStatusIndicator(label: "Reconnecting", color: Color(hex: 0xFFD60A))
        case .connected:
            DeviceStatusIndicator(label: "Connected", color: Color(hex: 0x30D158))
        case .unsupported:
            DeviceStatusIndicator(label: "Unsupported", color: Color(hex: 0xFFD60A))
        case .error:
            DeviceStatusIndicator(label: "Error", color: Color(hex: 0xFF453A))
        }
    }

    var allowsInteraction: Bool {
        self == .connected
    }

    var diagnosticsLabel: String {
        switch self {
        case .disconnected:
            "Disconnected"
        case .reconnecting:
            "Reconnecting to live telemetry"
        case .connected:
            "Live"
        case .unsupported:
            "Unsupported"
        case .error:
            "Error"
        }
    }
}

enum DpiUpdateTransportStatus: String, Codable, Equatable, Sendable {
    case unknown
    case listening
    case streamActive
    case pollingFallback
    case realTimeHID
    case unsupported

    var diagnosticsLabel: String {
        switch self {
        case .unknown:
            "Checking"
        case .listening:
            "Listening for first HID event"
        case .streamActive:
            "HID stream active"
        case .pollingFallback:
            "Polling fallback active"
        case .realTimeHID:
            "Real-time HID active"
        case .unsupported:
            "Unsupported"
        }
    }
}

struct RemoteClientPresenceState {
    let expiresAt: Date
    let selectedDeviceID: String?
}

enum PollingProfile: Equatable {
    case foreground
    case serviceIdle
    case serviceInteractive

    var refreshStateInterval: TimeInterval {
        switch self {
        case .foreground, .serviceInteractive:
            2.0
        case .serviceIdle:
            8.0
        }
    }

    var devicePresenceInterval: TimeInterval {
        switch self {
        case .foreground, .serviceInteractive:
            1.2
        case .serviceIdle:
            4.0
        }
    }

    var fastDpiInterval: TimeInterval? {
        switch self {
        case .foreground:
            0.20
        case .serviceInteractive:
            0.25
        case .serviceIdle:
            nil
        }
    }
}

enum RuntimeWakeSchedule {
    static let minimumSleepInterval: TimeInterval = 0.10
    static let suspendedForSleepInterval: TimeInterval = 60.0

    static func nextSleepInterval(
        now: Date,
        profile: PollingProfile,
        fastDpiInterval: TimeInterval?,
        usesRemoteServiceTransport: Bool,
        lastDevicePresencePollAt: Date,
        lastRefreshStatePollAt: Date,
        lastFastDpiPollAt: Date,
        lastRemoteClientPresencePingAt: Date,
        transientStatusUntil: Date?,
        nextRemoteClientPresenceExpiry: Date?
    ) -> TimeInterval {
        var intervals: [TimeInterval] = []

        if usesRemoteServiceTransport {
            intervals.append(max(0, 1.0 - now.timeIntervalSince(lastRemoteClientPresencePingAt)))
        } else {
            intervals.append(max(0, profile.devicePresenceInterval - now.timeIntervalSince(lastDevicePresencePollAt)))
            intervals.append(max(0, profile.refreshStateInterval - now.timeIntervalSince(lastRefreshStatePollAt)))
            if let fastInterval = fastDpiInterval {
                intervals.append(max(0, fastInterval - now.timeIntervalSince(lastFastDpiPollAt)))
            }
        }

        if let transientStatusUntil {
            intervals.append(max(0, transientStatusUntil.timeIntervalSince(now)))
        }

        if let nextRemoteClientPresenceExpiry {
            intervals.append(max(0, nextRemoteClientPresenceExpiry.timeIntervalSince(now)))
        }

        let nextDue = intervals.filter { $0.isFinite && $0 >= 0 }.min() ?? 1.0
        return max(minimumSleepInterval, nextDue)
    }
}

enum AppStateKeyboardSupport {
    static func hidKey(fromKeyboardText text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        if text == " " {
            return 44
        }

        let normalized = text.trimmingCharacters(in: .newlines).lowercased()
        switch normalized {
        case "enter", "return":
            return 40
        case "esc", "escape":
            return 41
        case "tab":
            return 43
        case "space":
            return 44
        default:
            break
        }

        guard let scalar = normalized.unicodeScalars.first else { return nil }
        let value = scalar.value

        if value >= 97 && value <= 122 {
            return 4 + Int(value - 97)
        }
        if value >= 49 && value <= 57 {
            return 30 + Int(value - 49)
        }
        if value == 48 {
            return 39
        }

        switch Character(scalar) {
        case "-": return 45
        case "=": return 46
        case "[": return 47
        case "]": return 48
        case "\\": return 49
        case ";": return 51
        case "'": return 52
        case "`": return 53
        case ",": return 54
        case ".": return 55
        case "/": return 56
        default: return nil
        }
    }

    static func keyboardText(forHidKey hidKey: Int) -> String? {
        if hidKey >= 4 && hidKey <= 29 {
            return String(UnicodeScalar(hidKey - 4 + 97)!)
        }
        if hidKey >= 30 && hidKey <= 38 {
            return String(hidKey - 30 + 1)
        }
        if hidKey == 39 {
            return "0"
        }

        switch hidKey {
        case 40: return "enter"
        case 41: return "esc"
        case 43: return "tab"
        case 44: return "space"
        case 45: return "-"
        case 46: return "="
        case 47: return "["
        case 48: return "]"
        case 49: return "\\"
        case 51: return ";"
        case 52: return "'"
        case 53: return "`"
        case 54: return ","
        case 55: return "."
        case 56: return "/"
        default: return nil
        }
    }
}

extension DevicePatch {
    var describe: String {
        var parts: [String] = []
        if let deviceMode { parts.append("mode=(\(deviceMode.mode),\(deviceMode.param))") }
        if let lowBatteryThresholdRaw { parts.append("lowBatt=0x\(String(lowBatteryThresholdRaw, radix: 16))") }
        if let scrollMode { parts.append("scrollMode=\(scrollMode)") }
        if let scrollAcceleration { parts.append("scrollAccel=\(scrollAcceleration)") }
        if let scrollSmartReel { parts.append("smartReel=\(scrollSmartReel)") }
        if let pollRate { parts.append("poll=\(pollRate)") }
        if let sleepTimeout { parts.append("sleep=\(sleepTimeout)") }
        if let dpiStages { parts.append("stages=\(dpiStages)") }
        if let activeStage { parts.append("active=\(activeStage)") }
        if let ledBrightness { parts.append("led=\(ledBrightness)") }
        if let ledRGB { parts.append("rgb=(\(ledRGB.r),\(ledRGB.g),\(ledRGB.b))") }
        if let lightingEffect {
            var detail = "fx=\(lightingEffect.kind.rawValue)"
            if lightingEffect.kind.usesWaveDirection {
                detail += ",dir=\(lightingEffect.waveDirection.rawValue)"
            }
            if lightingEffect.kind.usesReactiveSpeed {
                detail += ",speed=\(lightingEffect.reactiveSpeed)"
            }
            if lightingEffect.kind.usesPrimaryColor {
                detail += ",p=(\(lightingEffect.primary.r),\(lightingEffect.primary.g),\(lightingEffect.primary.b))"
            }
            if lightingEffect.kind.usesSecondaryColor {
                detail += ",s=(\(lightingEffect.secondary.r),\(lightingEffect.secondary.g),\(lightingEffect.secondary.b))"
            }
            parts.append(detail)
        }
        if let buttonBinding {
            var detail = "button(slot=\(buttonBinding.slot),kind=\(buttonBinding.kind.rawValue)"
            if buttonBinding.turboEnabled {
                detail += ",turbo=on,rate=\(buttonBinding.turboRate ?? 0x8E)"
            }
            if buttonBinding.kind == .dpiClutch {
                detail += ",dpi=\(buttonBinding.clutchDPI ?? ButtonBindingSupport.defaultV3ProDPIClutchDPI)"
            }
            detail += ")"
            parts.append(detail)
        }
        return parts.isEmpty ? "empty" : parts.joined(separator: " ")
    }
}
