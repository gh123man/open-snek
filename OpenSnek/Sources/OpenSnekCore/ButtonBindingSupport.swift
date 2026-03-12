import Foundation

public enum ButtonBindingSupport {
    public static let defaultV3ProDPIClutchDPI = 400

    private static func basiliskV3ProDPIClutchBlock(dpi: Int = defaultV3ProDPIClutchDPI) -> [UInt8] {
        let clamped = UInt16(max(100, min(30_000, dpi)))
        let hi = UInt8((clamped >> 8) & 0xFF)
        let lo = UInt8(clamped & 0xFF)
        // Observed V3 Pro clutch payload encodes symmetric X/Y DPI.
        return [0x06, 0x05, 0x05, hi, lo, hi, lo]
    }

    private static func v3ProDPIClutchDPI(from functionBlock: [UInt8]) -> Int? {
        guard functionBlock.count == 7,
              functionBlock[0] == 0x06,
              functionBlock[1] == 0x05,
              functionBlock[2] == 0x05
        else {
            return nil
        }
        let dpiX = (Int(functionBlock[3]) << 8) | Int(functionBlock[4])
        let dpiY = (Int(functionBlock[5]) << 8) | Int(functionBlock[6])
        guard dpiX == dpiY else { return nil }
        return max(100, min(30_000, dpiX))
    }

    public static func defaultDPIClutchDPI(for profileID: DeviceProfileID?) -> Int? {
        profileID == .basiliskV3Pro ? defaultV3ProDPIClutchDPI : nil
    }

    public static func defaultButtonBinding(for slot: Int, profileID: DeviceProfileID? = nil) -> ButtonBindingDraft {
        let fallback = ButtonBindingDraft(kind: .default, hidKey: 4, turboEnabled: false, turboRate: 0x8E)
        let visibleSlots = buttonSlotDescriptors(for: profileID)
        guard visibleSlots.contains(where: { $0.slot == slot }) else { return fallback }
        return fallback
    }

    public static func buttonBindingDraftFromUSBFunctionBlock(
        slot: Int,
        functionBlock: [UInt8],
        profileID: DeviceProfileID? = nil
    ) -> ButtonBindingDraft? {
        guard functionBlock.count == 7 else { return nil }
        let fallbackRate = 0x8E

        if let defaultBlock = defaultUSBFunctionBlock(for: slot, profileID: profileID), functionBlock == defaultBlock {
            return ButtonBindingDraft(kind: .default, hidKey: 4, turboEnabled: false, turboRate: fallbackRate)
        }

        let fnClass = functionBlock[0]
        let length = max(0, min(5, Int(functionBlock[1])))
        let data = Array(functionBlock[2..<(2 + length)])

        switch fnClass {
        case 0x00:
            guard functionBlock == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] else { return nil }
            return ButtonBindingDraft(kind: .clearLayer, hidKey: 4, turboEnabled: false, turboRate: fallbackRate)
        case 0x04:
            if slot == 96, functionBlock == [0x04, 0x02, 0x0F, 0x7B, 0x00, 0x00, 0x00] {
                return ButtonBindingDraft(kind: .dpiCycle, hidKey: 4, turboEnabled: false, turboRate: fallbackRate)
            }
            return nil
        case 0x06:
            if functionBlock == [0x06, 0x01, 0x06, 0x00, 0x00, 0x00, 0x00] {
                return ButtonBindingDraft(kind: .dpiCycle, hidKey: 4, turboEnabled: false, turboRate: fallbackRate)
            }
            if profileID == .basiliskV3Pro, let dpi = v3ProDPIClutchDPI(from: functionBlock) {
                return ButtonBindingDraft(
                    kind: .dpiClutch,
                    hidKey: 4,
                    turboEnabled: false,
                    turboRate: fallbackRate,
                    clutchDPI: max(100, min(30_000, dpi))
                )
            }
            return nil
        case 0x01:
            guard let mouseButton = data.first,
                  let kind = buttonKindFromUSBMouseButton(mouseButton)
            else { return nil }
            return ButtonBindingDraft(kind: kind, hidKey: 4, turboEnabled: false, turboRate: fallbackRate)
        case 0x02:
            guard !data.isEmpty else { return nil }
            let hidKey = data.count >= 2 ? Int(data[1]) : Int(data[0])
            return ButtonBindingDraft(
                kind: .keyboardSimple,
                hidKey: max(4, min(231, hidKey)),
                turboEnabled: false,
                turboRate: fallbackRate
            )
        case 0x0D:
            guard data.count >= 4 else { return nil }
            let hidKey = Int(data[1])
            let rawRate = (Int(data[2]) << 8) | Int(data[3])
            return ButtonBindingDraft(
                kind: .keyboardSimple,
                hidKey: max(4, min(231, hidKey)),
                turboEnabled: true,
                turboRate: max(1, min(255, rawRate))
            )
        case 0x0E:
            guard data.count >= 3,
                  let kind = buttonKindFromUSBMouseButton(data[0])
            else { return nil }
            let rawRate = (Int(data[1]) << 8) | Int(data[2])
            return ButtonBindingDraft(
                kind: kind,
                hidKey: 4,
                turboEnabled: true,
                turboRate: max(1, min(255, rawRate))
            )
        default:
            return nil
        }
    }

    public static func extractUSBFunctionBlock(
        response: [UInt8],
        profile: UInt8,
        slot: UInt8,
        hypershift: UInt8,
        profileID: DeviceProfileID? = nil
    ) -> [UInt8]? {
        guard response.count >= 18,
              response[8] == profile,
              response[9] == slot
        else {
            return nil
        }

        if usesExtendedBasiliskUSBReadLayout(profileID) {
            return Array(response[11..<18])
        }

        var candidates: [[UInt8]] = []
        if response[10] == hypershift {
            candidates.append(Array(response[11..<18]))
        }
        candidates.append(Array(response[10..<17]))

        if let defaultBlock = defaultUSBFunctionBlock(for: Int(slot), profileID: profileID),
           let matchedDefault = candidates.first(where: { $0 == defaultBlock }) {
            return matchedDefault
        }

        if let parsed = candidates.first(where: {
            buttonBindingDraftFromUSBFunctionBlock(slot: Int(slot), functionBlock: $0, profileID: profileID) != nil
        }) {
            return parsed
        }

        return candidates.first
    }

    public static func turboRawToPressesPerSecond(_ rawRate: Int) -> Int {
        let raw = max(1, min(255, rawRate))
        let scaled = 20.0 - (Double(raw - 1) * 19.0 / 254.0)
        return max(1, min(20, Int(round(scaled))))
    }

    public static func turboPressesPerSecondToRaw(_ pressesPerSecond: Int) -> Int {
        let pps = max(1, min(20, pressesPerSecond))
        let scaled = 1.0 + (Double(20 - pps) * 254.0 / 19.0)
        return max(1, min(255, Int(round(scaled))))
    }

    public static func buttonKindFromUSBMouseButton(_ value: UInt8) -> ButtonBindingKind? {
        switch value {
        case 0x01: return .leftClick
        case 0x02: return .rightClick
        case 0x03: return .middleClick
        case 0x04: return .mouseBack
        case 0x05: return .mouseForward
        case 0x09: return .scrollUp
        case 0x0A: return .scrollDown
        default: return nil
        }
    }

    public static func usbMouseButtonID(for kind: ButtonBindingKind) -> UInt8? {
        switch kind {
        case .leftClick: return 0x01
        case .rightClick: return 0x02
        case .middleClick: return 0x03
        case .mouseBack: return 0x04
        case .mouseForward: return 0x05
        case .scrollUp: return 0x09
        case .scrollDown: return 0x0A
        default: return nil
        }
    }

    public static func buildUSBFunctionBlock(
        slot: Int,
        kind: ButtonBindingKind,
        hidKey: Int,
        turboEnabled: Bool,
        turboRate: Int,
        clutchDPI: Int? = nil,
        profileID: DeviceProfileID? = nil
    ) -> [UInt8] {
        let clampedKey = UInt8(max(0, min(255, hidKey)))
        let turbo = UInt16(max(1, min(255, turboRate)))
        let turboHi = UInt8((turbo >> 8) & 0xFF)
        let turboLo = UInt8(turbo & 0xFF)

        switch kind {
        case .default:
            return defaultUSBFunctionBlock(for: slot, profileID: profileID) ?? [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        case .dpiCycle:
            return [0x06, 0x01, 0x06, 0x00, 0x00, 0x00, 0x00]
        case .dpiClutch:
            return basiliskV3ProDPIClutchBlock(dpi: clutchDPI ?? defaultV3ProDPIClutchDPI)
        case .clearLayer:
            return [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        case .keyboardSimple:
            if turboEnabled {
                return [0x0D, 0x04, 0x00, clampedKey, turboHi, turboLo, 0x00]
            }
            return [0x02, 0x02, 0x00, clampedKey, 0x00, 0x00, 0x00]
        default:
            if let buttonID = usbMouseButtonID(for: kind) {
                if turboEnabled {
                    return [0x0E, 0x03, buttonID, turboHi, turboLo, 0x00, 0x00]
                }
                return [0x01, 0x01, buttonID, 0x00, 0x00, 0x00, 0x00]
            }
            return [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        }
    }

    public static func defaultUSBFunctionBlock(for slot: Int, profileID: DeviceProfileID? = nil) -> [UInt8]? {
        switch slot {
        case 15 where profileID == .basiliskV3Pro:
            return basiliskV3ProDPIClutchBlock()
        case 52 where usesExtendedBasiliskUSBReadLayout(profileID),
             53 where usesExtendedBasiliskUSBReadLayout(profileID):
            return [0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00]
        case 96:
            switch profileID {
            case .basiliskV335K:
                return [0x04, 0x02, 0x0F, 0x7B, 0x00, 0x00, 0x00]
            case .basiliskV3Pro:
                return nil
            case .basiliskV3XHyperspeed, .none:
                return [0x06, 0x01, 0x06, 0x00, 0x00, 0x00, 0x00]
            }
        default:
            break
        }
        switch slot {
        case 1: return [0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00]
        case 2: return [0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00]
        case 3: return [0x01, 0x01, 0x03, 0x00, 0x00, 0x00, 0x00]
        case 4: return [0x01, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00]
        case 5: return [0x01, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00]
        case 9: return [0x01, 0x01, 0x09, 0x00, 0x00, 0x00, 0x00]
        case 10: return [0x01, 0x01, 0x0A, 0x00, 0x00, 0x00, 0x00]
        case 96: return [0x06, 0x01, 0x06, 0x00, 0x00, 0x00, 0x00]
        default: return nil
        }
    }

    public static func describeUSBFunctionBlock(_ block: [UInt8]) -> String {
        let hex = block.map { String(format: "%02x", $0) }.joined()
        guard block.count == 7 else { return "block=\(hex)" }
        let classID = block[0]
        let length = Int(min(5, block[1]))
        let data = Array(block[2..<(2 + length)])
        let dataHex = data.map { String(format: "%02x", $0) }.joined()
        if let clutchDPI = v3ProDPIClutchDPI(from: block) {
            return "block=\(hex) class=0x\(String(format: "%02x", classID)) len=\(length) data=\(dataHex) dpi_clutch=\(clutchDPI)"
        }
        return "block=\(hex) class=0x\(String(format: "%02x", classID)) len=\(length) data=\(dataHex)"
    }

    public static func availableButtonBindingKinds(profileID: DeviceProfileID?) -> [ButtonBindingKind] {
        ButtonBindingKind.allCases.filter { kind in
            switch kind {
            case .dpiClutch:
                return profileID == .basiliskV3Pro
            default:
                return true
            }
        }
    }

    private static func buttonSlotDescriptors(for profileID: DeviceProfileID?) -> [ButtonSlotDescriptor] {
        switch profileID {
        case .basiliskV3Pro:
            return DeviceProfiles.basiliskV3ProUSBButtonSlots
        case .basiliskV335K:
            return DeviceProfiles.basiliskV335KUSBButtonSlots
        case .basiliskV3XHyperspeed, .none:
            return DeviceProfiles.basiliskV3XButtonSlots
        }
    }

    private static func usesExtendedBasiliskUSBReadLayout(_ profileID: DeviceProfileID?) -> Bool {
        switch profileID {
        case .basiliskV3Pro, .basiliskV335K:
            return true
        case .basiliskV3XHyperspeed, .none:
            return false
        }
    }
}
