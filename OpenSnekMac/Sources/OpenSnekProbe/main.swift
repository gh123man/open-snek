import Foundation
import CoreBluetooth
import IOKit.hid

private enum ProbeError: LocalizedError {
    case usage(String)
    case protocolError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .usage(let text): return text
        case .protocolError(let text): return text
        case .timeout: return "Operation timed out"
        }
    }
}

private struct DpiSnapshot: Equatable {
    let active: Int
    let count: Int
    let slots: [Int]
    let stageIDs: [UInt8]
    let marker: UInt8

    var values: [Int] { Array(slots.prefix(count)) }
}

private final class USBProbeClient {
    private let usbVID = 0x1532
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let deviceID: String
    private let productID: Int
    private var cachedTxn: UInt8?

    init() throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: usbVID] as CFDictionary)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw ProbeError.protocolError("IOHIDManagerOpen failed (\(openResult))")
        }

        guard
            let rawSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
            !rawSet.isEmpty
        else {
            throw ProbeError.protocolError("No USB Razer HID device found")
        }

        var best: (score: Int, device: IOHIDDevice, id: String, pid: Int)?
        for candidate in rawSet {
            guard
                Self.intProp(candidate, key: kIOHIDVendorIDKey as CFString) == usbVID,
                let product = Self.intProp(candidate, key: kIOHIDProductIDKey as CFString)
            else { continue }
            let transport = (Self.stringProp(candidate, key: kIOHIDTransportKey as CFString) ?? "").lowercased()
            if transport.contains("bluetooth") { continue }

            let location = Self.intProp(candidate, key: kIOHIDLocationIDKey as CFString) ?? 0
            let id = String(format: "%04x:%04x:%08x:usb", usbVID, product, location)
            let score = Self.handleScore(candidate)
            if best == nil || score > best!.score {
                best = (score: score, device: candidate, id: id, pid: product)
            }
        }

        guard let best else {
            throw ProbeError.protocolError("No non-Bluetooth USB Razer HID control interface found")
        }

        self.manager = manager
        self.device = best.device
        self.deviceID = best.id
        self.productID = best.pid
    }

    func describe() -> String {
        "\(deviceID) pid=0x\(String(productID, radix: 16))"
    }

    func readButtonFunction(profile: UInt8, slot: UInt8, hypershift: UInt8 = 0x00) throws -> [UInt8]? {
        var args: [UInt8] = [profile, slot, hypershift]
        args.append(contentsOf: [UInt8](repeating: 0x00, count: 7))
        guard let response = try perform(
            classID: 0x02,
            cmdID: 0x8C,
            size: UInt8(args.count),
            args: args,
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

    func writeButtonFunction(profile: UInt8, slot: UInt8, hypershift: UInt8 = 0x00, functionBlock: [UInt8]) throws -> Bool {
        guard functionBlock.count == 7 else {
            throw ProbeError.usage("Function block must be exactly 7 bytes")
        }
        let args = [profile, slot, hypershift] + functionBlock
        guard let response = try perform(
            classID: 0x02,
            cmdID: 0x0C,
            size: UInt8(args.count),
            args: args,
            responseAttempts: 12,
            responseDelayUs: 40_000
        ) else {
            return false
        }
        return response[0] == 0x02
    }

    func writeButtonBinding(
        profiles: [UInt8],
        slot: Int,
        kind: String,
        hidKey: Int,
        turboEnabled: Bool,
        turboRate: Int
    ) throws -> Bool {
        let functionBlock = usbButtonFunctionBlock(
            slot: slot,
            kind: kind,
            hidKey: hidKey,
            turboEnabled: turboEnabled,
            turboRate: turboRate
        )
        let clampedSlot = UInt8(max(0, min(255, slot)))
        var wroteAny = false
        for profile in profiles {
            if try writeButtonFunction(profile: profile, slot: clampedSlot, functionBlock: functionBlock) {
                wroteAny = true
            }
        }
        return wroteAny
    }

    func usbButtonFunctionBlock(
        slot: Int,
        kind: String,
        hidKey: Int,
        turboEnabled: Bool,
        turboRate: Int
    ) -> [UInt8] {
        let key = UInt8(max(0, min(255, hidKey)))
        let turbo = UInt16(max(1, min(255, turboRate)))
        let turboHi = UInt8((turbo >> 8) & 0xFF)
        let turboLo = UInt8(turbo & 0xFF)

        switch kind {
        case "default":
            if slot == 96 {
                return [0x06, 0x01, 0x06, 0x00, 0x00, 0x00, 0x00]
            }
            if let buttonID = usbDefaultMouseButtonID(slot: slot) {
                return [0x01, 0x01, buttonID, 0x00, 0x00, 0x00, 0x00]
            }
            return [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        case "clear_layer":
            return [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        case "keyboard_simple":
            if turboEnabled {
                return [0x0D, 0x04, 0x00, key, turboHi, turboLo, 0x00]
            }
            return [0x02, 0x02, 0x00, key, 0x00, 0x00, 0x00]
        default:
            if let buttonID = usbMouseButtonID(kind: kind) {
                if turboEnabled {
                    return [0x0E, 0x03, buttonID, turboHi, turboLo, 0x00, 0x00]
                }
                return [0x01, 0x01, buttonID, 0x00, 0x00, 0x00, 0x00]
            }
            return [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        }
    }

    private func usbMouseButtonID(kind: String) -> UInt8? {
        switch kind {
        case "left_click": return 0x01
        case "right_click": return 0x02
        case "middle_click": return 0x03
        case "mouse_back": return 0x04
        case "mouse_forward": return 0x05
        case "scroll_up": return 0x09
        case "scroll_down": return 0x0A
        default: return nil
        }
    }

    private func usbDefaultMouseButtonID(slot: Int) -> UInt8? {
        switch slot {
        case 1: return 0x01
        case 2: return 0x02
        case 3: return 0x03
        case 4: return 0x04
        case 5: return 0x05
        case 9: return 0x09
        case 10: return 0x0A
        default: return nil
        }
    }

    private func perform(
        classID: UInt8,
        cmdID: UInt8,
        size: UInt8,
        args: [UInt8],
        responseAttempts: Int,
        responseDelayUs: useconds_t
    ) throws -> [UInt8]? {
        for txn in txnCandidates() {
            let report = createReport(txn: txn, classID: classID, cmdID: cmdID, size: size, args: args)
            guard let response = try exchange(
                report: report,
                expectedClassID: classID,
                expectedCmdID: cmdID,
                responseAttempts: responseAttempts,
                responseDelayUs: responseDelayUs
            ) else {
                continue
            }
            if response.count < 90 { continue }
            if response[0] == 0x01 { continue }
            cachedTxn = txn
            return response
        }
        cachedTxn = nil
        return nil
    }

    private func txnCandidates() -> [UInt8] {
        if let cachedTxn {
            return [cachedTxn]
        }
        return [0x1F, 0x3F, 0xFF]
    }

    private func createReport(txn: UInt8, classID: UInt8, cmdID: UInt8, size: UInt8, args: [UInt8]) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 90)
        report[0] = 0x00
        report[1] = txn
        report[5] = size
        report[6] = classID
        report[7] = cmdID
        for (idx, value) in args.prefix(80).enumerated() {
            report[8 + idx] = value
        }
        var crc: UInt8 = 0
        for idx in 2..<88 {
            crc ^= report[idx]
        }
        report[88] = crc
        return report
    }

    private func exchange(
        report: [UInt8],
        expectedClassID: UInt8,
        expectedCmdID: UInt8,
        responseAttempts: Int,
        responseDelayUs: useconds_t
    ) throws -> [UInt8]? {
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            if openResult == kIOReturnNotPermitted {
                throw ProbeError.protocolError("USB HID access denied. Grant Input Monitoring and relaunch.")
            }
            return nil
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let setResult = report.withUnsafeBufferPointer { ptr -> IOReturn in
            guard let base = ptr.baseAddress else { return kIOReturnError }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(0), base, ptr.count)
        }
        guard setResult == kIOReturnSuccess else {
            return nil
        }

        for _ in 0..<max(1, responseAttempts) {
            usleep(responseDelayUs)
            var out = [UInt8](repeating: 0, count: 90)
            var length = out.count
            let getResult = out.withUnsafeMutableBufferPointer { ptr -> IOReturn in
                guard let base = ptr.baseAddress else { return kIOReturnError }
                return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(0), base, &length)
            }
            guard getResult == kIOReturnSuccess, length > 0 else { continue }

            let raw = Array(out.prefix(length))
            let candidate: [UInt8]
            if raw.count == 91 {
                candidate = Array(raw.dropFirst())
            } else if raw.count == 90 {
                candidate = raw
            } else if raw.count > 90 {
                candidate = Array(raw.suffix(90))
            } else {
                continue
            }

            if candidate[0] == 0x00 { continue }
            if !isValidResponse(candidate, classID: expectedClassID, cmdID: expectedCmdID) { continue }
            return candidate
        }
        return nil
    }

    private func isValidResponse(_ report: [UInt8], classID: UInt8, cmdID: UInt8) -> Bool {
        guard report.count >= 90 else { return false }
        guard report[6] == classID else { return false }
        guard (report[7] & 0x7F) == (cmdID & 0x7F) else { return false }
        var crc: UInt8 = 0
        for idx in 2..<88 {
            crc ^= report[idx]
        }
        return report[88] == crc
    }

    private static func handleScore(_ device: IOHIDDevice) -> Int {
        let maxFeatureReport = intProp(device, key: kIOHIDMaxFeatureReportSizeKey as CFString) ?? 0
        let usagePage = intProp(device, key: kIOHIDPrimaryUsagePageKey as CFString) ?? 0
        let usage = intProp(device, key: kIOHIDPrimaryUsageKey as CFString) ?? 0

        var score = 0
        if maxFeatureReport >= 90 {
            score += 100
        } else if maxFeatureReport > 0 {
            score += maxFeatureReport
        }
        if usagePage == 0x01 && usage == 0x02 {
            score += 25
        }
        return score
    }

    private static func intProp(_ device: IOHIDDevice, key: CFString) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key) else { return nil }
        if CFGetTypeID(value) == CFNumberGetTypeID() {
            return (value as! NSNumber).intValue
        }
        return nil
    }

    private static func stringProp(_ device: IOHIDDevice, key: CFString) -> String? {
        guard let value = IOHIDDeviceGetProperty(device, key) else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            return value as? String
        }
        return nil
    }
}

private enum VendorProtocol {
    static let serviceUUID = UUID(uuidString: "52401523-F97C-7F90-0E7F-6C6F4E36DB1C")!
    static let writeUUID = UUID(uuidString: "52401524-F97C-7F90-0E7F-6C6F4E36DB1C")!
    static let notifyUUID = UUID(uuidString: "52401525-F97C-7F90-0E7F-6C6F4E36DB1C")!

    static let dpiGet: [UInt8] = [0x0B, 0x84, 0x01, 0x00]
    static let dpiSet: [UInt8] = [0x0B, 0x04, 0x01, 0x00]

    static func readHeader(req: UInt8, key: [UInt8]) -> Data {
        Data([req, 0x00, 0x00, 0x00] + key)
    }

    static func writeHeader(req: UInt8, payloadLength: UInt8, key: [UInt8]) -> Data {
        Data([req, payloadLength, 0x00, 0x00] + key)
    }

    struct NotifyHeader {
        let req: UInt8
        let length: Int
        let status: UInt8

        init?(data: Data) {
            guard data.count >= 8 else { return nil }
            req = data[0]
            length = Int(data[1])
            status = data[7]
        }
    }

    static func parsePayloadFrames(notifies: [Data], req: UInt8) -> Data? {
        guard let headerIndex = notifies.firstIndex(where: { frame in
            guard let hdr = NotifyHeader(data: frame) else { return false }
            return hdr.req == req && [0x02, 0x03, 0x05].contains(hdr.status)
        }), let header = NotifyHeader(data: notifies[headerIndex]), header.status == 0x02
        else { return nil }

        let continuation: [Data]
        if headerIndex + 1 < notifies.count {
            continuation = Array(notifies[(headerIndex + 1)...]).filter { $0.count == 20 }
        } else {
            continuation = []
        }
        let payload = continuation.reduce(into: Data()) { partialResult, frame in
            partialResult.append(frame)
        }
        if header.length == 0 { return Data() }
        return payload.prefix(header.length)
    }

    static func parseDpiSnapshot(_ payload: Data) -> DpiSnapshot? {
        guard payload.count >= 2 else { return nil }
        let activeRaw = Int(payload[0])
        let count = max(1, min(5, Int(payload[1])))

        var slots: [Int] = [800, 1600, 2400, 3200, 6400]
        var stageIDs: [UInt8] = [1, 2, 3, 4, 5]
        var marker: UInt8 = 0x03

        if payload.count >= 37 {
            for i in 0..<5 {
                let off = 2 + (i * 7)
                guard off + 6 < payload.count else { break }
                stageIDs[i] = payload[off]
                let dpi = Int(payload[off + 1]) | (Int(payload[off + 2]) << 8)
                slots[i] = dpi
                marker = payload[off + 6]
            }
        } else {
            var seenIDs: [UInt8] = []
            for i in 0..<count {
                let off = 2 + (i * 7)
                guard off + 4 < payload.count else { break }
                seenIDs.append(payload[off])
                let dpi = Int(payload[off + 1]) | (Int(payload[off + 2]) << 8)
                slots[i] = dpi
            }
            if !seenIDs.isEmpty {
                for i in 0..<min(5, seenIDs.count) {
                    stageIDs[i] = seenIDs[i]
                }
                for i in seenIDs.count..<5 {
                    stageIDs[i] = stageIDs[i - 1] &+ 1
                }
            }
            if count == 1 {
                slots = Array(repeating: slots[0], count: 5)
            }
            if payload.count > 2 + (count * 7) {
                marker = payload[min(payload.count - 1, 2 + count * 7)]
            }
        }

        let visibleIDs = Array(stageIDs.prefix(count))
        let active: Int
        if let idx = visibleIDs.firstIndex(of: UInt8(activeRaw & 0xFF)) {
            active = idx
        } else if activeRaw >= 1, activeRaw <= count {
            active = activeRaw - 1
        } else {
            active = max(0, min(count - 1, activeRaw))
        }

        return DpiSnapshot(active: active, count: count, slots: slots, stageIDs: stageIDs, marker: marker)
    }

    static func buildDpiPayload(active: Int, count: Int, slots: [Int], marker: UInt8, stageIDs: [UInt8]) -> Data {
        let clippedCount = max(1, min(5, count))
        var payload = [UInt8](repeating: 0, count: 38)
        var ids = Array(stageIDs.prefix(5))
        while ids.count < 5 {
            ids.append(ids.last.map { $0 &+ 1 } ?? UInt8(ids.count))
        }
        let activeIndex = max(0, min(clippedCount - 1, active))
        payload[0] = ids[activeIndex]
        payload[1] = UInt8(clippedCount)
        var off = 2
        for i in 0..<5 {
            let dpi = max(100, min(30_000, slots[i]))
            payload[off] = ids[i]
            payload[off + 1] = UInt8(dpi & 0xFF)
            payload[off + 2] = UInt8((dpi >> 8) & 0xFF)
            payload[off + 3] = UInt8(dpi & 0xFF)
            payload[off + 4] = UInt8((dpi >> 8) & 0xFF)
            payload[off + 5] = 0x00
            payload[off + 6] = i == 4 ? marker : 0x00
            off += 7
        }
        payload[37] = 0x00
        return Data(payload)
    }

    static func mergedSlots(current: [Int], requestedCount: Int, requested: [Int]) -> [Int] {
        var slots = Array(current.prefix(5))
        if slots.count < 5 { slots += Array(repeating: 800, count: 5 - slots.count) }
        let count = max(1, min(5, requestedCount))
        if count == 1, let first = requested.first {
            return Array(repeating: first, count: 5)
        }
        for i in 0..<count where i < requested.count {
            slots[i] = requested[i]
        }
        return slots
    }
}

private final class VendorClient: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "open.snek.probe.bt")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var isNotifyReady = false

    private var writeQueue: [Data] = []
    private var notifications: [Data] = []
    private var completion: ((Result<[Data], any Error>) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var finishWorkItem: DispatchWorkItem?

    func run(writes: [Data], timeout: TimeInterval = 1.0) async throws -> [Data] {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Data], any Error>) in
            queue.async {
                guard self.completion == nil else {
                    continuation.resume(throwing: ProbeError.protocolError("Probe busy"))
                    return
                }

                self.writeQueue = writes
                self.notifications = []
                self.timeoutWorkItem?.cancel()
                self.finishWorkItem?.cancel()
                self.timeoutWorkItem = nil
                self.finishWorkItem = nil

                self.completion = { result in
                    continuation.resume(with: result)
                }

                if self.central == nil {
                    self.central = CBCentralManager(delegate: self, queue: self.queue)
                } else {
                    self.ensureReady()
                }

                let timeoutItem = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(ProbeError.timeout))
                }
                self.timeoutWorkItem = timeoutItem
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            }
        }
    }

    private func ensureReady() {
        guard let central else { return }
        guard central.state == .poweredOn else { return }
        if isNotifyReady, peripheral?.state == .connected, writeChar != nil, notifyChar != nil {
            sendNextWrite()
            return
        }

        let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(nsuuid: VendorProtocol.serviceUUID)])
        guard let first = connected.first else {
            finish(.failure(ProbeError.protocolError("No connected peripheral with Razer vendor service")))
            return
        }
        peripheral = first
        first.delegate = self
        if first.state == .connected {
            first.discoverServices([CBUUID(nsuuid: VendorProtocol.serviceUUID)])
        } else {
            central.connect(first)
        }
    }

    private func sendNextWrite() {
        guard isNotifyReady, let peripheral, let writeChar, !writeQueue.isEmpty else {
            scheduleFinish()
            return
        }
        finishWorkItem?.cancel()
        let next = writeQueue.removeFirst()
        peripheral.writeValue(next, for: writeChar, type: .withResponse)
    }

    private func scheduleFinish() {
        guard writeQueue.isEmpty else { return }
        finishWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finish(.success(self.notifications))
        }
        finishWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.22, execute: item)
    }

    private func finish(_ result: Result<[Data], any Error>) {
        guard let completion else { return }
        self.completion = nil
        timeoutWorkItem?.cancel()
        finishWorkItem?.cancel()
        timeoutWorkItem = nil
        finishWorkItem = nil
        completion(result)
    }
}

extension VendorClient: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        ensureReady()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(nsuuid: VendorProtocol.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        isNotifyReady = false
        finish(.failure(error ?? ProbeError.protocolError("Failed to connect peripheral")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        isNotifyReady = false
        writeChar = nil
        notifyChar = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            finish(.failure(error))
            return
        }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        if let error {
            finish(.failure(error))
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == CBUUID(nsuuid: VendorProtocol.writeUUID) {
                writeChar = characteristic
            }
            if characteristic.uuid == CBUUID(nsuuid: VendorProtocol.notifyUUID) {
                notifyChar = characteristic
            }
        }
        if let notifyChar {
            peripheral.setNotifyValue(true, for: notifyChar)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            finish(.failure(error))
            return
        }
        if characteristic.isNotifying {
            isNotifyReady = true
            sendNextWrite()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            finish(.failure(error))
            return
        }
        sendNextWrite()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            finish(.failure(error))
            return
        }
        guard let value = characteristic.value else { return }
        notifications.append(value)
    }
}

private actor ProbeBridge {
    private let vendor = VendorClient()
    private var reqID: UInt8 = 0x30

    private func nextReq() -> UInt8 {
        defer { reqID = reqID &+ 1 }
        return reqID
    }

    func readDpi() async throws -> DpiSnapshot {
        for attempt in 0..<3 {
            let req = nextReq()
            let header = VendorProtocol.readHeader(req: req, key: VendorProtocol.dpiGet)
            let notifies = try await vendor.run(writes: [header], timeout: 1.2)
            if let payload = VendorProtocol.parsePayloadFrames(notifies: notifies, req: req),
               let snapshot = VendorProtocol.parseDpiSnapshot(payload) {
                return snapshot
            }
            if attempt < 2 {
                try await Task.sleep(nanoseconds: 60_000_000)
            }
        }
        throw ProbeError.protocolError("Failed to parse DPI payload")
    }

    func setDpi(active: Int, values: [Int], verifyRetries: Int, verifyDelayMs: Int) async throws -> DpiSnapshot {
        let current = try await readDpi()
        let count = max(1, min(5, values.count))
        let mergedSlots = VendorProtocol.mergedSlots(current: current.slots, requestedCount: count, requested: values)
        let expected = DpiSnapshot(
            active: max(0, min(count - 1, active)),
            count: count,
            slots: mergedSlots,
            stageIDs: current.stageIDs,
            marker: current.marker
        )
        let payload = VendorProtocol.buildDpiPayload(
            active: expected.active,
            count: expected.count,
            slots: expected.slots,
            marker: expected.marker,
            stageIDs: expected.stageIDs
        )

        let req = nextReq()
        let header = VendorProtocol.writeHeader(req: req, payloadLength: 0x26, key: VendorProtocol.dpiSet)
        let notifies = try await vendor.run(
            writes: [header, payload.prefix(20), payload.suffix(from: 20)],
            timeout: 1.0
        )
        guard let ack = notifies.compactMap({ VendorProtocol.NotifyHeader(data: $0) }).first(where: { $0.req == req }),
              ack.status == 0x02
        else {
            throw ProbeError.protocolError("DPI set did not return success ACK")
        }

        let retries = max(1, verifyRetries)
        for attempt in 0..<retries {
            let readback = try await readDpi()
            if readback.active == expected.active && readback.values == expected.values {
                return readback
            }
            if attempt < retries - 1 {
                try await Task.sleep(nanoseconds: UInt64(max(0, verifyDelayMs)) * 1_000_000)
            }
        }
        throw ProbeError.protocolError("Readback mismatch after DPI set")
    }
}

@main
struct OpenSnekProbe {
    static func main() async {
        do {
            try await run()
            Foundation.exit(EXIT_SUCCESS)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            throw ProbeError.usage(usageText)
        }

        switch command {
        case "dpi-read":
            let bridge = ProbeBridge()
            let snapshot = try await bridge.readDpi()
            print("active=\(snapshot.active + 1) count=\(snapshot.count) values=\(snapshot.values)")
        case "dpi-set":
            let bridge = ProbeBridge()
            let parsed = try parseSetArgs(Array(args.dropFirst()))
            let snapshot = try await bridge.setDpi(
                active: parsed.active,
                values: parsed.values,
                verifyRetries: parsed.verifyRetries,
                verifyDelayMs: parsed.verifyDelayMs
            )
            print("applied active=\(snapshot.active + 1) values=\(snapshot.values)")
        case "dpi-cycle":
            let bridge = ProbeBridge()
            let parsed = try parseCycleArgs(Array(args.dropFirst()))
            for i in 0..<parsed.loops {
                let values = parsed.sequence[i % parsed.sequence.count]
                let snapshot = try await bridge.setDpi(
                    active: parsed.active,
                    values: values,
                    verifyRetries: parsed.verifyRetries,
                    verifyDelayMs: parsed.verifyDelayMs
                )
                print("loop \(i + 1): active=\(snapshot.active + 1) values=\(snapshot.values)")
                if parsed.sleepMs > 0 {
                    try await Task.sleep(nanoseconds: UInt64(parsed.sleepMs) * 1_000_000)
                }
            }
        case "usb-info":
            let usb = try USBProbeClient()
            print("usb \(usb.describe())")
        case "usb-button-read":
            let parsed = try parseUSBButtonReadArgs(Array(args.dropFirst()))
            let usb = try USBProbeClient()
            print("usb \(usb.describe())")
            let slot = UInt8(max(0, min(255, parsed.slot)))
            for profile in parsed.profiles {
                if let block = try usb.readButtonFunction(profile: profile, slot: slot, hypershift: parsed.hypershift) {
                    print("profile=\(profile) slot=\(parsed.slot) hypershift=\(parsed.hypershift) \(describeUSBFunctionBlock(block))")
                } else {
                    print("profile=\(profile) slot=\(parsed.slot) hypershift=\(parsed.hypershift) read_failed")
                }
            }
        case "usb-button-set":
            let parsed = try parseUSBButtonSetArgs(Array(args.dropFirst()))
            let usb = try USBProbeClient()
            print("usb \(usb.describe())")
            let wrote = try usb.writeButtonBinding(
                profiles: parsed.profiles,
                slot: parsed.slot,
                kind: parsed.kind,
                hidKey: parsed.hidKey,
                turboEnabled: parsed.turboEnabled,
                turboRate: parsed.turboRate
            )
            guard wrote else {
                throw ProbeError.protocolError("USB button write did not return success")
            }
            let slot = UInt8(max(0, min(255, parsed.slot)))
            for profile in parsed.profiles {
                if let block = try usb.readButtonFunction(profile: profile, slot: slot, hypershift: 0x00) {
                    print("readback profile=\(profile) slot=\(parsed.slot) \(describeUSBFunctionBlock(block))")
                }
            }
        case "usb-button-set-raw":
            let parsed = try parseUSBButtonSetRawArgs(Array(args.dropFirst()))
            let usb = try USBProbeClient()
            print("usb \(usb.describe())")
            let slot = UInt8(max(0, min(255, parsed.slot)))
            var wroteAny = false
            for profile in parsed.profiles {
                if try usb.writeButtonFunction(profile: profile, slot: slot, hypershift: 0x00, functionBlock: parsed.functionBlock) {
                    wroteAny = true
                }
            }
            guard wroteAny else {
                throw ProbeError.protocolError("USB raw button write did not return success")
            }
            for profile in parsed.profiles {
                if let block = try usb.readButtonFunction(profile: profile, slot: slot, hypershift: 0x00) {
                    print("readback profile=\(profile) slot=\(parsed.slot) \(describeUSBFunctionBlock(block))")
                }
            }
        default:
            throw ProbeError.usage(usageText)
        }
    }

    private static var usageText: String {
        """
        Usage:
          OpenSnekProbe dpi-read
          OpenSnekProbe dpi-set --values 1600,6400 [--active 1] [--verify-retries 6] [--verify-delay-ms 120]
          OpenSnekProbe dpi-cycle --sequence 800,6400;1600,6400 --loops 10 [--active 1] [--sleep-ms 120]
          OpenSnekProbe usb-info
          OpenSnekProbe usb-button-read --slot 4 [--profile default|direct|both]
          OpenSnekProbe usb-button-set --slot 4 --kind right_click [--profile both] [--hid-key 4] [--turbo on|off] [--turbo-rate 142]
          OpenSnekProbe usb-button-set-raw --slot 4 --hex 01010200000000 [--profile default|direct|both]

        USB button kinds:
          default left_click right_click middle_click scroll_up scroll_down mouse_back mouse_forward keyboard_simple clear_layer
        """
    }

    private static func parseSetArgs(_ args: [String]) throws -> (values: [Int], active: Int, verifyRetries: Int, verifyDelayMs: Int) {
        let flags = parseFlags(args)
        guard let valuesRaw = flags["--values"] else {
            throw ProbeError.usage("Missing --values\n\(usageText)")
        }
        let values = try parseValues(valuesRaw)
        let active = max(0, (Int(flags["--active"] ?? "1") ?? 1) - 1)
        let verifyRetries = Int(flags["--verify-retries"] ?? "6") ?? 6
        let verifyDelayMs = Int(flags["--verify-delay-ms"] ?? "120") ?? 120
        return (values, active, verifyRetries, verifyDelayMs)
    }

    private static func parseCycleArgs(_ args: [String]) throws -> (sequence: [[Int]], loops: Int, active: Int, sleepMs: Int, verifyRetries: Int, verifyDelayMs: Int) {
        let flags = parseFlags(args)
        guard let raw = flags["--sequence"] else {
            throw ProbeError.usage("Missing --sequence\n\(usageText)")
        }
        let sequence = try raw.split(separator: ";").map { try parseValues(String($0)) }
        guard !sequence.isEmpty else { throw ProbeError.usage("Empty --sequence") }
        let loops = max(1, Int(flags["--loops"] ?? "10") ?? 10)
        let active = max(0, (Int(flags["--active"] ?? "1") ?? 1) - 1)
        let sleepMs = max(0, Int(flags["--sleep-ms"] ?? "120") ?? 120)
        let verifyRetries = Int(flags["--verify-retries"] ?? "6") ?? 6
        let verifyDelayMs = Int(flags["--verify-delay-ms"] ?? "120") ?? 120
        return (sequence, loops, active, sleepMs, verifyRetries, verifyDelayMs)
    }

    private static func parseUSBButtonReadArgs(_ args: [String]) throws -> (slot: Int, profiles: [UInt8], hypershift: UInt8) {
        let flags = parseFlags(args)
        guard let slotRaw = flags["--slot"], let slot = Int(slotRaw) else {
            throw ProbeError.usage("Missing --slot\n\(usageText)")
        }
        let profiles = try parseUSBProfiles(flags["--profile"], defaultProfiles: [0x01])
        let hypershift = UInt8(max(0, min(1, Int(flags["--hypershift"] ?? "0") ?? 0)))
        return (slot, profiles, hypershift)
    }

    private static func parseUSBButtonSetArgs(_ args: [String]) throws -> (slot: Int, kind: String, hidKey: Int, turboEnabled: Bool, turboRate: Int, profiles: [UInt8]) {
        let flags = parseFlags(args)
        guard let slotRaw = flags["--slot"], let slot = Int(slotRaw) else {
            throw ProbeError.usage("Missing --slot\n\(usageText)")
        }
        guard let kindRaw = flags["--kind"]?.lowercased() else {
            throw ProbeError.usage("Missing --kind\n\(usageText)")
        }
        let validKinds: Set<String> = [
            "default", "left_click", "right_click", "middle_click",
            "scroll_up", "scroll_down", "mouse_back", "mouse_forward",
            "keyboard_simple", "clear_layer",
        ]
        guard validKinds.contains(kindRaw) else {
            throw ProbeError.usage("Invalid --kind '\(kindRaw)'\n\(usageText)")
        }

        let hidKey = max(0, min(255, Int(flags["--hid-key"] ?? "4") ?? 4))
        let turboEnabled = parseBoolean(flags["--turbo"] ?? "off")
        let turboRate = max(1, min(255, Int(flags["--turbo-rate"] ?? "142") ?? 142))
        let profiles = try parseUSBProfiles(flags["--profile"], defaultProfiles: [0x01, 0x00])
        return (slot, kindRaw, hidKey, turboEnabled, turboRate, profiles)
    }

    private static func parseUSBButtonSetRawArgs(_ args: [String]) throws -> (slot: Int, functionBlock: [UInt8], profiles: [UInt8]) {
        let flags = parseFlags(args)
        guard let slotRaw = flags["--slot"], let slot = Int(slotRaw) else {
            throw ProbeError.usage("Missing --slot\n\(usageText)")
        }
        guard let hexRaw = flags["--hex"] else {
            throw ProbeError.usage("Missing --hex\n\(usageText)")
        }
        let functionBlock = try parseHexBytes(hexRaw)
        guard functionBlock.count == 7 else {
            throw ProbeError.usage("--hex must decode to exactly 7 bytes")
        }
        let profiles = try parseUSBProfiles(flags["--profile"], defaultProfiles: [0x01, 0x00])
        return (slot, functionBlock, profiles)
    }

    private static func parseUSBProfiles(_ raw: String?, defaultProfiles: [UInt8]) throws -> [UInt8] {
        guard let raw else { return defaultProfiles }
        let normalized = raw.lowercased()
        switch normalized {
        case "default", "persistent", "1":
            return [0x01]
        case "direct", "0":
            return [0x00]
        case "both", "all":
            return [0x01, 0x00]
        default:
            throw ProbeError.usage("Invalid --profile '\(raw)' (expected default/direct/both)")
        }
    }

    private static func parseFlags(_ args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var i = 0
        while i < args.count {
            let key = args[i]
            if key.hasPrefix("--"), i + 1 < args.count {
                result[key] = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }

    private static func parseValues(_ raw: String) throws -> [Int] {
        let values = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let clipped = values.prefix(5).map { max(100, min(30_000, $0)) }
        guard !clipped.isEmpty else {
            throw ProbeError.usage("Invalid DPI values: \(raw)")
        }
        return clipped
    }

    private static func parseBoolean(_ raw: String) -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func parseHexBytes(_ raw: String) throws -> [UInt8] {
        let normalized = raw
            .replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
        guard normalized.count % 2 == 0 else {
            throw ProbeError.usage("Invalid hex byte string: \(raw)")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(normalized.count / 2)
        var idx = normalized.startIndex
        while idx < normalized.endIndex {
            let next = normalized.index(idx, offsetBy: 2)
            let chunk = normalized[idx..<next]
            guard let value = UInt8(chunk, radix: 16) else {
                throw ProbeError.usage("Invalid hex byte string: \(raw)")
            }
            bytes.append(value)
            idx = next
        }
        return bytes
    }

    private static func describeUSBFunctionBlock(_ block: [UInt8]) -> String {
        let hex = block.map { String(format: "%02x", $0) }.joined()
        guard block.count == 7 else { return "block=\(hex)" }
        let classID = block[0]
        let length = Int(min(5, block[1]))
        let data = Array(block[2..<(2 + length)])
        let dataHex = data.map { String(format: "%02x", $0) }.joined()
        return "block=\(hex) class=0x\(String(format: "%02x", classID)) len=\(length) data=\(dataHex)"
    }
}
