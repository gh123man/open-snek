import Foundation
import IOKit.hid
import OpenSnekCore
import OpenSnekHardware
import OpenSnekProtocols

extension BridgeClient {
    func debugUSBReadButtonBinding(
        device: MouseDevice,
        slot: Int,
        profile: Int = 0x01,
        hypershift: Int = 0x00
    ) async throws -> [UInt8]? {
        guard device.transport != .bluetooth else { return nil }
        let sessions = sessionsFor(device: device)
        guard !sessions.isEmpty else {
            throw BridgeError.commandFailed("Device not available")
        }

        let clampedSlot = UInt8(max(0, min(255, slot)))
        let clampedProfile = UInt8(max(0, min(255, profile)))
        let clampedHypershift = UInt8(max(0, min(1, hypershift)))
        for session in sessions {
            if let block = try getButtonBindingUSBRaw(
                session,
                device,
                profile: clampedProfile,
                slot: clampedSlot,
                hypershift: clampedHypershift
            ) {
                deviceSessions[device.id] = session
                return block
            }
        }
        return nil
    }

    func debugUSBSetButtonBindingRaw(
        device: MouseDevice,
        slot: Int,
        profile: Int = 0x01,
        hypershift: Int = 0x00,
        functionBlock: [UInt8]
    ) async throws -> Bool {
        guard device.transport != .bluetooth else { return false }
        guard functionBlock.count == 7 else {
            throw BridgeError.commandFailed("functionBlock must be exactly 7 bytes")
        }
        let sessions = sessionsFor(device: device)
        guard !sessions.isEmpty else {
            throw BridgeError.commandFailed("Device not available")
        }

        let clampedSlot = UInt8(max(0, min(255, slot)))
        let clampedProfile = UInt8(max(0, min(255, profile)))
        let clampedHypershift = UInt8(max(0, min(1, hypershift)))
        for session in sessions {
            if try setButtonBindingUSBRaw(
                session,
                device,
                profile: clampedProfile,
                slot: clampedSlot,
                hypershift: clampedHypershift,
                functionBlock: functionBlock
            ) {
                deviceSessions[device.id] = session
                return true
            }
        }
        return false
    }

    func readUSBState(device: MouseDevice, session: USBHIDControlSession) async throws -> MouseState {
        if hidAccessDenied {
            throw BridgeError.commandFailed(
                "USB HID feature reports are blocked by macOS permissions. " +
                "Enable Input Monitoring for this app host and relaunch."
            )
        }

        guard let dpi = try getDPI(session, device) else {
            if hidAccessDenied {
                throw BridgeError.commandFailed(
                    "USB HID feature reports are blocked by macOS permissions. " +
                    "Enable Input Monitoring for this app host and relaunch."
                )
            }
            throw BridgeError.commandFailed(
                "USB device telemetry unavailable. Feature-report interface did not return usable responses."
            )
        }

        let serial = try getSerial(session, device)
        if hidAccessDenied {
            throw BridgeError.commandFailed(
                "USB HID feature reports are blocked by macOS permissions. " +
                "Enable Input Monitoring for this app host and relaunch."
            )
        }
        let fw = try getFirmware(session, device)
        let mode = try getDeviceMode(session, device)
        let battery = try getBattery(session, device)
        let stages = try getDPIStages(session, device)
        let poll = try getPollRate(session, device)
        let sleepTimeout = try getIdleTime(session, device)
        let lowBatteryThreshold = try getLowBatteryThreshold(session, device)
        let scrollMode = try getScrollMode(session, device)
        let scrollAcceleration = try getScrollAcceleration(session, device)
        let scrollSmartReel = try getScrollSmartReel(session, device)
        let led = try getScrollLEDBrightness(session, device)

        let active = stages?.0 ?? 0
        let values = stages?.1 ?? [dpi.0]

        return MouseState(
            device: DeviceSummary(
                id: device.id,
                product_name: device.product_name,
                serial: serial ?? device.serial,
                transport: device.transport,
                firmware: fw ?? device.firmware
            ),
            connection: "usb",
            battery_percent: battery?.0,
            charging: battery?.1,
            dpi: DpiPair(x: dpi.0, y: dpi.1),
            dpi_stages: DpiStages(active_stage: active, values: values),
            poll_rate: poll,
            sleep_timeout: sleepTimeout,
            device_mode: mode.map { DeviceMode(mode: $0.0, param: $0.1) },
            low_battery_threshold_raw: lowBatteryThreshold,
            scroll_mode: scrollMode,
            scroll_acceleration: scrollAcceleration,
            scroll_smart_reel: scrollSmartReel,
            led_value: led,
            capabilities: Capabilities(dpi_stages: true, poll_rate: true, power_management: true, button_remap: true, lighting: true)
        )
    }

    func sessionFor(device: MouseDevice) -> USBHIDControlSession? {
        deviceSessions[device.id]
    }

    func sessionsFor(device: MouseDevice) -> [USBHIDControlSession] {
        if let preferred = deviceSessions[device.id] {
            let rest = (deviceSessionCandidates[device.id] ?? []).filter { $0 !== preferred }
            return [preferred] + rest
        }
        return deviceSessionCandidates[device.id] ?? []
    }

    func perform(
        _ session: USBHIDControlSession,
        _ device: MouseDevice,
        classID: UInt8,
        cmdID: UInt8,
        size: UInt8,
        args: [UInt8] = [],
        allowTxnRescan: Bool = false,
        responseAttempts: Int = 6,
        responseDelayUs: useconds_t = 30_000
    ) throws -> [UInt8]? {
        do {
            let response = try session.perform(
                classID: classID,
                cmdID: cmdID,
                size: size,
                args: args,
                allowTxnRescan: allowTxnRescan,
                responseAttempts: responseAttempts,
                responseDelayUs: responseDelayUs
            )
            hidAccessDenied = false
            return response
        } catch let error as BridgeError {
            if case .commandFailed(let message) = error, message.contains("USB HID access denied") {
                hidAccessDenied = true
                let now = Date()
                if lastOpenDeniedLogAt == nil || now.timeIntervalSince(lastOpenDeniedLogAt!) > 2.0 {
                    AppLog.debug("Bridge", "USB HID access denied device=\(device.id)")
                    lastOpenDeniedLogAt = now
                }
            }
            throw error
        }
    }

    func getDPI(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> (Int, Int)? {
        guard let r = try perform(session, device, classID: 0x04, cmdID: 0x85, size: 0x07, args: [0x00], allowTxnRescan: true), r[0] == 0x02 else { return nil }
        return (Int(r[9]) << 8 | Int(r[10]), Int(r[11]) << 8 | Int(r[12]))
    }

    func setDPI(_ session: USBHIDControlSession, _ device: MouseDevice, dpiX: Int, dpiY: Int, store: Bool) throws -> Bool {
        let x = max(100, min(30_000, dpiX))
        let y = max(100, min(30_000, dpiY))
        let storage: UInt8 = store ? 0x01 : 0x00
        let args: [UInt8] = [
            storage,
            UInt8((x >> 8) & 0xFF),
            UInt8(x & 0xFF),
            UInt8((y >> 8) & 0xFF),
            UInt8(y & 0xFF),
        ]
        guard let r = try perform(session, device, classID: 0x04, cmdID: 0x05, size: 0x07, args: args, allowTxnRescan: true), r[0] == 0x02 else { return false }
        return true
    }

    func getDPIStages(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> (Int, [Int])? {
        guard let snapshot = try getDPIStageSnapshot(session, device) else { return nil }
        return (snapshot.active, snapshot.values)
    }

    func getDPIStageSnapshot(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> USBDpiStageSnapshot? {
        guard let r = try perform(session, device, classID: 0x04, cmdID: 0x86, size: 0x26, allowTxnRescan: true),
              r[0] == 0x02
        else {
            return nil
        }

        let count = max(1, min(5, Int(r[9])))
        var values: [Int] = []
        var stageIDs: [UInt8] = []
        for i in 0..<count {
            let off = 10 + (i * 7)
            guard off + 4 < r.count else { break }
            let stageID = r[off]
            let dpi = (Int(r[off + 1]) << 8) | Int(r[off + 2])
            stageIDs.append(stageID)
            values.append(max(100, min(30_000, dpi)))
        }

        if values.isEmpty {
            return nil
        }

        while values.count < count {
            values.append(values.last ?? 800)
            stageIDs.append(stageIDs.last.map { $0 &+ 1 } ?? UInt8(stageIDs.count))
        }
        while values.count < 5 {
            values.append(values.last ?? 800)
            stageIDs.append(stageIDs.last.map { $0 &+ 1 } ?? UInt8(stageIDs.count))
        }

        let activeRaw = Int(r[8])
        let active = usbResolveStageIndex(activeRaw: activeRaw, stageIDs: Array(stageIDs.prefix(count)), count: count)
        return (
            active: active,
            values: Array(values.prefix(count)),
            stageIDs: Array(stageIDs.prefix(count))
        )
    }

    func usbResolveStageIndex(activeRaw: Int, stageIDs: [UInt8], count: Int) -> Int {
        if let mapped = stageIDs.firstIndex(of: UInt8(activeRaw & 0xFF)) {
            return mapped
        }
        if activeRaw >= 1, activeRaw <= count {
            return activeRaw - 1
        }
        return max(0, min(count - 1, activeRaw))
    }

    func usbStageIDsForWrite(count: Int, stageIDs: [UInt8]?) -> [UInt8] {
        let clippedCount = max(1, min(5, count))
        var ids = Array((stageIDs ?? [0, 1, 2, 3, 4]).prefix(clippedCount))
        while ids.count < clippedCount {
            ids.append(ids.last.map { $0 &+ 1 } ?? UInt8(ids.count))
        }
        return ids
    }

    func setDPIStages(
        _ session: USBHIDControlSession,
        _ device: MouseDevice,
        stages: [Int],
        activeStage: Int,
        stageIDs: [UInt8]? = nil
    ) throws -> Bool {
        let clipped = Array(stages.prefix(5)).map { max(100, min(30_000, $0)) }
        guard !clipped.isEmpty else { return false }
        let activeClamped = max(0, min(clipped.count - 1, activeStage))
        let writeStageIDs = usbStageIDsForWrite(count: clipped.count, stageIDs: stageIDs)
        guard writeStageIDs.count == clipped.count else { return false }

        var args = [UInt8](repeating: 0, count: 3 + clipped.count * 7)
        args[0] = 0x01
        args[1] = writeStageIDs[activeClamped]
        args[2] = UInt8(clipped.count)
        var off = 3
        for (i, dpi) in clipped.enumerated() {
            args[off] = writeStageIDs[i]
            args[off + 1] = UInt8((dpi >> 8) & 0xFF)
            args[off + 2] = UInt8(dpi & 0xFF)
            args[off + 3] = UInt8((dpi >> 8) & 0xFF)
            args[off + 4] = UInt8(dpi & 0xFF)
            off += 7
        }

        guard let r = try perform(session, device, classID: 0x04, cmdID: 0x06, size: 0x26, args: args) else { return false }
        return r[0] == 0x02
    }

    func getPollRate(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> Int? {
        guard let r = try perform(session, device, classID: 0x00, cmdID: 0x85, size: 0x01), r[0] == 0x02 else { return nil }
        switch r[8] {
        case 0x01: return 1000
        case 0x02: return 500
        case 0x08: return 125
        default: return nil
        }
    }

    func setPollRate(_ session: USBHIDControlSession, _ device: MouseDevice, value: Int) throws -> Bool {
        let raw: UInt8
        switch value {
        case 1000: raw = 0x01
        case 500: raw = 0x02
        case 125: raw = 0x08
        default: return false
        }
        guard let r = try perform(session, device, classID: 0x00, cmdID: 0x05, size: 0x01, args: [raw]) else { return false }
        return r[0] == 0x02
    }

    func getIdleTime(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> Int? {
        guard let r = try perform(session, device, classID: 0x07, cmdID: 0x83, size: 0x02), r[0] == 0x02 else { return nil }
        return (Int(r[8]) << 8) | Int(r[9])
    }

    func setIdleTime(_ session: USBHIDControlSession, _ device: MouseDevice, seconds: Int) throws -> Bool {
        let clamped = max(60, min(900, seconds))
        let args: [UInt8] = [UInt8((clamped >> 8) & 0xFF), UInt8(clamped & 0xFF)]
        guard let r = try perform(session, device, classID: 0x07, cmdID: 0x03, size: 0x02, args: args) else { return false }
        return r[0] == 0x02
    }

    func getBattery(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> (Int, Bool)? {
        guard let r = try perform(session, device, classID: 0x07, cmdID: 0x80, size: 0x02), r[0] == 0x02 else { return nil }
        let charging = r[8] == 0x01
        let pct = Int((Double(r[9]) / 255.0) * 100.0)
        return (pct, charging)
    }

    func getSerial(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> String? {
        guard let r = try perform(session, device, classID: 0x00, cmdID: 0x82, size: 0x16), r[0] == 0x02 else { return nil }
        let raw = Data(r[8..<30])
        let s = String(data: raw, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        return s?.isEmpty == false ? s : nil
    }

    func getFirmware(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> String? {
        guard let r = try perform(session, device, classID: 0x00, cmdID: 0x81, size: 0x02), r[0] == 0x02 else { return nil }
        return "\(r[8]).\(r[9])"
    }

    func getDeviceMode(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> (Int, Int)? {
        guard let r = try perform(session, device, classID: 0x00, cmdID: 0x84, size: 0x02), r[0] == 0x02 else { return nil }
        return (Int(r[8]), Int(r[9]))
    }

    func setDeviceMode(_ session: USBHIDControlSession, _ device: MouseDevice, mode: Int, param: Int = 0x00) throws -> Bool {
        let modeRaw: UInt8 = mode == 0x03 ? 0x03 : 0x00
        let args: [UInt8] = [modeRaw, UInt8(param & 0xFF)]
        guard let r = try perform(session, device, classID: 0x00, cmdID: 0x04, size: 0x02, args: args) else { return false }
        return r[0] == 0x02
    }

    func getLowBatteryThreshold(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> Int? {
        guard let r = try perform(session, device, classID: 0x07, cmdID: 0x81, size: 0x01), r[0] == 0x02 else { return nil }
        return Int(r[8])
    }

    func setLowBatteryThreshold(_ session: USBHIDControlSession, _ device: MouseDevice, thresholdRaw: Int) throws -> Bool {
        let clamped = UInt8(max(0x0C, min(0x3F, thresholdRaw)))
        guard let r = try perform(session, device, classID: 0x07, cmdID: 0x01, size: 0x01, args: [clamped]) else { return false }
        return r[0] == 0x02
    }

    func getScrollMode(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> Int? {
        let args: [UInt8] = [0x01, 0x00]
        guard let r = try perform(session, device, classID: 0x02, cmdID: 0x94, size: 0x02, args: args), r[0] == 0x02 else { return nil }
        return Int(r[9])
    }

    func setScrollMode(_ session: USBHIDControlSession, _ device: MouseDevice, mode: Int) throws -> Bool {
        let modeRaw: UInt8 = mode == 1 ? 0x01 : 0x00
        let args: [UInt8] = [0x01, modeRaw]
        guard let r = try perform(session, device, classID: 0x02, cmdID: 0x14, size: 0x02, args: args) else { return false }
        return r[0] == 0x02
    }

    func getScrollAcceleration(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> Bool? {
        let args: [UInt8] = [0x01, 0x00]
        guard let r = try perform(session, device, classID: 0x02, cmdID: 0x96, size: 0x02, args: args), r[0] == 0x02 else { return nil }
        return r[9] != 0
    }

    func setScrollAcceleration(_ session: USBHIDControlSession, _ device: MouseDevice, enabled: Bool) throws -> Bool {
        let args: [UInt8] = [0x01, enabled ? 0x01 : 0x00]
        guard let r = try perform(session, device, classID: 0x02, cmdID: 0x16, size: 0x02, args: args) else { return false }
        return r[0] == 0x02
    }

    func getScrollSmartReel(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> Bool? {
        let args: [UInt8] = [0x01, 0x00]
        guard let r = try perform(session, device, classID: 0x02, cmdID: 0x97, size: 0x02, args: args), r[0] == 0x02 else { return nil }
        return r[9] != 0
    }

    func setScrollSmartReel(_ session: USBHIDControlSession, _ device: MouseDevice, enabled: Bool) throws -> Bool {
        let args: [UInt8] = [0x01, enabled ? 0x01 : 0x00]
        guard let r = try perform(session, device, classID: 0x02, cmdID: 0x17, size: 0x02, args: args) else { return false }
        return r[0] == 0x02
    }

    func getScrollLEDBrightness(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> Int? {
        let args: [UInt8] = [0x01, 0x01]
        guard let r = try perform(session, device, classID: 0x0F, cmdID: 0x84, size: 0x03, args: args), r[0] == 0x02 else { return nil }
        return Int(r[10])
    }

    func setScrollLEDBrightness(_ session: USBHIDControlSession, _ device: MouseDevice, value: Int) throws -> Bool {
        let v = UInt8(max(0, min(255, value)))
        let args: [UInt8] = [0x01, 0x01, v]
        guard let r = try perform(session, device, classID: 0x0F, cmdID: 0x04, size: 0x03, args: args) else { return false }
        return r[0] == 0x02
    }

    func setScrollLEDEffect(_ session: USBHIDControlSession, _ device: MouseDevice, effect: LightingEffectPatch) throws -> Bool {
        let args = BLEVendorProtocol.buildScrollLEDEffectArgs(effect: effect)
        guard let r = try perform(
            session,
            device,
            classID: 0x0F,
            cmdID: 0x02,
            size: UInt8(max(0, min(255, args.count))),
            args: args
        ) else { return false }
        return r[0] == 0x02
    }

    func setButtonBindingUSBRaw(
        _ session: USBHIDControlSession,
        _ device: MouseDevice,
        profile: UInt8,
        slot: UInt8,
        hypershift: UInt8,
        functionBlock: [UInt8]
    ) throws -> Bool {
        guard functionBlock.count == 7 else { return false }
        let args = [profile, slot, hypershift] + functionBlock
        guard let r = try perform(
            session,
            device,
            classID: 0x02,
            cmdID: 0x0C,
            size: UInt8(args.count),
            args: args,
            allowTxnRescan: true,
            responseAttempts: 12,
            responseDelayUs: 40_000
        ) else { return false }
        return r[0] == 0x02
    }

    func setButtonBindingUSB(
        _ session: USBHIDControlSession,
        _ device: MouseDevice,
        slot: Int,
        kind: String,
        hidKey: Int,
        turboEnabled: Bool,
        turboRate: Int
    ) throws -> Bool {
        guard let bindingKind = ButtonBindingKind(rawValue: kind) else { return false }
        let functionBlock = ButtonBindingSupport.buildUSBFunctionBlock(
            slot: slot,
            kind: bindingKind,
            hidKey: hidKey,
            turboEnabled: turboEnabled && bindingKind.supportsTurbo,
            turboRate: turboRate
        )
        let clampedSlot = UInt8(max(0, min(255, slot)))

        if try setButtonBindingUSBRaw(session, device, profile: 0x01, slot: clampedSlot, hypershift: 0x00, functionBlock: functionBlock) {
            return true
        }

        return try setButtonBindingUSBRaw(
            session,
            device,
            profile: 0x00,
            slot: clampedSlot,
            hypershift: 0x00,
            functionBlock: functionBlock
        )
    }

    func getButtonBindingUSBRaw(
        _ session: USBHIDControlSession,
        _ device: MouseDevice,
        profile: UInt8,
        slot: UInt8,
        hypershift: UInt8
    ) throws -> [UInt8]? {
        var args: [UInt8] = [profile, slot, hypershift]
        args.append(contentsOf: [UInt8](repeating: 0x00, count: 7))
        guard let response = try perform(
            session,
            device,
            classID: 0x02,
            cmdID: 0x8C,
            size: UInt8(args.count),
            args: args,
            allowTxnRescan: true,
            responseAttempts: 12,
            responseDelayUs: 40_000
        ), response[0] == 0x02 else {
            return nil
        }

        if response.count >= 18,
           response[8] == profile,
           response[9] == slot,
           response[10] == hypershift {
            return Array(response[11..<18])
        }
        if response.count >= 15 {
            return Array(response[8..<15])
        }
        return nil
    }
}
