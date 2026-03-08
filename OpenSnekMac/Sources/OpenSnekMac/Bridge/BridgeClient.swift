import Foundation
import IOKit.hid

actor BridgeClient {
    private var deviceHandles: [String: IOHIDDevice] = [:]
    private var txnByDeviceID: [String: UInt8] = [:]
    private var btReqID: UInt8 = 0x30
    private var btDpiSnapshotByDeviceID: [String: (active: Int, count: Int, slots: [Int], marker: UInt8)] = [:]

    private let usbVID = 0x1532
    private let btVID = 0x068E

    func listDevices() async throws -> [MouseDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDVendorIDKey: usbVID] as CFDictionary,
            [kIOHIDVendorIDKey: btVID] as CFDictionary,
        ] as CFArray)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw BridgeError.commandFailed("Unable to open IOHIDManager (\(openResult))")
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let set = IOHIDManagerCopyDevices(manager) else { return [] }
        let devices = (set as NSSet).allObjects.map { $0 as! IOHIDDevice }

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

        return result.sorted { $0.product_name < $1.product_name }
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        guard let handle = handleFor(device: device) else {
            throw BridgeError.commandFailed("Device not available")
        }

        if device.transport == "bluetooth" {
            return try await readBluetoothState(device: device, handle: handle)
        }
        return try await readUSBState(device: device, handle: handle)
    }

    func apply(device: MouseDevice, patch: DevicePatch) async throws -> MouseState {
        guard let handle = handleFor(device: device) else {
            throw BridgeError.commandFailed("Device not available")
        }

        if device.transport == "bluetooth" {
            if let stages = patch.dpiStages {
                let active = patch.activeStage ?? 0
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

            if let binding = patch.buttonBinding {
                let slot = UInt8(max(0, min(255, binding.slot)))
                let kind = binding.kind
                let hidKey = UInt8(max(0, min(255, binding.hidKey ?? 4)))
                guard try await btSetButtonBinding(slot: slot, kind: kind, hidKey: hidKey) else {
                    throw BridgeError.commandFailed("Failed to set Bluetooth button binding")
                }
            }

        } else {
            if let pollRate = patch.pollRate {
                guard try setPollRate(handle, device, value: pollRate) else {
                    throw BridgeError.commandFailed("Failed to set poll rate")
                }
            }

            if let stages = patch.dpiStages {
                let active = patch.activeStage ?? 0
                guard try setDPIStages(handle, device, stages: stages, activeStage: active) else {
                    throw BridgeError.commandFailed("Failed to set DPI stages")
                }
            }

            if let brightness = patch.ledBrightness {
                guard try setScrollLEDBrightness(handle, device, value: brightness) else {
                    throw BridgeError.commandFailed("Failed to set LED brightness")
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
        }

        return try await readState(device: device)
    }

    private func readUSBState(device: MouseDevice, handle: IOHIDDevice) async throws -> MouseState {
        let serial = try getSerial(handle, device)
        let fw = try getFirmware(handle, device)
        let mode = try getDeviceMode(handle, device)
        let battery = try getBattery(handle, device)
        let dpi = try getDPI(handle, device)
        let stages = try getDPIStages(handle, device)
        let poll = try getPollRate(handle, device)
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
            device_mode: mode.map { DeviceMode(mode: $0.0, param: $0.1) },
            led_value: led,
            capabilities: Capabilities(
                dpi_stages: stages != nil,
                poll_rate: poll != nil,
                button_remap: true,
                lighting: led != nil
            )
        )
    }

    private func readBluetoothState(device: MouseDevice, handle: IOHIDDevice) async throws -> MouseState {
        let btStages = (try? await btGetDpiStages(deviceID: device.id)) ?? nil
        let batteryRaw = (try? await btGetScalar(key: .batteryRaw, size: 1)) ?? nil
        let batteryStatus = (try? await btGetScalar(key: .batteryStatus, size: 1)) ?? nil
        let lighting = (try? await btGetScalar(key: .lightingGet, size: 1)) ?? nil

        let batteryPct: Int?
        if let batteryRaw {
            batteryPct = batteryRaw <= 100 ? batteryRaw : Int((Double(batteryRaw) / 255.0) * 100.0)
        } else {
            batteryPct = (try? getBattery(handle, device))??.0
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
            device_mode: nil,
            led_value: lighting,
            capabilities: Capabilities(
                dpi_stages: btStages != nil,
                poll_rate: false,
                button_remap: true,
                lighting: true
            )
        )
    }

    private func nextBTReq() -> UInt8 {
        defer { btReqID = btReqID &+ 1 }
        return btReqID
    }

    private func btExchange(_ writes: [Data], timeout: TimeInterval = 2.2) async throws -> [Data] {
        // Use a fresh transaction client per exchange to avoid overlapping-call continuation leaks.
        let client = BTVendorClient()
        return try await client.run(writes: writes, timeout: timeout)
    }

    private func btGetScalar(key: BLEVendorProtocol.Key, size: Int) async throws -> Int? {
        let req = nextBTReq()
        let header = BLEVendorProtocol.buildReadHeader(req: req, key: key)
        let notifies = try await btExchange([header])
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
        let notifies = try await btExchange([header, payload])
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
        let req = nextBTReq()
        let header = BLEVendorProtocol.buildReadHeader(req: req, key: .dpiStagesGet)
        let notifies = try await btExchange([header])
        guard let payload = BLEVendorProtocol.parsePayloadFrames(notifies: notifies, req: req),
              let parsed = BLEVendorProtocol.parseDpiStages(blob: payload) else {
            return nil
        }
        if let snap = BLEVendorProtocol.parseDpiStageSnapshot(blob: payload) {
            btDpiSnapshotByDeviceID[deviceID] = snap
        }
        return (active: parsed.active, values: parsed.values, marker: parsed.marker)
    }

    private func btGetDpiStageSnapshot(deviceID: String) async throws -> (active: Int, count: Int, slots: [Int], marker: UInt8)? {
        let req = nextBTReq()
        let header = BLEVendorProtocol.buildReadHeader(req: req, key: .dpiStagesGet)
        let notifies = try await btExchange([header])
        guard let payload = BLEVendorProtocol.parsePayloadFrames(notifies: notifies, req: req),
              let parsed = BLEVendorProtocol.parseDpiStageSnapshot(blob: payload) else {
            return nil
        }
        btDpiSnapshotByDeviceID[deviceID] = parsed
        return parsed
    }

    private func btSetDpiStages(deviceID: String, active: Int, values: [Int]) async throws -> Bool {
        let current: (active: Int, count: Int, slots: [Int], marker: UInt8)?
        if let cached = btDpiSnapshotByDeviceID[deviceID] {
            current = cached
        } else {
            current = try await btGetDpiStageSnapshot(deviceID: deviceID)
        }
        let marker = current?.marker ?? 0x03
        let count = max(1, min(5, values.count))
        let currentSlots = current?.slots ?? [800, 1600, 2400, 3200, 6400]
        let mergedSlots = BLEVendorProtocol.mergedStageSlots(
            currentSlots: currentSlots,
            requestedCount: count,
            requestedValues: values
        )

        let payload = BLEVendorProtocol.buildDpiStagePayload(
            active: active,
            count: count,
            slots: mergedSlots,
            marker: marker
        )
        let req = nextBTReq()
        let header = BLEVendorProtocol.buildWriteHeader(req: req, payloadLength: 0x26, key: .dpiStagesSet)
        let notifies = try await btExchange([header, payload.prefix(20), payload.suffix(from: 20)])
        let ok = btAckSuccess(notifies: notifies, req: req)
        if ok {
            btDpiSnapshotByDeviceID[deviceID] = (
                active: max(0, min(count - 1, active)),
                count: count,
                slots: mergedSlots,
                marker: marker
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
        let notifies = try await btExchange([header, payload])
        return btAckSuccess(notifies: notifies, req: req)
    }

    private func btSetButtonBinding(slot: UInt8, kind: ButtonBindingKind, hidKey: UInt8) async throws -> Bool {
        let payload = BLEVendorProtocol.buildButtonPayload(slot: slot, kind: kind, hidKey: hidKey)
        let req = nextBTReq()
        let header = BLEVendorProtocol.buildWriteHeader(req: req, payloadLength: 0x0A, key: .buttonBind(slot: slot))
        let notifies = try await btExchange([header, payload])
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

    private func getDPIStages(_ handle: IOHIDDevice, _ device: MouseDevice) throws -> (Int, [Int])? {
        guard let r = try perform(device, handle, classID: 0x04, cmdID: 0x86, size: 0x26, args: [0x01]), r[0] == 0x02 else { return nil }
        let active = Int(r[9])
        let count = max(1, min(5, Int(r[10])))
        var values: [Int] = []
        for i in 0..<count {
            let off = 11 + (i * 7)
            if off + 4 >= r.count { break }
            values.append((Int(r[off + 1]) << 8) | Int(r[off + 2]))
        }
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

    private func setButtonBindingUSB(_ handle: IOHIDDevice, _ device: MouseDevice, slot: Int, kind: String, hidKey: Int) throws -> Bool {
        let profile: UInt8 = 0x01
        let button = UInt8(max(0, min(255, slot)))
        let actionType: UInt8
        let params: [UInt8]
        switch kind {
        case "left_click":
            actionType = 0x01
            params = [0x01, 0x01]
        case "right_click":
            actionType = 0x01
            params = [0x01, 0x02]
        case "middle_click":
            actionType = 0x01
            params = [0x01, 0x03]
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
