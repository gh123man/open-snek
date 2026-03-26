import Foundation
import IOKit.hid
import OpenSnekCore
import OpenSnekHardware
import OpenSnekProtocols

extension BridgeClient {
    static func usbButtonWriteSucceeded(
        writePersistentLayer: Bool,
        writeDirectLayer: Bool,
        wrotePersistent: Bool,
        wroteDirect: Bool
    ) -> Bool {
        if writePersistentLayer, !wrotePersistent {
            return false
        }
        if writeDirectLayer, !wroteDirect {
            return false
        }
        return writePersistentLayer || writeDirectLayer
    }

    func resolvedUSBStateCapabilities(
        device _: MouseDevice,
        profile: DeviceProfile?,
        stages: USBDpiStageSnapshot?,
        poll: Int?,
        sleepTimeout: Int?,
        led: Int?
    ) -> Capabilities {
        if profile != nil {
            return Capabilities(
                dpi_stages: true,
                poll_rate: true,
                power_management: true,
                button_remap: true,
                lighting: true
            )
        }

        return Capabilities(
            dpi_stages: stages != nil,
            poll_rate: poll != nil,
            power_management: sleepTimeout != nil,
            button_remap: false,
            lighting: led != nil
        )
    }

    func resolvedUSBStateCapabilities(
        device: MouseDevice,
        profile: DeviceProfile?,
        stages: (Int, [Int])?,
        poll: Int?,
        sleepTimeout: Int?,
        led: Int?
    ) -> Capabilities {
        resolvedUSBStateCapabilities(
            device: device,
            profile: profile,
            stages: stages.map { active, values in
                (
                    active: active,
                    values: values,
                    pairs: values.map { DpiPair(x: $0, y: $0) },
                    stageIDs: Array(0..<values.count).map(UInt8.init)
                )
            },
            poll: poll,
            sleepTimeout: sleepTimeout,
            led: led
        )
    }

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
        // A cached session-level kIOReturnNotPermitted can be transient around sleep/wake.
        // Always attempt a fresh HID exchange here instead of trapping the process in a
        // self-sustaining permission loop until restart.
        guard let dpi = try getDPI(session, device) else {
            throw BridgeError.commandFailed(
                "USB device telemetry unavailable. Feature-report interface did not return usable responses."
            )
        }

        let serial = try getSerial(session, device)
        let fw = try getFirmware(session, device)
        let mode = try getDeviceMode(session, device)
        let battery = try getBattery(session, device)
        let stages = try getDPIStageSnapshot(session, device)
        let poll = try getPollRate(session, device)
        let sleepTimeout = try getIdleTime(session, device)
        let lowBatteryThreshold = try getLowBatteryThreshold(session, device)
        let scrollMode = try getScrollMode(session, device)
        let scrollAcceleration = try getScrollAcceleration(session, device)
        let scrollSmartReel = try getScrollSmartReel(session, device)
        let onboardProfile = try getOnboardProfileInfo(session, device)
        let led = try getScrollLEDBrightness(session, device)
        let profile = usbDeviceProfile(for: device)
        let capabilities = resolvedUSBStateCapabilities(
            device: device,
            profile: profile,
            stages: stages,
            poll: poll,
            sleepTimeout: sleepTimeout,
            led: led
        )

        let active = stages?.active ?? 0
        let values = stages?.values ?? [dpi.0]
        let pairs = stages?.pairs

        return MouseState(
            device: DeviceSummary(
                id: device.id,
                product_name: device.product_name,
                serial: serial ?? device.serial,
                transport: device.transport,
                firmware: fw ?? device.firmware
            ),
            connection: "USB",
            battery_percent: battery?.0,
            charging: battery?.1,
            dpi: DpiPair(x: dpi.0, y: dpi.1),
            dpi_stages: DpiStages(active_stage: active, values: values, pairs: pairs),
            poll_rate: poll,
            sleep_timeout: sleepTimeout,
            device_mode: mode.map { DeviceMode(mode: $0.0, param: $0.1) },
            low_battery_threshold_raw: lowBatteryThreshold,
            scroll_mode: scrollMode,
            scroll_acceleration: scrollAcceleration,
            scroll_smart_reel: scrollSmartReel,
            active_onboard_profile: onboardProfile?.active,
            onboard_profile_count: onboardProfile?.count ?? max(1, device.onboard_profile_count),
            led_value: led,
            capabilities: capabilities
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
                    AppLog.warning("Bridge", "USB HID access denied device=\(device.id); Input Monitoring is required")
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
        let x = DeviceProfiles.clampDPI(dpiX, device: device)
        let y = DeviceProfiles.clampDPI(dpiY, device: device)
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
              let snapshot = parseUSBDpiStageSnapshotResponse(r, device: device)
        else {
            return nil
        }
        return snapshot
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
        stagePairs: [DpiPair]? = nil,
        stageIDs: [UInt8]? = nil
    ) throws -> Bool {
        let clippedPairs = Array((stagePairs ?? stages.map { DpiPair(x: $0, y: $0) }).prefix(5)).map { pair in
            DpiPair(
                x: DeviceProfiles.clampDPI(pair.x, device: device),
                y: DeviceProfiles.clampDPI(pair.y, device: device)
            )
        }
        guard !clippedPairs.isEmpty else { return false }
        let activeClamped = max(0, min(clippedPairs.count - 1, activeStage))
        let writeStageIDs = usbStageIDsForWrite(count: clippedPairs.count, stageIDs: stageIDs)
        guard writeStageIDs.count == clippedPairs.count else { return false }

        var args = [UInt8](repeating: 0, count: 3 + clippedPairs.count * 7)
        args[0] = 0x01
        args[1] = writeStageIDs[activeClamped]
        args[2] = UInt8(clippedPairs.count)
        var off = 3
        for (i, pair) in clippedPairs.enumerated() {
            args[off] = writeStageIDs[i]
            args[off + 1] = UInt8((pair.x >> 8) & 0xFF)
            args[off + 2] = UInt8(pair.x & 0xFF)
            args[off + 3] = UInt8((pair.y >> 8) & 0xFF)
            args[off + 4] = UInt8(pair.y & 0xFF)
            off += 7
        }

        guard let r = try perform(session, device, classID: 0x04, cmdID: 0x06, size: 0x26, args: args) else { return false }
        return r[0] == 0x02
    }

    func parseUSBDpiStageSnapshotResponse(_ response: [UInt8], device: MouseDevice? = nil) -> USBDpiStageSnapshot? {
        guard response.count >= 12, response[0] == 0x02 else { return nil }

        // USB response layout for 0x04:0x86:
        //   response[8]  = storage
        //   response[9]  = active stage ID token
        //   response[10] = stage count
        //   response[11...] = stage rows (7 bytes each)
        let activeRaw = Int(response[9])
        let count = max(1, min(5, Int(response[10])))
        var values: [Int] = []
        var pairs: [DpiPair] = []
        var stageIDs: [UInt8] = []

        for index in 0..<count {
            let offset = 11 + (index * 7)
            guard offset + 6 < response.count else { break }
            let stageID = response[offset]
            let dpiX = (Int(response[offset + 1]) << 8) | Int(response[offset + 2])
            let dpiY = (Int(response[offset + 3]) << 8) | Int(response[offset + 4])
            stageIDs.append(stageID)
            values.append(DeviceProfiles.clampDPI(dpiX, device: device))
            pairs.append(
                DpiPair(
                    x: DeviceProfiles.clampDPI(dpiX, device: device),
                    y: DeviceProfiles.clampDPI(dpiY, device: device)
                )
            )
        }

        guard !values.isEmpty else { return nil }

        while values.count < count {
            let fallback = pairs.last ?? DpiPair(x: values.last ?? 800, y: values.last ?? 800)
            values.append(fallback.x)
            pairs.append(fallback)
            stageIDs.append(stageIDs.last.map { $0 &+ 1 } ?? UInt8(stageIDs.count))
        }

        let active = usbResolveStageIndex(
            activeRaw: activeRaw,
            stageIDs: Array(stageIDs.prefix(count)),
            count: count
        )
        return (
            active: active,
            values: Array(values.prefix(count)),
            pairs: Array(pairs.prefix(count)),
            stageIDs: Array(stageIDs.prefix(count))
        )
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

    func getOnboardProfileInfo(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> (active: Int, count: Int)? {
        guard device.onboard_profile_count > 1 else { return (active: 1, count: 1) }
        guard let r = try perform(session, device, classID: 0x00, cmdID: 0x87, size: 0x00), r[0] == 0x02 else {
            return nil
        }
        let active = max(1, Int(r[8]))
        let count = max(1, Int(r[10]))
        return (active: active, count: count)
    }

    func setScrollSmartReel(_ session: USBHIDControlSession, _ device: MouseDevice, enabled: Bool) throws -> Bool {
        let args: [UInt8] = [0x01, enabled ? 0x01 : 0x00]
        guard let r = try perform(session, device, classID: 0x02, cmdID: 0x17, size: 0x02, args: args) else { return false }
        return r[0] == 0x02
    }

    func usbDeviceProfile(for device: MouseDevice) -> DeviceProfile? {
        DeviceProfiles.resolve(vendorID: device.vendor_id, productID: device.product_id, transport: device.transport)
    }

    func usbLightingLEDIDs(for device: MouseDevice, override: [UInt8]? = nil) -> [UInt8] {
        let ids = override ?? usbDeviceProfile(for: device)?.allUSBLightingLEDIDs ?? [0x01]
        return ids.isEmpty ? [0x01] : ids
    }

    func getScrollLEDBrightness(_ session: USBHIDControlSession, _ device: MouseDevice) throws -> Int? {
        var values: [Int] = []
        for ledID in usbLightingLEDIDs(for: device) {
            let args: [UInt8] = [0x01, ledID]
            guard let r = try perform(session, device, classID: 0x0F, cmdID: 0x84, size: 0x03, args: args), r[0] == 0x02 else {
                continue
            }
            values.append(Int(r[10]))
        }
        return values.max()
    }

    func setScrollLEDBrightness(_ session: USBHIDControlSession, _ device: MouseDevice, value: Int) throws -> Bool {
        let v = UInt8(max(0, min(255, value)))
        var wroteAny = false
        for ledID in usbLightingLEDIDs(for: device) {
            let args: [UInt8] = [0x01, ledID, v]
            guard let r = try perform(session, device, classID: 0x0F, cmdID: 0x04, size: 0x03, args: args), r[0] == 0x02 else {
                return false
            }
            wroteAny = true
        }
        return wroteAny
    }

    func setScrollLEDEffect(
        _ session: USBHIDControlSession,
        _ device: MouseDevice,
        effect: LightingEffectPatch,
        ledIDs: [UInt8]? = nil
    ) throws -> Bool {
        var wroteAny = false
        for ledID in usbLightingLEDIDs(for: device, override: ledIDs) {
            let args = BLEVendorProtocol.buildScrollLEDEffectArgs(effect: effect, ledID: ledID)
            guard let r = try perform(
                session,
                device,
                classID: 0x0F,
                cmdID: 0x02,
                size: UInt8(max(0, min(255, args.count))),
                args: args
            ), r[0] == 0x02 else {
                return false
            }
            wroteAny = true
        }
        return wroteAny
    }

    func writableUSBButtonSlots(for device: MouseDevice) -> [UInt8] {
        let layout = device.button_layout
        let slots = layout?.writableSlots ?? ButtonSlotDescriptor.defaults.map(\.slot)
        return slots.map { UInt8(max(0, min(255, $0))) }
    }

    func projectUSBButtonProfileToDirectLayer(
        _ session: USBHIDControlSession,
        _ device: MouseDevice,
        profile: UInt8
    ) throws -> Bool {
        let slots = writableUSBButtonSlots(for: device)
        guard !slots.isEmpty else { return false }

        for slot in slots {
            guard let block = try getButtonBindingUSBRaw(
                session,
                device,
                profile: profile,
                slot: slot,
                hypershift: 0x00
            ) else {
                return false
            }
            guard try setButtonBindingUSBRaw(
                session,
                device,
                profile: 0x00,
                slot: slot,
                hypershift: 0x00,
                functionBlock: block
            ) else {
                return false
            }
        }

        return true
    }

    func duplicateUSBButtonProfile(
        _ session: USBHIDControlSession,
        _ device: MouseDevice,
        sourceProfile: UInt8,
        targetProfile: UInt8
    ) throws -> Bool {
        let slots = writableUSBButtonSlots(for: device)
        guard !slots.isEmpty else { return false }

        for slot in slots {
            guard let block = try getButtonBindingUSBRaw(
                session,
                device,
                profile: sourceProfile,
                slot: slot,
                hypershift: 0x00
            ) else {
                return false
            }
            guard try setButtonBindingUSBRaw(
                session,
                device,
                profile: targetProfile,
                slot: slot,
                hypershift: 0x00,
                functionBlock: block
            ) else {
                return false
            }
        }

        return true
    }

    func resetUSBButtonProfile(
        _ session: USBHIDControlSession,
        _ device: MouseDevice,
        profile: UInt8
    ) throws -> Bool {
        let slots = writableUSBButtonSlots(for: device)
        guard !slots.isEmpty else { return false }

        for slot in slots {
            guard let block = ButtonBindingSupport.defaultUSBFunctionBlock(
                for: Int(slot),
                profileID: device.profile_id
            ) else {
                return false
            }
            guard try setButtonBindingUSBRaw(
                session,
                device,
                profile: profile,
                slot: slot,
                hypershift: 0x00,
                functionBlock: block
            ) else {
                return false
            }
        }

        return true
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
        turboRate: Int,
        clutchDPI: Int?,
        persistentProfile: Int,
        writePersistentLayer: Bool,
        writeDirectLayer: Bool
    ) throws -> Bool {
        guard let bindingKind = ButtonBindingKind(rawValue: kind) else { return false }
        let functionBlock = ButtonBindingSupport.buildUSBFunctionBlock(
            slot: slot,
            kind: bindingKind,
            hidKey: hidKey,
            turboEnabled: turboEnabled && bindingKind.supportsTurbo,
            turboRate: turboRate,
            clutchDPI: clutchDPI,
            profileID: device.profile_id
        )
        let clampedSlot = UInt8(max(0, min(255, slot)))

        let clampedPersistentProfile = UInt8(max(1, min(5, persistentProfile)))

        let wrotePersistent: Bool
        if writePersistentLayer {
            wrotePersistent = try setButtonBindingUSBRaw(
                session,
                device,
                profile: clampedPersistentProfile,
                slot: clampedSlot,
                hypershift: 0x00,
                functionBlock: functionBlock
            )
            guard wrotePersistent else { return false }
        } else {
            wrotePersistent = false
        }
        let wroteDirect: Bool
        if writeDirectLayer {
            wroteDirect = try setButtonBindingUSBRaw(
                session,
                device,
                profile: 0x00,
                slot: clampedSlot,
                hypershift: 0x00,
                functionBlock: functionBlock
            )
        } else {
            wroteDirect = false
        }
        return Self.usbButtonWriteSucceeded(
            writePersistentLayer: writePersistentLayer,
            writeDirectLayer: writeDirectLayer,
            wrotePersistent: wrotePersistent,
            wroteDirect: wroteDirect
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

        return ButtonBindingSupport.extractUSBFunctionBlock(
            response: response,
            profile: profile,
            slot: slot,
            hypershift: hypershift,
            profileID: device.profile_id
        )
    }
}
