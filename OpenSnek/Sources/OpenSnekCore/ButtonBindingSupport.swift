import Foundation

public enum ButtonBindingSupport {
    public static func defaultButtonBinding(for slot: Int) -> ButtonBindingDraft {
        let fallback = ButtonBindingDraft(kind: .default, hidKey: 4, turboEnabled: false, turboRate: 0x8E)
        guard ButtonSlotDescriptor.defaults.contains(where: { $0.slot == slot }) else { return fallback }
        return fallback
    }

    public static func buttonBindingDraftFromUSBFunctionBlock(slot: Int, functionBlock: [UInt8]) -> ButtonBindingDraft? {
        guard functionBlock.count == 7 else { return nil }
        let fallbackRate = 0x8E

        if let defaultBlock = defaultUSBFunctionBlock(for: slot), functionBlock == defaultBlock {
            return ButtonBindingDraft(kind: .default, hidKey: 4, turboEnabled: false, turboRate: fallbackRate)
        }

        let fnClass = functionBlock[0]
        let length = max(0, min(5, Int(functionBlock[1])))
        let data = Array(functionBlock[2..<(2 + length)])

        switch fnClass {
        case 0x00:
            return ButtonBindingDraft(kind: .clearLayer, hidKey: 4, turboEnabled: false, turboRate: fallbackRate)
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
        case 0x06:
            if slot == 96 {
                return ButtonBindingDraft(kind: .default, hidKey: 4, turboEnabled: false, turboRate: fallbackRate)
            }
            return nil
        default:
            return nil
        }
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

    public static func defaultUSBFunctionBlock(for slot: Int) -> [UInt8]? {
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
}
