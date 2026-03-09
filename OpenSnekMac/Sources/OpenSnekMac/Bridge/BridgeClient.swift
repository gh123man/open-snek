import Foundation
import IOKit.hid

actor BridgeClient {
    private typealias USBDpiStageSnapshot = (active: Int, values: [Int], stageIDs: [UInt8])

    private var deviceHandles: [String: IOHIDDevice] = [:]
    private var deviceHandleCandidates: [String: [IOHIDDevice]] = [:]
    private var txnByDeviceID: [String: UInt8] = [:]
    private var lastStateByDeviceID: [String: MouseState] = [:]
    private var btReqID: UInt8 = 0x30
    private var btDpiSnapshotByDeviceID: [String: (active: Int, count: Int, slots: [Int], stageIDs: [UInt8], marker: UInt8)] = [:]
    private var btExpectedDpiByDeviceID: [String: (active: Int, values: [Int], expiresAt: Date, remainingMasks: Int)] = [:]
    private let btVendorClient = BTVendorClient()
    private var btExchangeLocked = false
    private var btExchangeWaiters: [CheckedContinuation<Void, Never>] = []
    private var hidAccessDenied = false
    private var managerAccessDenied = false
    private var lastOpenDeniedLogAt: Date?

    private let usbVID = 0x1532
    private let btVID = 0x068E
    private let fallbackBTPID = 0x00BA

    func listDevices() async throws -> [MouseDevice] {
        let start = Date()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDVendorIDKey: usbVID] as CFDictionary,
            [kIOHIDVendorIDKey: btVID] as CFDictionary,
        ] as CFArray)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        managerAccessDenied = openResult == kIOReturnNotPermitted
        if openResult != kIOReturnSuccess {
            AppLog.error("Bridge", "IOHIDManagerOpen failed (\(openResult)); continuing best-effort discovery")
            if openResult == kIOReturnNotPermitted {
                AppLog.error(
                    "Bridge",
                    "IOHID access not permitted; USB access may be blocked unless Input Monitoring permission is granted"
                )
            }
        }
        defer {
            if openResult == kIOReturnSuccess {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
        }

        let devices: [IOHIDDevice]
        if let set = IOHIDManagerCopyDevices(manager) {
            devices = (set as NSSet).allObjects.map { $0 as! IOHIDDevice }
        } else {
            devices = []
        }

        var modelsByID: [String: MouseDevice] = [:]
        var handlesByID: [String: [(score: Int, handle: IOHIDDevice)]] = [:]
        for device in devices {
            guard let vendor = intProp(device, key: kIOHIDVendorIDKey as CFString),
                  (vendor == usbVID || vendor == btVID),
                  let product = intProp(device, key: kIOHIDProductIDKey as CFString) else { continue }

            let name = stringProp(device, key: kIOHIDProductKey as CFString) ?? "Razer Mouse"
            let serial = stringProp(device, key: kIOHIDSerialNumberKey as CFString)
            let transportRaw = (stringProp(device, key: kIOHIDTransportKey as CFString) ?? "").lowercased()
            let transport = transportRaw.contains("bluetooth") || vendor == btVID ? "bluetooth" : "usb"
            let location = intProp(device, key: kIOHIDLocationIDKey as CFString) ?? 0
            let id = String(format: "%04x:%04x:%08x:%@", vendor, product, location, transport)

            let model = MouseDevice(
                id: id,
                vendor_id: vendor,
                product_id: product,
                product_name: name,
                transport: transport,
                path_b64: "",
                serial: serial,
                firmware: nil
            )
            if modelsByID[id] == nil {
                modelsByID[id] = model
            }

            let score = handlePreferenceScore(device: device)
            handlesByID[id, default: []].append((score: score, handle: device))
        }
        var preferredHandlesByID: [String: IOHIDDevice] = [:]
        var candidatesByID: [String: [IOHIDDevice]] = [:]
        for (id, scoredHandles) in handlesByID {
            let sorted = scoredHandles.sorted { lhs, rhs in
                if lhs.score == rhs.score { return false }
                return lhs.score > rhs.score
            }
            let handles = sorted.map(\.handle)
            candidatesByID[id] = handles
            if let first = handles.first {
                preferredHandlesByID[id] = first
            }
        }
        deviceHandleCandidates = candidatesByID
        deviceHandles = preferredHandlesByID
        var result = Array(modelsByID.values)

        let hasBluetoothDevice = result.contains(where: { $0.transport == "bluetooth" })
        if !hasBluetoothDevice, result.isEmpty, openResult == kIOReturnNotPermitted {
            do {
                _ = try await btExchange([], timeout: 0.8)
                let fallbackID = String(format: "%04x:%04x:%08x:%@", btVID, fallbackBTPID, 0, "bluetooth")
                let fallback = MouseDevice(
                    id: fallbackID,
                    vendor_id: btVID,
                    product_id: fallbackBTPID,
                    product_name: "Razer Bluetooth Mouse",
                    transport: "bluetooth",
                    path_b64: "",
                    serial: nil,
                    firmware: nil
                )
                result.append(fallback)
                AppLog.event("Bridge", "listDevices added Bluetooth fallback device after HID permission denial")
            } catch {
                AppLog.error("Bridge", "Bluetooth fallback discovery failed: \(error.localizedDescription)")
            }
        }

        let sorted = result.sorted { $0.product_name < $1.product_name }
        if sorted.isEmpty, openResult == kIOReturnNotPermitted {
            throw BridgeError.commandFailed(
                "HID access denied by macOS (kIOReturnNotPermitted). " +
                "Enable Input Monitoring for Open Snek (or Terminal/Xcode when running via swift run/Xcode), " +
                "or ensure a supported Bluetooth device is connected."
            )
        }
        AppLog.event("Bridge", "listDevices count=\(sorted.count) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        return sorted
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        let start = Date()
        if device.transport == "bluetooth" {
            let handle = handleFor(device: device)
            let state = try await readBluetoothState(device: device, handle: handle)
            lastStateByDeviceID[device.id] = state
            AppLog.debug("Bridge", "readState bt device=\(device.id) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
            return state
        }

        let candidates = handlesFor(device: device)
        guard !candidates.isEmpty else {
            if hidAccessDenied || managerAccessDenied {
                throw BridgeError.commandFailed(
                    "USB HID access denied by macOS. Enable Input Monitoring for Open Snek " +
                    "(or Terminal/Xcode when running via swift run/Xcode), then relaunch."
                )
            }
            throw BridgeError.commandFailed("Device not available")
        }
        var firstError: Error?
        for scanAttempt in 0..<2 {
            firstError = nil
            for (index, handle) in candidates.enumerated() {
                do {
                    let state = try await readUSBState(device: device, handle: handle)
                    if index > 0 {
                        deviceHandles[device.id] = handle
                        AppLog.debug("Bridge", "readState usb switched to alternate handle index=\(index) device=\(device.id)")
                    }
                    lastStateByDeviceID[device.id] = state
                    AppLog.debug("Bridge", "readState usb device=\(device.id) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
                    return state
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                    AppLog.debug("Bridge", "readState usb candidate index=\(index) failed: \(error.localizedDescription)")
                }
            }
            if scanAttempt == 0 {
                usleep(120_000)
            }
        }

        txnByDeviceID.removeValue(forKey: device.id)
        if let firstError {
            throw firstError
        }
        throw BridgeError.commandFailed("USB device telemetry unavailable")
    }

    func readDpiStagesFast(device: MouseDevice) async throws -> (active: Int, values: [Int])? {
        if device.transport == "bluetooth" {
            guard let parsed = try await btGetDpiStages(deviceID: device.id) else { return nil }
            return (active: parsed.active, values: parsed.values)
        }

        guard device.transport == "usb" else { return nil }
        let orderedHandles = handlesFor(device: device)
        guard !orderedHandles.isEmpty else { return nil }

        var firstError: Error?
        for handle in orderedHandles {
            do {
                guard let stages = try getDPIStageSnapshot(handle, device) else { continue }
                let liveDpi = try getDPI(handle, device)?.0
                let active: Int
                if let liveDpi, let exact = stages.values.firstIndex(of: liveDpi) {
                    active = exact
                } else {
                    active = stages.active
                }
                deviceHandles[device.id] = handle
                return (active: active, values: stages.values)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            throw firstError
        }
        return nil
    }

    func readLightingColor(device: MouseDevice) async throws -> RGBPatch? {
        guard device.transport == "bluetooth" else { return nil }
        let req = nextBTReq()
        let header = BLEVendorProtocol.buildReadHeader(req: req, key: .lightingFrameGet)
        let notifies = try await btExchange([header], timeout: 0.6)
        guard let payload = BLEVendorProtocol.parsePayloadFrames(notifies: notifies, req: req) else {
            AppLog.debug("Bridge", "readLightingColor no-payload device=\(device.id) notifies=\(notifies.count)")
            return nil
        }
        let parsed = parseLightingRGB(payload: payload)
        if let parsed {
            AppLog.debug("Bridge", "readLightingColor device=\(device.id) rgb=(\(parsed.r),\(parsed.g),\(parsed.b))")
        } else {
            AppLog.debug("Bridge", "readLightingColor parse-failed device=\(device.id) payload=\(payload.map { String(format: "%02x", $0) }.joined())")
        }
        return parsed
    }

    func apply(device: MouseDevice, patch: DevicePatch) async throws -> MouseState {
        if device.transport == "bluetooth" {
            let handle = handleFor(device: device)
            let changedDpi = patch.dpiStages != nil || patch.activeStage != nil
            let changedLighting = patch.ledBrightness != nil || patch.ledRGB != nil || patch.lightingEffect != nil
            let changedPower = patch.sleepTimeout != nil

            if patch.dpiStages != nil || patch.activeStage != nil {
                let current: (active: Int, count: Int, slots: [Int], stageIDs: [UInt8], marker: UInt8)?
                if let cached = btDpiSnapshotByDeviceID[device.id] {
                    current = cached
                } else {
                    current = try await btGetDpiStageSnapshot(deviceID: device.id)
                }
                guard let current else {
                    throw BridgeError.commandFailed("Failed to read current Bluetooth DPI stages")
                }
                let stages = patch.dpiStages ?? Array(current.slots.prefix(current.count))
                let active = patch.activeStage ?? current.active
                guard try await btSetDpiStages(deviceID: device.id, active: active, values: stages) else {
                    throw BridgeError.commandFailed("Failed to set Bluetooth DPI stages")
                }
            }

            if let brightness = patch.ledBrightness {
                guard try await btSetLightingValue(value: brightness) else {
                    throw BridgeError.commandFailed("Failed to set Bluetooth lighting value")
                }
            }

            if let rgb = patch.ledRGB {
                guard try await btSetLightingRGB(r: rgb.r, g: rgb.g, b: rgb.b) else {
                    throw BridgeError.commandFailed("Failed to set Bluetooth RGB")
                }
            }

            if let effect = patch.lightingEffect {
                var applied = false
                if let handle {
                    applied = try setScrollLEDEffect(handle, device, effect: effect)
                }
                if !applied {
                    applied = try await btApplyLightingEffectFallback(effect: effect)
                }
                if !applied {
                    AppLog.debug(
                        "Bridge",
                        "lighting effect fallback unavailable kind=\(effect.kind.rawValue) transport=\(device.transport)"
                    )
                }
            }

            if let binding = patch.buttonBinding {
                let slot = UInt8(max(0, min(255, binding.slot)))
                let kind = binding.kind
                let hidKey = UInt8(max(0, min(255, binding.hidKey ?? 4)))
                let turboEnabled = kind.supportsTurbo && binding.turboEnabled
                let turboRate = UInt16(max(1, min(255, binding.turboRate ?? 0x8E)))
                guard try await btSetButtonBinding(
                    slot: slot,
                    kind: kind,
                    hidKey: hidKey,
                    turboEnabled: turboEnabled,
                    turboRate: turboRate
                ) else {
                    throw BridgeError.commandFailed("Failed to set Bluetooth button binding")
                }
            }

            if let timeout = patch.sleepTimeout {
                let clamped = max(60, min(900, timeout))
                guard try await btSetScalar(
                    key: .powerTimeoutSet,
                    value: clamped,
                    size: 2,
                    payloadLength: 0x02
                ) else {
                    throw BridgeError.commandFailed("Failed to set Bluetooth sleep timeout")
                }
            }

            return try await buildBluetoothDeltaState(
                device: device,
                includeDpi: changedDpi,
                includeLighting: changedLighting,
                includePower: changedPower
            )
        } else {
            let orderedHandles = handlesFor(device: device)
            guard !orderedHandles.isEmpty else {
                if hidAccessDenied {
                    throw BridgeError.commandFailed(
                        "USB HID access denied by macOS. Enable Input Monitoring for Open Snek " +
                        "(or Terminal/Xcode when running via swift run/Xcode), then relaunch."
                    )
                }
                throw BridgeError.commandFailed("Device not available")
            }
            func runUSBWrite(_ operation: (IOHIDDevice) throws -> Bool) throws -> Bool {
                var firstError: Error?
                for handle in orderedHandles {
                    do {
                        if try operation(handle) {
                            deviceHandles[device.id] = handle
                            return true
                        }
                    } catch {
                        if firstError == nil {
                            firstError = error
                        }
                    }
                }
                if let firstError {
                    throw firstError
                }
                return false
            }

            func readUSBCurrentDpiStages() throws -> USBDpiStageSnapshot? {
                var firstError: Error?
                for handle in orderedHandles {
                    do {
                        if let current = try getDPIStageSnapshot(handle, device) {
                            deviceHandles[device.id] = handle
                            return current
                        }
                    } catch {
                        if firstError == nil {
                            firstError = error
                        }
                    }
                }
                if let firstError {
                    throw firstError
                }
                return nil
            }

            func readUSBCurrentDpi() throws -> (Int, Int)? {
                var firstError: Error?
                for handle in orderedHandles {
                    do {
                        if let current = try getDPI(handle, device) {
                            deviceHandles[device.id] = handle
                            return current
                        }
                    } catch {
                        if firstError == nil {
                            firstError = error
                        }
                    }
                }
                if let firstError {
                    throw firstError
                }
                return nil
            }

            if let mode = patch.deviceMode {
                guard try runUSBWrite({ try setDeviceMode($0, device, mode: mode.mode, param: mode.param) }) else {
                    throw BridgeError.commandFailed("Failed to set device mode")
                }
            }

            if let threshold = patch.lowBatteryThresholdRaw {
                guard try runUSBWrite({ try setLowBatteryThreshold($0, device, thresholdRaw: threshold) }) else {
                    throw BridgeError.commandFailed("Failed to set low battery threshold")
                }
            }

            if let scrollMode = patch.scrollMode {
                guard try runUSBWrite({ try setScrollMode($0, device, mode: scrollMode) }) else {
                    throw BridgeError.commandFailed("Failed to set scroll mode")
                }
            }

            if let scrollAcceleration = patch.scrollAcceleration {
                guard try runUSBWrite({ try setScrollAcceleration($0, device, enabled: scrollAcceleration) }) else {
                    throw BridgeError.commandFailed("Failed to set scroll acceleration")
                }
            }

            if let scrollSmartReel = patch.scrollSmartReel {
                guard try runUSBWrite({ try setScrollSmartReel($0, device, enabled: scrollSmartReel) }) else {
                    throw BridgeError.commandFailed("Failed to set scroll smart reel")
                }
            }

            if let pollRate = patch.pollRate {
                guard try runUSBWrite({ try setPollRate($0, device, value: pollRate) }) else {
                    throw BridgeError.commandFailed("Failed to set poll rate")
                }
            }

            if let timeout = patch.sleepTimeout {
                guard try runUSBWrite({ try setIdleTime($0, device, seconds: timeout) }) else {
                    throw BridgeError.commandFailed("Failed to set sleep timeout")
                }
            }

            if patch.dpiStages != nil || patch.activeStage != nil {
                let current = try readUSBCurrentDpiStages()
                let stages = (patch.dpiStages ?? current?.values)?.map { max(100, min(30_000, $0)) }
                let active = patch.activeStage ?? current?.active ?? 0
                let stageIDs = current?.stageIDs
                guard let stages, !stages.isEmpty else {
                    throw BridgeError.commandFailed("Failed to resolve current DPI stages")
                }
                let requiresStrictStageVerify = patch.dpiStages != nil
                let activeClamped = max(0, min(stages.count - 1, active))
                let liveDpi = stages[activeClamped]
                if stages.count == 1 {
                    // Persist single-stage intent via stage-table command when possible.
                    do {
                        _ = try runUSBWrite({
                            try setDPIStages($0, device, stages: [liveDpi], activeStage: 0, stageIDs: stageIDs)
                        })
                    } catch {
                        AppLog.debug("Bridge", "single-stage table persist failed: \(error.localizedDescription)")
                    }

                    var dpiWriteError: Error?
                    var dpiWriteAcked = false
                    var dpiWriteVerified = false
                    for _ in 0..<6 {
                        do {
                            guard try runUSBWrite({ try setDPI($0, device, dpiX: liveDpi, dpiY: liveDpi, store: false) }) else {
                                usleep(40_000)
                                continue
                            }
                            dpiWriteAcked = true
                            for _ in 0..<12 {
                                if let readback = try readUSBCurrentDpi(),
                                   readback.0 == liveDpi,
                                   readback.1 == liveDpi {
                                    dpiWriteVerified = true
                                    break
                                }
                                usleep(70_000)
                            }
                            if dpiWriteVerified {
                                break
                            }
                        } catch {
                            if dpiWriteError == nil {
                                dpiWriteError = error
                            }
                        }
                        usleep(50_000)
                    }
                    if !dpiWriteVerified {
                        if dpiWriteAcked {
                            if requiresStrictStageVerify {
                                throw BridgeError.commandFailed("Failed to verify DPI write")
                            }
                            AppLog.debug("Bridge", "single-stage dpi verify timeout live=\(liveDpi); proceeding after acked write")
                        } else {
                            if let dpiWriteError {
                                throw dpiWriteError
                            }
                            throw BridgeError.commandFailed("Failed to set DPI")
                        }
                    }
                } else {
                    var stageWriteAcked = false
                    var stageWriteVerified = false
                    var stageWriteError: Error?
                    for _ in 0..<6 {
                        do {
                            guard try runUSBWrite({
                                try setDPIStages($0, device, stages: stages, activeStage: activeClamped, stageIDs: stageIDs)
                            }) else {
                                usleep(50_000)
                                continue
                            }
                            stageWriteAcked = true

                            for _ in 0..<12 {
                                guard let readback = try readUSBCurrentDpiStages() else {
                                    usleep(70_000)
                                    continue
                                }
                                let readbackActive = max(0, min(stages.count - 1, readback.active))
                                let readbackValues = Array(readback.values.prefix(stages.count)).map { max(100, min(30_000, $0)) }
                                if readbackValues == stages && readbackActive == activeClamped {
                                    stageWriteVerified = true
                                    break
                                }
                                AppLog.debug(
                                    "Bridge",
                                    "dpi stage verify mismatch wanted=\(stages) active=\(activeClamped) " +
                                    "got=\(readbackValues) active=\(readbackActive)"
                                )
                                usleep(70_000)
                            }
                            if stageWriteVerified {
                                break
                            }
                        } catch {
                            if stageWriteError == nil {
                                stageWriteError = error
                            }
                        }
                        usleep(50_000)
                        if stageWriteVerified {
                            break
                        }
                    }
                    if !stageWriteVerified {
                        if stageWriteAcked {
                            if requiresStrictStageVerify {
                                throw BridgeError.commandFailed("Failed to verify DPI stage write")
                            }
                            AppLog.debug("Bridge", "dpi stage verify timeout active=\(activeClamped) values=\(stages); proceeding after acked write")
                        } else {
                            if let stageWriteError {
                                throw stageWriteError
                            }
                            throw BridgeError.commandFailed("Failed to set DPI stages")
                        }
                    }

                    // After stage-table commit, best-effort apply active stage DPI immediately.
                    // Some firmware reports updated table first, then lags current DPI scalar.
                    do {
                        var liveApplied = false
                        for _ in 0..<4 where !liveApplied {
                            guard try runUSBWrite({ try setDPI($0, device, dpiX: liveDpi, dpiY: liveDpi, store: false) }) else {
                                usleep(50_000)
                                continue
                            }
                            for _ in 0..<6 {
                                if let readback = try readUSBCurrentDpi(),
                                   readback.0 == liveDpi,
                                   readback.1 == liveDpi {
                                    liveApplied = true
                                    break
                                }
                                usleep(70_000)
                            }
                        }
                        if !liveApplied {
                            AppLog.debug("Bridge", "post-stage live dpi verify timeout live=\(liveDpi)")
                        }
                    } catch {
                        AppLog.debug("Bridge", "post-stage live dpi apply failed: \(error.localizedDescription)")
                    }
                }
            }

            if let brightness = patch.ledBrightness {
                guard try runUSBWrite({ try setScrollLEDBrightness($0, device, value: brightness) }) else {
                    throw BridgeError.commandFailed("Failed to set LED brightness")
                }
            }

            if let rgb = patch.ledRGB {
                let effect = LightingEffectPatch(
                    kind: .staticColor,
                    primary: RGBPatch(r: rgb.r, g: rgb.g, b: rgb.b)
                )
                guard try runUSBWrite({ try setScrollLEDEffect($0, device, effect: effect) }) else {
                    throw BridgeError.commandFailed("Failed to set LED color")
                }
            }

            if let effect = patch.lightingEffect {
                guard try runUSBWrite({ try setScrollLEDEffect($0, device, effect: effect) }) else {
                    throw BridgeError.commandFailed("Failed to set lighting effect")
                }
            }

            if let binding = patch.buttonBinding {
                let slot = binding.slot
                let kind = binding.kind.rawValue
                let hidKey = binding.hidKey ?? 4
                guard try runUSBWrite({ try setButtonBindingUSB($0, device, slot: slot, kind: kind, hidKey: hidKey) }) else {
                    throw BridgeError.commandFailed("Failed to set button binding")
                }
            }

            do {
                return try await readStateAfterUSBWrite(device: device)
            } catch {
                if let cached = lastStateByDeviceID[device.id] {
                    let projected = projectedState(from: cached, applying: patch)
                    lastStateByDeviceID[device.id] = projected
                    AppLog.debug(
                        "Bridge",
                        "usb apply readback failed; returning projected state device=\(device.id): \(error.localizedDescription)"
                    )
                    return projected
                }
                throw error
            }
        }
    }

    private func readUSBState(device: MouseDevice, handle: IOHIDDevice) async throws -> MouseState {
        if hidAccessDenied {
            throw BridgeError.commandFailed(
                "USB HID feature reports are blocked by macOS permissions. " +
                "Enable Input Monitoring for this app host and relaunch."
            )
        }

        guard let dpi = try getDPI(handle, device) else {
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

        let serial = try getSerial(handle, device)
        if hidAccessDenied {
            throw BridgeError.commandFailed(
                "USB HID feature reports are blocked by macOS permissions. " +
                "Enable Input Monitoring for this app host and relaunch."
            )
        }
        let fw = try getFirmware(handle, device)
        let mode = try getDeviceMode(handle, device)
        let battery = try getBattery(handle, device)
        let stages = try getDPIStages(handle, device)
        let poll = try getPollRate(handle, device)
        let sleepTimeout = try getIdleTime(handle, device)
        let lowBatteryThreshold = try getLowBatteryThreshold(handle, device)
        let scrollMode = try getScrollMode(handle, device)
        let scrollAcceleration = try getScrollAcceleration(handle, device)
        let scrollSmartReel = try getScrollSmartReel(handle, device)
        let led = try getScrollLEDBrightness(handle, device)
        var normalizedStages = stages
        if let stageTuple = stages {
            let values = stageTuple.1
            if !values.isEmpty {
                let allSame = values.allSatisfy { $0 == values[0] }
                // Some USB interfaces expose an unhelpful fixed stage table (often all 100).
                // Treat that as missing stage telemetry so cached values stay stable.
                if allSame && values[0] == 100 {
                    normalizedStages = nil
                }
            }
        }

        if let stageTuple = normalizedStages {
            let values = stageTuple.1
            if !values.isEmpty {
                let resolvedActive: Int
                if let exact = values.firstIndex(of: dpi.0) {
                    resolvedActive = exact
                } else {
                    let nearest = values.enumerated().min { lhs, rhs in
                        abs(lhs.element - dpi.0) < abs(rhs.element - dpi.0)
                    }?.offset ?? stageTuple.0
                    resolvedActive = nearest
                }
                normalizedStages = (max(0, min(values.count - 1, resolvedActive)), values)
            }
        }

        let noCoreTelemetry = mode == nil &&
            battery == nil &&
            normalizedStages == nil &&
            poll == nil &&
            sleepTimeout == nil &&
            lowBatteryThreshold == nil &&
            scrollMode == nil &&
            scrollAcceleration == nil &&
            scrollSmartReel == nil &&
            led == nil
        if noCoreTelemetry {
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

        AppLog.debug(
            "Bridge",
            "readUSBState core serial=\(serial ?? "nil") fw=\(fw ?? "nil") " +
            "dpi=true stages=\(stages != nil) poll=\(poll != nil) led=\(led != nil)"
        )

        return MouseState(
            device: DeviceSummary(
                id: device.id,
                product_name: device.product_name,
                serial: serial ?? device.serial,
                transport: device.transport,
                firmware: fw
            ),
            connection: "USB",
            battery_percent: battery?.0,
            charging: battery?.1,
            dpi: DpiPair(x: dpi.0, y: dpi.1),
            dpi_stages: DpiStages(active_stage: normalizedStages?.0, values: normalizedStages?.1),
            poll_rate: poll,
            sleep_timeout: sleepTimeout,
            device_mode: mode.map { DeviceMode(mode: $0.0, param: $0.1) },
            low_battery_threshold_raw: lowBatteryThreshold,
            scroll_mode: scrollMode,
            scroll_acceleration: scrollAcceleration,
            scroll_smart_reel: scrollSmartReel,
            led_value: led,
            capabilities: Capabilities(
                dpi_stages: true,
                poll_rate: true,
                power_management: true,
                button_remap: true,
                lighting: true
            )
        )
    }

    private func readBluetoothState(device: MouseDevice, handle: IOHIDDevice?) async throws -> MouseState {
        let btStages = (try? await btGetDpiStages(deviceID: device.id))
            ?? btDpiSnapshotByDeviceID[device.id].map { snapshot in
                (active: snapshot.active, values: Array(snapshot.slots.prefix(snapshot.count)), marker: snapshot.marker)
            }
        let batteryRaw = (try? await btGetScalar(key: .batteryRaw, size: 1)) ?? nil
        let batteryStatus = (try? await btGetScalar(key: .batteryStatus, size: 1)) ?? nil
        let lighting = (try? await btGetScalar(key: .lightingGet, size: 1)) ?? nil
        let sleepTimeout = (try? await btGetScalar(key: .powerTimeoutGet, size: 2)) ?? nil

        let batteryPct: Int?
        if let batteryRaw {
            batteryPct = batteryRaw <= 100 ? batteryRaw : Int((Double(batteryRaw) / 255.0) * 100.0)
        } else {
            if let handle {
                batteryPct = (try? getBattery(handle, device))??.0
            } else {
                batteryPct = nil
            }
        }

        return MouseState(
            device: DeviceSummary(
                id: device.id,
                product_name: device.product_name,
                serial: device.serial,
                transport: device.transport,
                firmware: nil
            ),
            connection: "Bluetooth",
            battery_percent: batteryPct,
            charging: batteryStatus == 1,
            dpi: {
                guard
                    let active = btStages?.active,
                    let values = btStages?.values,
                    active >= 0,
                    active < values.count
                else { return nil }
                let value = values[active]
                return DpiPair(x: value, y: value)
            }(),
            dpi_stages: DpiStages(active_stage: btStages?.active, values: btStages?.values),
            poll_rate: nil,
            sleep_timeout: sleepTimeout,
            device_mode: nil,
            led_value: lighting,
            capabilities: Capabilities(
                dpi_stages: true,
                poll_rate: false,
                power_management: true,
                button_remap: true,
                lighting: true
            )
        )
    }

    private func buildBluetoothDeltaState(
        device: MouseDevice,
        includeDpi: Bool,
        includeLighting: Bool,
        includePower: Bool
    ) async throws -> MouseState {
        let btStages: (active: Int, values: [Int], marker: UInt8)?
        if includeDpi {
            btStages = try await btGetDpiStages(deviceID: device.id)
        } else {
            btStages = nil
        }

        let lighting: Int?
        if includeLighting {
            lighting = try await btGetScalar(key: .lightingGet, size: 1)
        } else {
            lighting = nil
        }

        let sleepTimeout: Int?
        if includePower {
            sleepTimeout = try await btGetScalar(key: .powerTimeoutGet, size: 2)
        } else {
            sleepTimeout = nil
        }

        let dpiPair: DpiPair? = {
            guard
                let active = btStages?.active,
                let values = btStages?.values,
                active >= 0,
                active < values.count
            else { return nil }
            let value = values[active]
            return DpiPair(x: value, y: value)
        }()

        return MouseState(
            device: DeviceSummary(
                id: device.id,
                product_name: device.product_name,
                serial: device.serial,
                transport: device.transport,
                firmware: nil
            ),
            connection: "Bluetooth",
            battery_percent: nil,
            charging: nil,
            dpi: dpiPair,
            dpi_stages: DpiStages(active_stage: btStages?.active, values: btStages?.values),
            poll_rate: nil,
            sleep_timeout: sleepTimeout,
            device_mode: nil,
            led_value: lighting,
            capabilities: Capabilities(
                dpi_stages: true,
                poll_rate: false,
                power_management: true,
                button_remap: true,
                lighting: true
            )
        )
    }

    private func nextBTReq() -> UInt8 {
        defer { btReqID = btReqID &+ 1 }
        return btReqID
    }

    private func btExchange(_ writes: [Data], timeout: TimeInterval = 0.8) async throws -> [Data] {
        let start = Date()
        await btAcquireExchangeLock()
        defer { btReleaseExchangeLock() }

        let result = try await btVendorClient.run(writes: writes, timeout: timeout)
        AppLog.debug(
            "Bridge",
            "btExchange writes=\(writes.count) timeout=\(String(format: "%.2f", timeout))s " +
            "notifies=\(result.count) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s"
        )
        return result
    }

    private func btAcquireExchangeLock() async {
        if !btExchangeLocked {
            btExchangeLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            btExchangeWaiters.append(continuation)
        }
    }

    private func btReleaseExchangeLock() {
        if btExchangeWaiters.isEmpty {
            btExchangeLocked = false
            return
        }
        let next = btExchangeWaiters.removeFirst()
        next.resume()
    }

    private func btGetScalar(key: BLEVendorProtocol.Key, size: Int) async throws -> Int? {
        let req = nextBTReq()
        let header = BLEVendorProtocol.buildReadHeader(req: req, key: key)
        let notifies = try await btExchange([header], timeout: 0.5)
        guard let payload = BLEVendorProtocol.parsePayloadFrames(notifies: notifies, req: req), payload.count >= size else {
            return nil
        }
        return payload.prefix(size).enumerated().reduce(0) { partial, pair in
            partial | (Int(pair.element) << (pair.offset * 8))
        }
    }

    private func btSetScalar(key: BLEVendorProtocol.Key, value: Int, size: Int, payloadLength: UInt8) async throws -> Bool {
        let req = nextBTReq()
        let header = BLEVendorProtocol.buildWriteHeader(req: req, payloadLength: payloadLength, key: key)
        let payload = Data((0..<size).map { idx in UInt8((value >> (8 * idx)) & 0xFF) })
        let notifies = try await btExchange([header, payload], timeout: 0.9)
        return btAckSuccess(notifies: notifies, req: req)
    }

    private func btAckSuccess(notifies: [Data], req: UInt8) -> Bool {
        for frame in notifies {
            guard let header = BLEVendorProtocol.NotifyHeader(data: frame) else { continue }
            if header.req == req {
                return header.status == 0x02
            }
        }
        return false
    }

    private func btGetDpiStages(deviceID: String) async throws -> (active: Int, values: [Int], marker: UInt8)? {
        for attempt in 0..<2 {
            let req = nextBTReq()
            let header = BLEVendorProtocol.buildReadHeader(req: req, key: .dpiStagesGet)
            let notifies = try await btExchange([header], timeout: 0.6)
            guard let payload = BLEVendorProtocol.parsePayloadFrames(notifies: notifies, req: req),
                  let parsed = BLEVendorProtocol.parseDpiStages(blob: payload) else {
                if attempt == 0 { continue }
                return nil
            }

            guard !parsed.values.isEmpty,
                  parsed.active >= 0,
                  parsed.active < parsed.values.count,
                  parsed.values.allSatisfy({ $0 >= 100 && $0 <= 30_000 }) else {
                AppLog.debug(
                    "Bridge",
                    "btGetDpiStages ignored invalid payload device=\(deviceID) values=\(parsed.values) active=\(parsed.active) attempt=\(attempt + 1)"
                )
                if attempt == 0 { continue }
                return nil
            }

            if var expected = btExpectedDpiByDeviceID[deviceID] {
                let parsedValues = Array(parsed.values.prefix(expected.values.count))
                if parsed.active == expected.active && parsedValues == expected.values {
                    btExpectedDpiByDeviceID[deviceID] = nil
                } else if Date() < expected.expiresAt, expected.remainingMasks > 0 {
                    expected.remainingMasks -= 1
                    btExpectedDpiByDeviceID[deviceID] = expected
                    AppLog.debug(
                        "Bridge",
                        "btGetDpiStages stale-read masked device=\(deviceID) expectedActive=\(expected.active) expectedValues=\(expected.values) " +
                        "actualActive=\(parsed.active) actualValues=\(parsed.values) remainingMasks=\(expected.remainingMasks)"
                    )
                    return (active: expected.active, values: expected.values, marker: parsed.marker)
                } else {
                    btExpectedDpiByDeviceID[deviceID] = nil
                }
            }

            if let snap = BLEVendorProtocol.parseDpiStageSnapshot(blob: payload) {
                btDpiSnapshotByDeviceID[deviceID] = snap
            }
            AppLog.debug("Bridge", "btGetDpiStages device=\(deviceID) active=\(parsed.active) values=\(parsed.values)")
            return (active: parsed.active, values: parsed.values, marker: parsed.marker)
        }
        return nil
    }

    private func btGetDpiStageSnapshot(deviceID: String) async throws -> (active: Int, count: Int, slots: [Int], stageIDs: [UInt8], marker: UInt8)? {
        let req = nextBTReq()
        let header = BLEVendorProtocol.buildReadHeader(req: req, key: .dpiStagesGet)
        let notifies = try await btExchange([header], timeout: 0.6)
        guard let payload = BLEVendorProtocol.parsePayloadFrames(notifies: notifies, req: req),
              let parsed = BLEVendorProtocol.parseDpiStageSnapshot(blob: payload) else {
            return nil
        }
        btDpiSnapshotByDeviceID[deviceID] = parsed
        return parsed
    }

    private func btSetDpiStages(deviceID: String, active: Int, values: [Int]) async throws -> Bool {
        let current: (active: Int, count: Int, slots: [Int], stageIDs: [UInt8], marker: UInt8)?
        if let cached = btDpiSnapshotByDeviceID[deviceID] {
            current = cached
        } else {
            current = try await btGetDpiStageSnapshot(deviceID: deviceID)
        }
        let marker = current?.marker ?? 0x03
        let count = max(1, min(5, values.count))
        let currentSlots = current?.slots ?? [800, 1600, 2400, 3200, 6400]
        let currentStageIDs = Array((current?.stageIDs ?? [1, 2, 3, 4, 5]).prefix(5))
        let mergedSlots = BLEVendorProtocol.mergedStageSlots(
            currentSlots: currentSlots,
            requestedCount: count,
            requestedValues: values
        )

        let payload = BLEVendorProtocol.buildDpiStagePayload(
            active: active,
            count: count,
            slots: mergedSlots,
            marker: marker,
            stageIDs: currentStageIDs
        )
        let req = nextBTReq()
        let header = BLEVendorProtocol.buildWriteHeader(req: req, payloadLength: 0x26, key: .dpiStagesSet)
        let notifies = try await btExchange([header, payload.prefix(20), payload.suffix(from: 20)], timeout: 0.9)
        let ok = btAckSuccess(notifies: notifies, req: req)
        AppLog.debug("Bridge", "btSetDpiStages device=\(deviceID) reqActive=\(active) reqValues=\(values) count=\(count) ok=\(ok)")
        if ok {
            let expectedActive = max(0, min(count - 1, active))
            let expectedValues = Array(mergedSlots.prefix(count))
            btDpiSnapshotByDeviceID[deviceID] = (
                active: expectedActive,
                count: count,
                slots: mergedSlots,
                stageIDs: currentStageIDs,
                marker: marker
            )
            btExpectedDpiByDeviceID[deviceID] = (
                active: expectedActive,
                values: expectedValues,
                expiresAt: Date().addingTimeInterval(1.2),
                remainingMasks: 4
            )
        }
        return ok
    }

    private func btSetLightingValue(value: Int) async throws -> Bool {
        try await btSetScalar(key: .lightingSet, value: max(0, min(255, value)), size: 1, payloadLength: 0x01)
    }

    private func btSetLightingRGB(r: Int, g: Int, b: Int) async throws -> Bool {
        let payload = Data([
            0x04, 0x00, 0x00, 0x00,
            0x00,
            UInt8(max(0, min(255, r))),
            UInt8(max(0, min(255, g))),
            UInt8(max(0, min(255, b))),
        ])
        let req = nextBTReq()
        let header = BLEVendorProtocol.buildWriteHeader(req: req, payloadLength: 0x08, key: .lightingFrameSet)
        let notifies = try await btExchange([header, payload], timeout: 0.9)
        return btAckSuccess(notifies: notifies, req: req)
    }

    private func btSetLightingModeRaw(value: UInt32) async throws -> Bool {
        try await btSetScalar(
            key: .lightingModeSet,
            value: Int(value),
            size: 4,
            payloadLength: 0x04
        )
    }

    private func btApplyLightingEffectFallback(effect: LightingEffectPatch) async throws -> Bool {
        switch effect.kind {
        case .off:
            // On BLE-only paths, emulate "off" via brightness scalar.
            return try await btSetLightingValue(value: 0)
        case .staticColor:
            return try await btSetLightingRGB(r: effect.primary.r, g: effect.primary.g, b: effect.primary.b)
        case .spectrum:
            // Capture-backed selector key from all-lighting-modes.pcapng.
            return try await btSetLightingModeRaw(value: 0x00000008)
        case .wave, .reactive, .pulseRandom, .pulseSingle, .pulseDual:
            // No capture-backed BLE vendor selector values for these profile families yet.
            // Keep UI/app-state consistent without throwing hard errors.
            return false
        }
    }

    private func parseLightingRGB(payload: Data) -> RGBPatch? {
        guard !payload.isEmpty else { return nil }

        if payload.count >= 8, payload[0] == 0x04 {
            return RGBPatch(r: Int(payload[5]), g: Int(payload[6]), b: Int(payload[7]))
        }
        if payload.count >= 4 {
            return RGBPatch(r: Int(payload[1]), g: Int(payload[2]), b: Int(payload[3]))
        }
        return nil
    }

    private func btSetButtonBinding(
        slot: UInt8,
        kind: ButtonBindingKind,
        hidKey: UInt8,
        turboEnabled: Bool,
        turboRate: UInt16
    ) async throws -> Bool {
        let payload = BLEVendorProtocol.buildButtonPayload(
            slot: slot,
            kind: kind,
            hidKey: hidKey,
            turboEnabled: turboEnabled,
            turboRate: turboRate
        )
        let req = nextBTReq()
        let header = BLEVendorProtocol.buildWriteHeader(req: req, payloadLength: 0x0A, key: .buttonBind(slot: slot))
        let notifies = try await btExchange([header, payload], timeout: 0.9)
        return btAckSuccess(notifies: notifies, req: req)
    }

    private func handleFor(device: MouseDevice) -> IOHIDDevice? {
        deviceHandles[device.id]
    }

    private func handlesFor(device: MouseDevice) -> [IOHIDDevice] {
        if let preferred = deviceHandles[device.id] {
            let rest = (deviceHandleCandidates[device.id] ?? []).filter { $0 !== preferred }
            return [preferred] + rest
        }
        return deviceHandleCandidates[device.id] ?? []
    }

    private func defaultTxnCandidates(for device: MouseDevice) -> [UInt8] {
        if device.vendor_id == btVID && device.product_id == 0x00BA {
            return [0x3F, 0x1F, 0xFF]
        }
        return [0x1F, 0x3F, 0xFF]
    }

    private func getCandidates(for device: MouseDevice) -> [UInt8] {
        if let cached = txnByDeviceID[device.id] {
            return [cached]
        }
        return defaultTxnCandidates(for: device)
    }

    private func perform(
        _ device: MouseDevice,
        _ handle: IOHIDDevice,
        classID: UInt8,
        cmdID: UInt8,
        size: UInt8,
        args: [UInt8] = [],
        allowTxnRescan: Bool = false
    ) throws -> [UInt8]? {
        let cachedTxn = txnByDeviceID[device.id]
        for txn in getCandidates(for: device) {
            let report = createReport(txn: txn, classID: classID, cmdID: cmdID, size: size, args: args)
            guard let response = exchange(handle: handle, report: report, expectedClassID: classID, expectedCmdID: cmdID) else {
                if hidAccessDenied { break }
                continue
            }
            if response.count < 90 { continue }
            if response[0] == 0x01 { continue }
            txnByDeviceID[device.id] = txn
            return response
        }

        if allowTxnRescan, let cachedTxn {
            for txn in defaultTxnCandidates(for: device) where txn != cachedTxn {
                let report = createReport(txn: txn, classID: classID, cmdID: cmdID, size: size, args: args)
                guard let response = exchange(handle: handle, report: report, expectedClassID: classID, expectedCmdID: cmdID) else {
                    if hidAccessDenied { break }
                    continue
                }
                if response.count < 90 { continue }
                if response[0] == 0x01 { continue }
                txnByDeviceID[device.id] = txn
                return response
            }
        }

        if allowTxnRescan {
            txnByDeviceID.removeValue(forKey: device.id)
        }
        return nil
    }

    private func createReport(txn: UInt8, classID: UInt8, cmdID: UInt8, size: UInt8, args: [UInt8]) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 90)
        report[0] = 0x00
        report[1] = txn
        report[5] = size
        report[6] = classID
        report[7] = cmdID
        for (idx, b) in args.prefix(80).enumerated() {
            report[8 + idx] = b
        }
        var crc: UInt8 = 0
        for i in 2..<88 { crc ^= report[i] }
        report[88] = crc
        return report
    }

    private func exchange(
        handle: IOHIDDevice,
        report: [UInt8],
        expectedClassID: UInt8,
        expectedCmdID: UInt8
    ) -> [UInt8]? {
        let openResult = IOHIDDeviceOpen(handle, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            if openResult == kIOReturnNotPermitted {
                hidAccessDenied = true
                let now = Date()
                if lastOpenDeniedLogAt == nil || now.timeIntervalSince(lastOpenDeniedLogAt!) > 2.0 {
                    AppLog.debug("Bridge", "IOHIDDeviceOpen denied (\(openResult))")
                    lastOpenDeniedLogAt = now
                }
            } else {
                AppLog.debug("Bridge", "IOHIDDeviceOpen failed (\(openResult))")
            }
            return nil
        }
        hidAccessDenied = false
        defer { IOHIDDeviceClose(handle, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let sendResult = report.withUnsafeBufferPointer { ptr -> IOReturn in
            guard let base = ptr.baseAddress else { return kIOReturnError }
            return IOHIDDeviceSetReport(handle, kIOHIDReportTypeFeature, CFIndex(0), base, ptr.count)
        }
        if sendResult != kIOReturnSuccess {
            AppLog.debug("Bridge", "IOHIDDeviceSetReport failed (\(sendResult)) len=\(report.count)")
            return nil
        }

        var lastReadResult: IOReturn = kIOReturnSuccess
        for _ in 0..<6 {
            usleep(30_000)
            var out = [UInt8](repeating: 0, count: 90)
            var length = out.count
            let readResult = out.withUnsafeMutableBufferPointer { ptr -> IOReturn in
                guard let base = ptr.baseAddress else { return kIOReturnError }
                return IOHIDDeviceGetReport(handle, kIOHIDReportTypeFeature, CFIndex(0), base, &length)
            }
            lastReadResult = readResult
            if readResult != kIOReturnSuccess || length == 0 { continue }
            let data = Array(out.prefix(length))
            let candidate: [UInt8]
            if data.count == 91 {
                candidate = Array(data.dropFirst())
            } else if data.count == 90 {
                candidate = data
            } else if data.count > 90 {
                candidate = Array(data.suffix(90))
            } else {
                continue
            }
            // Some interfaces report back the request frame first (status 0x00).
            // Ignore that echo and keep polling for the actual response status.
            if candidate[0] == 0x00 {
                continue
            }
            if !isValidResponse(candidate, classID: expectedClassID, cmdID: expectedCmdID) {
                AppLog.debug(
                    "Bridge",
                    "usb response skipped expect=0x\(String(expectedClassID, radix: 16))/0x\(String(expectedCmdID, radix: 16)) " +
                    "got=0x\(String(candidate[6], radix: 16))/0x\(String(candidate[7], radix: 16)) status=0x\(String(candidate[0], radix: 16))"
                )
                continue
            }
            return candidate
        }
        AppLog.debug(
            "Bridge",
            "IOHIDDeviceGetReport timed out/failed expect=0x\(String(expectedClassID, radix: 16))/0x\(String(expectedCmdID, radix: 16)) last=\(lastReadResult)"
        )
        return nil
    }

    private func isValidResponse(_ response: [UInt8], classID: UInt8, cmdID: UInt8) -> Bool {
        guard response.count >= 90 else { return false }
        guard response[6] == classID else { return false }
        // On macOS HID paths some firmware/hubs mirror command direction bit differently.
        guard (response[7] & 0x7F) == (cmdID & 0x7F) else { return false }

        var crc: UInt8 = 0
        for i in 2..<88 {
            crc ^= response[i]
        }
        return response[88] == crc
    }

    private func getDPI(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> (Int, Int)? {
        guard let r = try perform(device, handle, classID: 0x04, cmdID: 0x85, size: 0x07, args: [0x00], allowTxnRescan: true), r[0] == 0x02 else { return nil }
        return (Int(r[9]) << 8 | Int(r[10]), Int(r[11]) << 8 | Int(r[12]))
    }

    private func setDPI(_ handle: IOHIDDevice, _ device: MouseDevice, dpiX: Int, dpiY: Int, store: Bool) throws -> Bool {
        let x = max(100, min(30_000, dpiX))
        let y = max(100, min(30_000, dpiY))
        let storage: UInt8 = store ? 0x01 : 0x00
        let args: [UInt8] = [
            storage,
            UInt8((x >> 8) & 0xFF),
            UInt8(x & 0xFF),
            UInt8((y >> 8) & 0xFF),
            UInt8(y & 0xFF),
            0x00,
            0x00,
        ]
        guard let r = try perform(device, handle, classID: 0x04, cmdID: 0x05, size: 0x07, args: args) else { return false }
        return r[0] == 0x02
    }

    private func getDPIStages(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> (Int, [Int])? {
        guard let snapshot = try getDPIStageSnapshot(handle, device) else { return nil }
        return (snapshot.active, snapshot.values)
    }

    private func getDPIStageSnapshot(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> USBDpiStageSnapshot? {
        guard let r = try perform(device, handle, classID: 0x04, cmdID: 0x86, size: 0x26, args: [0x01]), r[0] == 0x02 else { return nil }
        let activeRaw = Int(r[9])
        let count = max(1, min(5, Int(r[10])))
        var values: [Int] = []
        var stageIDs: [UInt8] = []
        for i in 0..<count {
            let off = 11 + (i * 7)
            if off + 4 >= r.count { break }
            stageIDs.append(r[off])
            let valueRaw = (Int(r[off + 1]) << 8) | Int(r[off + 2])
            let value = max(100, min(30_000, valueRaw))
            values.append(value)
        }

        guard !values.isEmpty else { return nil }
        let wantsZeroBaseIDs = stageIDs.first == 0
        while values.count < count {
            values.append(values.last ?? 800)
        }
        while stageIDs.count < count {
            let next = wantsZeroBaseIDs ? stageIDs.count : stageIDs.count + 1
            stageIDs.append(UInt8(next & 0xFF))
        }

        let active = usbResolveStageIndex(activeRaw: activeRaw, stageIDs: stageIDs, count: count)
        return (active: active, values: values, stageIDs: stageIDs)
    }

    private func usbResolveStageIndex(activeRaw: Int, stageIDs: [UInt8], count: Int) -> Int {
        guard count > 0 else { return 0 }

        if let idx = stageIDs.firstIndex(where: { Int($0) == activeRaw }) {
            return idx
        }
        if activeRaw >= 1 && activeRaw <= count {
            return activeRaw - 1
        }
        if activeRaw >= 0 && activeRaw < count {
            return activeRaw
        }
        return max(0, min(count - 1, activeRaw))
    }

    private func usbStageIDsForWrite(count: Int, stageIDs: [UInt8]?) -> [UInt8] {
        guard count > 0 else { return [] }
        if stageIDs == nil {
            return (0..<count).map { UInt8($0 + 1) }
        }

        var ids = Array((stageIDs ?? []).prefix(count))
        let wantsZeroBase = ids.first == 0
        if ids.isEmpty {
            ids.append(UInt8(wantsZeroBase ? 0 : 1))
        }
        var next = Int(ids.last ?? UInt8(wantsZeroBase ? 0 : 1)) + 1
        while ids.count < count {
            ids.append(UInt8(next & 0xFF))
            next += 1
        }
        return ids
    }

    private func setDPIStages(
        _ handle: IOHIDDevice,
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

        guard let r = try perform(device, handle, classID: 0x04, cmdID: 0x06, size: 0x26, args: args) else { return false }
        return r[0] == 0x02
    }

    private func getPollRate(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> Int? {
        guard let r = try perform(device, handle, classID: 0x00, cmdID: 0x85, size: 0x01), r[0] == 0x02 else { return nil }
        switch r[8] {
        case 0x01: return 1000
        case 0x02: return 500
        case 0x08: return 125
        default: return nil
        }
    }

    private func setPollRate(_ handle: IOHIDDevice, _ device: MouseDevice, value: Int) throws -> Bool {
        let raw: UInt8
        switch value {
        case 1000: raw = 0x01
        case 500: raw = 0x02
        case 125: raw = 0x08
        default: return false
        }
        guard let r = try perform(device, handle, classID: 0x00, cmdID: 0x05, size: 0x01, args: [raw]) else { return false }
        return r[0] == 0x02
    }

    private func getIdleTime(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> Int? {
        guard let r = try perform(device, handle, classID: 0x07, cmdID: 0x83, size: 0x02), r[0] == 0x02 else { return nil }
        return (Int(r[8]) << 8) | Int(r[9])
    }

    private func setIdleTime(_ handle: IOHIDDevice, _ device: MouseDevice, seconds: Int) throws -> Bool {
        let clamped = max(60, min(900, seconds))
        let args: [UInt8] = [UInt8((clamped >> 8) & 0xFF), UInt8(clamped & 0xFF)]
        guard let r = try perform(device, handle, classID: 0x07, cmdID: 0x03, size: 0x02, args: args) else { return false }
        return r[0] == 0x02
    }

    private func getBattery(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> (Int, Bool)? {
        guard let r = try perform(device, handle, classID: 0x07, cmdID: 0x80, size: 0x02), r[0] == 0x02 else { return nil }
        let charging = r[8] == 0x01
        let pct = Int((Double(r[9]) / 255.0) * 100.0)
        return (pct, charging)
    }

    private func getSerial(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> String? {
        guard let r = try perform(device, handle, classID: 0x00, cmdID: 0x82, size: 0x16), r[0] == 0x02 else { return nil }
        let raw = Data(r[8..<30])
        let s = String(data: raw, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        return s?.isEmpty == false ? s : nil
    }

    private func getFirmware(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> String? {
        guard let r = try perform(device, handle, classID: 0x00, cmdID: 0x81, size: 0x02), r[0] == 0x02 else { return nil }
        return "\(r[8]).\(r[9])"
    }

    private func getDeviceMode(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> (Int, Int)? {
        guard let r = try perform(device, handle, classID: 0x00, cmdID: 0x84, size: 0x02), r[0] == 0x02 else { return nil }
        return (Int(r[8]), Int(r[9]))
    }

    private func setDeviceMode(_ handle: IOHIDDevice, _ device: MouseDevice, mode: Int, param: Int = 0x00) throws -> Bool {
        let modeRaw: UInt8 = mode == 0x03 ? 0x03 : 0x00
        let args: [UInt8] = [modeRaw, UInt8(param & 0xFF)]
        guard let r = try perform(device, handle, classID: 0x00, cmdID: 0x04, size: 0x02, args: args) else { return false }
        return r[0] == 0x02
    }

    private func getLowBatteryThreshold(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> Int? {
        guard let r = try perform(device, handle, classID: 0x07, cmdID: 0x81, size: 0x01), r[0] == 0x02 else { return nil }
        return Int(r[8])
    }

    private func setLowBatteryThreshold(_ handle: IOHIDDevice, _ device: MouseDevice, thresholdRaw: Int) throws -> Bool {
        let clamped = UInt8(max(0x0C, min(0x3F, thresholdRaw)))
        guard let r = try perform(device, handle, classID: 0x07, cmdID: 0x01, size: 0x01, args: [clamped]) else { return false }
        return r[0] == 0x02
    }

    private func getScrollMode(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> Int? {
        let args: [UInt8] = [0x01, 0x00]
        guard let r = try perform(device, handle, classID: 0x02, cmdID: 0x94, size: 0x02, args: args), r[0] == 0x02 else { return nil }
        return Int(r[9])
    }

    private func setScrollMode(_ handle: IOHIDDevice, _ device: MouseDevice, mode: Int) throws -> Bool {
        let modeRaw: UInt8 = mode == 1 ? 0x01 : 0x00
        let args: [UInt8] = [0x01, modeRaw]
        guard let r = try perform(device, handle, classID: 0x02, cmdID: 0x14, size: 0x02, args: args) else { return false }
        return r[0] == 0x02
    }

    private func getScrollAcceleration(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> Bool? {
        let args: [UInt8] = [0x01, 0x00]
        guard let r = try perform(device, handle, classID: 0x02, cmdID: 0x96, size: 0x02, args: args), r[0] == 0x02 else { return nil }
        return r[9] != 0
    }

    private func setScrollAcceleration(_ handle: IOHIDDevice, _ device: MouseDevice, enabled: Bool) throws -> Bool {
        let args: [UInt8] = [0x01, enabled ? 0x01 : 0x00]
        guard let r = try perform(device, handle, classID: 0x02, cmdID: 0x16, size: 0x02, args: args) else { return false }
        return r[0] == 0x02
    }

    private func getScrollSmartReel(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> Bool? {
        let args: [UInt8] = [0x01, 0x00]
        guard let r = try perform(device, handle, classID: 0x02, cmdID: 0x97, size: 0x02, args: args), r[0] == 0x02 else { return nil }
        return r[9] != 0
    }

    private func setScrollSmartReel(_ handle: IOHIDDevice, _ device: MouseDevice, enabled: Bool) throws -> Bool {
        let args: [UInt8] = [0x01, enabled ? 0x01 : 0x00]
        guard let r = try perform(device, handle, classID: 0x02, cmdID: 0x17, size: 0x02, args: args) else { return false }
        return r[0] == 0x02
    }

    private func getScrollLEDBrightness(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> Int? {
        let args: [UInt8] = [0x01, 0x01]
        guard let r = try perform(device, handle, classID: 0x0F, cmdID: 0x84, size: 0x03, args: args), r[0] == 0x02 else { return nil }
        return Int(r[10])
    }

    private func setScrollLEDBrightness(_ handle: IOHIDDevice, _ device: MouseDevice, value: Int) throws -> Bool {
        let v = UInt8(max(0, min(255, value)))
        let args: [UInt8] = [0x01, 0x01, v]
        guard let r = try perform(device, handle, classID: 0x0F, cmdID: 0x04, size: 0x03, args: args) else { return false }
        return r[0] == 0x02
    }

    private func setScrollLEDEffect(_ handle: IOHIDDevice, _ device: MouseDevice, effect: LightingEffectPatch) throws -> Bool {
        let args = BLEVendorProtocol.buildScrollLEDEffectArgs(effect: effect)
        guard let r = try perform(
            device,
            handle,
            classID: 0x0F,
            cmdID: 0x02,
            size: UInt8(max(0, min(255, args.count))),
            args: args
        ) else { return false }
        return r[0] == 0x02
    }

    private func setButtonBindingUSB(_ handle: IOHIDDevice, _ device: MouseDevice, slot: Int, kind: String, hidKey: Int) throws -> Bool {
        let profile: UInt8 = 0x01
        let button = UInt8(max(0, min(255, slot)))
        let actionType: UInt8
        let params: [UInt8]
        switch kind {
        case "default":
            switch slot {
            case 1:
                actionType = 0x01
                params = [0x01, 0x01]
            case 2:
                actionType = 0x01
                params = [0x01, 0x02]
            case 3:
                actionType = 0x01
                params = [0x01, 0x03]
            case 4:
                actionType = 0x01
                params = [0x01, 0x04]
            case 5:
                actionType = 0x01
                params = [0x01, 0x05]
            case 9:
                actionType = 0x01
                params = [0x01, 0x09]
            case 10:
                actionType = 0x01
                params = [0x01, 0x0A]
            case 96:
                // Capture-backed DPI cycle default payload pattern.
                actionType = 0x06
                params = [0x01, 0x06]
            default:
                actionType = 0x01
                params = []
            }
        case "left_click":
            actionType = 0x01
            params = [0x01, 0x01]
        case "right_click":
            actionType = 0x01
            params = [0x01, 0x02]
        case "middle_click":
            actionType = 0x01
            params = [0x01, 0x03]
        case "scroll_up":
            actionType = 0x01
            params = [0x01, 0x09]
        case "scroll_down":
            actionType = 0x01
            params = [0x01, 0x0A]
        case "mouse_back":
            actionType = 0x01
            params = [0x01, 0x04]
        case "mouse_forward":
            actionType = 0x01
            params = [0x01, 0x05]
        case "keyboard_simple":
            actionType = 0x02
            params = [0x02, 0x00, UInt8(max(0, min(255, hidKey))), 0x00]
        case "clear_layer":
            actionType = 0x00
            params = [0x00, 0x00]
        default:
            actionType = 0x01
            params = []
        }

        var args: [UInt8] = [profile, button, 0x00, 0x00, 0x00, actionType, UInt8(params.count)]
        args.append(contentsOf: params)
        guard let r = try perform(device, handle, classID: 0x02, cmdID: 0x0D, size: UInt8(args.count), args: args) else { return false }
        return r[0] == 0x02
    }

    private func intProp(_ device: IOHIDDevice, key: CFString) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key) else { return nil }
        if CFGetTypeID(value) == CFNumberGetTypeID() { return (value as! NSNumber).intValue }
        return nil
    }

    private func stringProp(_ device: IOHIDDevice, key: CFString) -> String? {
        guard let value = IOHIDDeviceGetProperty(device, key) else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() { return value as? String }
        return nil
    }

    private func handlePreferenceScore(device: IOHIDDevice) -> Int {
        let maxFeatureReport = intProp(device, key: kIOHIDMaxFeatureReportSizeKey as CFString) ?? 0
        let usagePage = intProp(device, key: kIOHIDPrimaryUsagePageKey as CFString) ?? 0
        let usage = intProp(device, key: kIOHIDPrimaryUsageKey as CFString) ?? 0

        var score = 0
        // Prefer interfaces that advertise full 90-byte feature report support.
        if maxFeatureReport >= 90 {
            score += 100
        } else if maxFeatureReport > 0 {
            score += maxFeatureReport
        }
        // Mouse collections are usually the right control plane over USB.
        if usagePage == 0x01 && usage == 0x02 {
            score += 25
        }
        return score
    }

    private func readStateAfterUSBWrite(device: MouseDevice, attempts: Int = 4) async throws -> MouseState {
        var firstError: Error?
        let totalAttempts = max(1, attempts)
        for attempt in 0..<totalAttempts {
            do {
                return try await readState(device: device)
            } catch {
                if firstError == nil {
                    firstError = error
                }
                AppLog.debug(
                    "Bridge",
                    "usb post-write readback attempt \(attempt + 1)/\(totalAttempts) failed device=\(device.id): \(error.localizedDescription)"
                )
                if attempt + 1 < totalAttempts {
                    let backoffMs = UInt64(120 + (attempt * 120))
                    try? await Task.sleep(nanoseconds: backoffMs * 1_000_000)
                }
            }
        }
        throw firstError ?? BridgeError.commandFailed("USB readback failed after apply")
    }

    private func projectedState(from base: MouseState, applying patch: DevicePatch) -> MouseState {
        let nextValues = patch.dpiStages ?? base.dpi_stages.values
        let requestedActive = patch.activeStage ?? base.dpi_stages.active_stage

        let resolvedActive: Int?
        if let values = nextValues, !values.isEmpty {
            resolvedActive = max(0, min(values.count - 1, requestedActive ?? 0))
        } else {
            resolvedActive = requestedActive
        }

        let nextDpi: DpiPair?
        if let values = nextValues, !values.isEmpty {
            let activeIndex = max(0, min(values.count - 1, resolvedActive ?? 0))
            let value = values[activeIndex]
            nextDpi = DpiPair(x: value, y: value)
        } else {
            nextDpi = base.dpi
        }

        return MouseState(
            device: base.device,
            connection: base.connection,
            battery_percent: base.battery_percent,
            charging: base.charging,
            dpi: nextDpi,
            dpi_stages: DpiStages(active_stage: resolvedActive, values: nextValues),
            poll_rate: patch.pollRate ?? base.poll_rate,
            sleep_timeout: patch.sleepTimeout ?? base.sleep_timeout,
            device_mode: patch.deviceMode ?? base.device_mode,
            low_battery_threshold_raw: patch.lowBatteryThresholdRaw ?? base.low_battery_threshold_raw,
            scroll_mode: patch.scrollMode ?? base.scroll_mode,
            scroll_acceleration: patch.scrollAcceleration ?? base.scroll_acceleration,
            scroll_smart_reel: patch.scrollSmartReel ?? base.scroll_smart_reel,
            led_value: patch.ledBrightness ?? base.led_value,
            capabilities: base.capabilities
        )
    }
}

enum BridgeError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let msg): return msg
        }
    }
}
