import Foundation
import IOKit.hid

actor BridgeClient {
    private var deviceHandles: [String: IOHIDDevice] = [:]
    private var txnByDeviceID: [String: UInt8] = [:]
    private var btReqID: UInt8 = 0x30
    private var btDpiSnapshotByDeviceID: [String: (active: Int, count: Int, slots: [Int], stageIDs: [UInt8], marker: UInt8)] = [:]
    private var btExpectedDpiByDeviceID: [String: (active: Int, values: [Int], expiresAt: Date, remainingMasks: Int)] = [:]
    private let btVendorClient = BTVendorClient()
    private var btExchangeLocked = false
    private var btExchangeWaiters: [CheckedContinuation<Void, Never>] = []

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

        var result: [MouseDevice] = []
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
            result.append(model)
            deviceHandles[id] = device
        }

        let hasBluetoothDevice = result.contains(where: { $0.transport == "bluetooth" })
        if !hasBluetoothDevice, openResult == kIOReturnNotPermitted {
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
                "Enable Input Monitoring for Open Snek in System Settings, or ensure a supported Bluetooth device is connected."
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
            AppLog.debug("Bridge", "readState bt device=\(device.id) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
            return state
        }

        guard let handle = handleFor(device: device) else {
            throw BridgeError.commandFailed("Device not available")
        }
        let state = try await readUSBState(device: device, handle: handle)
        AppLog.debug("Bridge", "readState usb device=\(device.id) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        return state
    }

    func readDpiStagesFast(device: MouseDevice) async throws -> (active: Int, values: [Int])? {
        guard device.transport == "bluetooth" else { return nil }
        guard let parsed = try await btGetDpiStages(deviceID: device.id) else { return nil }
        return (active: parsed.active, values: parsed.values)
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
            guard let handle = handleFor(device: device) else {
                throw BridgeError.commandFailed("Device not available")
            }
            if let pollRate = patch.pollRate {
                guard try setPollRate(handle, device, value: pollRate) else {
                    throw BridgeError.commandFailed("Failed to set poll rate")
                }
            }

            if let timeout = patch.sleepTimeout {
                guard try setIdleTime(handle, device, seconds: timeout) else {
                    throw BridgeError.commandFailed("Failed to set sleep timeout")
                }
            }

            if patch.dpiStages != nil || patch.activeStage != nil {
                let current = try getDPIStages(handle, device)
                let stages = patch.dpiStages ?? current?.1
                let active = patch.activeStage ?? current?.0 ?? 0
                guard let stages, !stages.isEmpty else {
                    throw BridgeError.commandFailed("Failed to resolve current DPI stages")
                }
                guard try setDPIStages(handle, device, stages: stages, activeStage: active) else {
                    throw BridgeError.commandFailed("Failed to set DPI stages")
                }
                let activeClamped = max(0, min(stages.count - 1, active))
                let liveDpi = stages[activeClamped]
                _ = try? setDPI(handle, device, dpiX: liveDpi, dpiY: liveDpi, store: false)
            }

            if let brightness = patch.ledBrightness {
                guard try setScrollLEDBrightness(handle, device, value: brightness) else {
                    throw BridgeError.commandFailed("Failed to set LED brightness")
                }
            }

            if let effect = patch.lightingEffect {
                guard try setScrollLEDEffect(handle, device, effect: effect) else {
                    throw BridgeError.commandFailed("Failed to set lighting effect")
                }
            }

            if let binding = patch.buttonBinding {
                let slot = binding.slot
                let kind = binding.kind.rawValue
                let hidKey = binding.hidKey ?? 4
                guard try setButtonBindingUSB(handle, device, slot: slot, kind: kind, hidKey: hidKey) else {
                    throw BridgeError.commandFailed("Failed to set button binding")
                }
            }

            return try await readUSBState(device: device, handle: handle)
        }
    }

    private func readUSBState(device: MouseDevice, handle: IOHIDDevice) async throws -> MouseState {
        let serial = try getSerial(handle, device)
        let fw = try getFirmware(handle, device)
        let mode = try getDeviceMode(handle, device)
        let battery = try getBattery(handle, device)
        let dpi = try getDPI(handle, device)
        let stages = try getDPIStages(handle, device)
        let poll = try getPollRate(handle, device)
        let sleepTimeout = try getIdleTime(handle, device)
        let led = try getScrollLEDBrightness(handle, device)

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
            dpi: dpi.map { DpiPair(x: $0.0, y: $0.1) },
            dpi_stages: DpiStages(active_stage: stages?.0, values: stages?.1),
            poll_rate: poll,
            sleep_timeout: sleepTimeout,
            device_mode: mode.map { DeviceMode(mode: $0.0, param: $0.1) },
            led_value: led,
            capabilities: Capabilities(
                dpi_stages: stages != nil,
                poll_rate: poll != nil,
                power_management: true,
                button_remap: true,
                lighting: led != nil
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

    private func getCandidates(for device: MouseDevice) -> [UInt8] {
        if let cached = txnByDeviceID[device.id] {
            var vals: [UInt8] = [cached]
            for c: UInt8 in [0x1F, 0x3F, 0xFF] where c != cached { vals.append(c) }
            return vals
        }
        if device.vendor_id == btVID && device.product_id == 0x00BA {
            return [0x3F, 0x1F, 0xFF]
        }
        return [0x1F, 0x3F, 0xFF]
    }

    private func perform(_ device: MouseDevice, _ handle: IOHIDDevice, classID: UInt8, cmdID: UInt8, size: UInt8, args: [UInt8] = []) throws -> [UInt8]? {
        for txn in getCandidates(for: device) {
            let report = createReport(txn: txn, classID: classID, cmdID: cmdID, size: size, args: args)
            guard let response = exchange(handle: handle, report: report) else { continue }
            if response.count < 90 { continue }
            if response[0] == 0x01 { continue }
            txnByDeviceID[device.id] = txn
            return response
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

    private func exchange(handle: IOHIDDevice, report: [UInt8]) -> [UInt8]? {
        let openResult = IOHIDDeviceOpen(handle, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { return nil }
        defer { IOHIDDeviceClose(handle, IOOptionBits(kIOHIDOptionsTypeNone)) }

        var packet = [UInt8](repeating: 0, count: 91)
        packet[0] = 0x00
        for i in 0..<90 { packet[i + 1] = report[i] }

        let sendResult = packet.withUnsafeMutableBufferPointer { ptr -> IOReturn in
            guard let base = ptr.baseAddress else { return kIOReturnError }
            return IOHIDDeviceSetReport(handle, kIOHIDReportTypeFeature, CFIndex(0), base, ptr.count)
        }
        if sendResult != kIOReturnSuccess { return nil }

        for _ in 0..<7 {
            usleep(30_000)
            var out = [UInt8](repeating: 0, count: 91)
            var length = out.count
            let readResult = out.withUnsafeMutableBufferPointer { ptr -> IOReturn in
                guard let base = ptr.baseAddress else { return kIOReturnError }
                return IOHIDDeviceGetReport(handle, kIOHIDReportTypeFeature, CFIndex(0), base, &length)
            }
            if readResult != kIOReturnSuccess || length == 0 { continue }
            let data = Array(out.prefix(length))
            if data.count == 91 { return Array(data.dropFirst()) }
            if data.count == 90 { return data }
            if data.count > 90 { return Array(data.suffix(90)) }
        }
        return nil
    }

    private func getDPI(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> (Int, Int)? {
        guard let r = try perform(device, handle, classID: 0x04, cmdID: 0x85, size: 0x07, args: [0x00]), r[0] == 0x02 else { return nil }
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
        guard let r = try perform(device, handle, classID: 0x04, cmdID: 0x86, size: 0x26, args: [0x01]), r[0] == 0x02 else { return nil }
        let activeRaw = Int(r[9])
        let count = max(1, min(5, Int(r[10])))
        var values: [Int] = []
        for i in 0..<count {
            let off = 11 + (i * 7)
            if off + 4 >= r.count { break }
            let value = (Int(r[off + 1]) << 8) | Int(r[off + 2])
            values.append(value)
        }

        guard !values.isEmpty else { return nil }
        while values.count < count {
            values.append(values.last ?? 800)
        }

        let active = max(0, min(count - 1, activeRaw))
        return (active, values)
    }

    private func setDPIStages(_ handle: IOHIDDevice, _ device: MouseDevice, stages: [Int], activeStage: Int) throws -> Bool {
        let clipped = Array(stages.prefix(5)).map { max(100, min(30_000, $0)) }
        guard !clipped.isEmpty else { return false }

        var args = [UInt8](repeating: 0, count: 3 + clipped.count * 7)
        args[0] = 0x01
        args[1] = UInt8(max(0, min(clipped.count - 1, activeStage)))
        args[2] = UInt8(clipped.count)
        var off = 3
        for (i, dpi) in clipped.enumerated() {
            args[off] = UInt8(i)
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
}

enum BridgeError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let msg): return msg
        }
    }
}
