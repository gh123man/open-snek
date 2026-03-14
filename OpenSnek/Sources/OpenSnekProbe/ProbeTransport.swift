import Foundation
import IOKit.hid
import OpenSnekCore
import OpenSnekHardware
import OpenSnekProtocols

enum ProbeError: LocalizedError {
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

struct DpiSnapshot: Equatable {
    let active: Int
    let count: Int
    let slots: [Int]
    let stageIDs: [UInt8]
    let marker: UInt8

    var values: [Int] { Array(slots.prefix(count)) }
}

struct USBLightingReadResult: Sendable {
    let target: USBLightingTargetDescriptor
    let brightness: Int?
}

struct USBLightingWriteResult: Sendable {
    let target: USBLightingTargetDescriptor
    let args: [UInt8]
    let succeeded: Bool
}

private struct USBProbeDeviceCandidate: @unchecked Sendable {
    let index: Int
    let device: IOHIDDevice
    let devicePointer: UInt
    let deviceID: String
    let productID: Int
    let productName: String
    let locationID: Int
    let usagePage: Int
    let usage: Int
    let maxInputReportSize: Int
    let maxFeatureReportSize: Int
    let score: Int
    let passiveDescriptor: PassiveDPIInputDescriptor?

    var usageLabel: String {
        String(format: "0x%02x:0x%02x", usagePage, usage)
    }

    func describe() -> String {
        String(
            format: "candidate[%d] %@ pid=0x%04x loc=0x%08x usage=%@ input=%d feature=%d score=%d name=%@",
            index,
            deviceID,
            productID,
            locationID,
            usageLabel,
            maxInputReportSize,
            maxFeatureReportSize,
            score,
            productName
        )
    }
}

private func enumerateUSBProbeCandidates(preferredProductID: Int? = nil) throws -> (manager: IOHIDManager, candidates: [USBProbeDeviceCandidate]) {
    let usbVID = 0x1532
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

    var gathered: [(device: IOHIDDevice, deviceID: String, productID: Int, productName: String, locationID: Int, usagePage: Int, usage: Int, maxInputReportSize: Int, maxFeatureReportSize: Int, score: Int, passiveDescriptor: PassiveDPIInputDescriptor?)] = []
    for candidate in rawSet {
        guard
            USBHIDSupport.intProperty(candidate, key: kIOHIDVendorIDKey as CFString) == usbVID,
            let product = USBHIDSupport.intProperty(candidate, key: kIOHIDProductIDKey as CFString)
        else { continue }
        if let preferredProductID, product != preferredProductID { continue }

        let transport = (USBHIDSupport.stringProperty(candidate, key: kIOHIDTransportKey as CFString) ?? "").lowercased()
        if transport.contains("bluetooth") { continue }

        let locationID = USBHIDSupport.intProperty(candidate, key: kIOHIDLocationIDKey as CFString) ?? 0
        let deviceID = String(format: "%04x:%04x:%08x:usb", usbVID, product, locationID)
        let usagePage = USBHIDSupport.intProperty(candidate, key: kIOHIDPrimaryUsagePageKey as CFString) ?? 0
        let usage = USBHIDSupport.intProperty(candidate, key: kIOHIDPrimaryUsageKey as CFString) ?? 0
        let maxInputReportSize = USBHIDSupport.intProperty(candidate, key: kIOHIDMaxInputReportSizeKey as CFString) ?? 0
        let maxFeatureReportSize = USBHIDSupport.intProperty(candidate, key: kIOHIDMaxFeatureReportSizeKey as CFString) ?? 0
        let score = USBHIDSupport.handlePreferenceScore(device: candidate)
        let productName = USBHIDSupport.stringProperty(candidate, key: kIOHIDProductKey as CFString) ?? "Razer HID Device"
        let passiveDescriptor = DeviceProfiles.resolve(vendorID: usbVID, productID: product, transport: .usb)?.passiveDPIInput

        gathered.append((
            device: candidate,
            deviceID: deviceID,
            productID: product,
            productName: productName,
            locationID: locationID,
            usagePage: usagePage,
            usage: usage,
            maxInputReportSize: maxInputReportSize,
            maxFeatureReportSize: maxFeatureReportSize,
            score: score,
            passiveDescriptor: passiveDescriptor
        ))
    }

    guard !gathered.isEmpty else {
        if let preferredProductID {
            throw ProbeError.protocolError(
                "No non-Bluetooth USB Razer HID interface found for pid 0x\(String(format: "%04x", preferredProductID))"
            )
        }
        throw ProbeError.protocolError("No non-Bluetooth USB Razer HID interface found")
    }

    let sorted = gathered.sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.usagePage != rhs.usagePage { return lhs.usagePage < rhs.usagePage }
        if lhs.usage != rhs.usage { return lhs.usage < rhs.usage }
        if lhs.maxInputReportSize != rhs.maxInputReportSize { return lhs.maxInputReportSize > rhs.maxInputReportSize }
        return lhs.maxFeatureReportSize > rhs.maxFeatureReportSize
    }

    let candidates = sorted.enumerated().map { index, candidate in
        USBProbeDeviceCandidate(
            index: index,
            device: candidate.device,
            devicePointer: UInt(bitPattern: Unmanaged.passUnretained(candidate.device).toOpaque()),
            deviceID: candidate.deviceID,
            productID: candidate.productID,
            productName: candidate.productName,
            locationID: candidate.locationID,
            usagePage: candidate.usagePage,
            usage: candidate.usage,
            maxInputReportSize: candidate.maxInputReportSize,
            maxFeatureReportSize: candidate.maxFeatureReportSize,
            score: candidate.score,
            passiveDescriptor: candidate.passiveDescriptor
        )
    }
    return (manager, candidates)
}

final class USBProbeClient {
    private let manager: IOHIDManager
    private let session: USBHIDControlSession
    private let deviceID: String
    private let productID: Int
    private let profileID: DeviceProfileID?
    private let profile: DeviceProfile?

    init(productID preferredProductID: Int? = nil) throws {
        let enumeration = try enumerateUSBProbeCandidates(preferredProductID: preferredProductID)
        guard let best = enumeration.candidates.first else {
            throw ProbeError.protocolError("No non-Bluetooth USB Razer HID control interface found")
        }

        self.manager = enumeration.manager
        self.session = USBHIDControlSession(device: best.device, deviceID: best.deviceID)
        self.deviceID = best.deviceID
        self.productID = best.productID
        self.profile = DeviceProfiles.resolve(vendorID: 0x1532, productID: best.productID, transport: .usb)
        self.profileID = profile?.id
    }

    func describe() -> String {
        "\(deviceID) pid=0x\(String(format: "%04x", productID))"
    }

    func supportedLightingEffects() -> [LightingEffectKind] {
        profile?.supportedLightingEffects ?? LightingEffectKind.allCases
    }

    func availableLightingZones() -> [USBLightingZoneDescriptor] {
        profile?.usbLightingZones ?? []
    }

    func lightingZoneChoices() -> [String] {
        let zoneIDs = availableLightingZones().map(\.id)
        return zoneIDs.isEmpty ? ["all"] : ["all"] + zoneIDs
    }

    func lightingTargets(zoneID: String? = nil) -> [USBLightingTargetDescriptor]? {
        if let profile {
            return profile.lightingTargets(for: zoneID)
        }

        let normalizedZoneID = zoneID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedZoneID == nil || normalizedZoneID == "" || normalizedZoneID == "all" else {
            return nil
        }
        return [USBLightingTargetDescriptor(zoneID: "led_01", zoneLabel: "LED 0x01", ledID: 0x01)]
    }

    func readLightingBrightness(zoneID: String? = nil) throws -> [USBLightingReadResult]? {
        guard let targets = lightingTargets(zoneID: zoneID) else { return nil }
        return try targets.map { target in
            USBLightingReadResult(
                target: target,
                brightness: try readLightingBrightness(ledID: target.ledID)
            )
        }
    }

    func writeLightingBrightness(value: Int, zoneID: String? = nil) throws -> [USBLightingWriteResult]? {
        guard let targets = lightingTargets(zoneID: zoneID) else { return nil }
        let brightness = UInt8(max(0, min(255, value)))
        return try targets.map { target in
            let args = [0x01, target.ledID, brightness]
            return USBLightingWriteResult(
                target: target,
                args: args,
                succeeded: try writeLightingCommand(cmdID: 0x04, args: args)
            )
        }
    }

    func writeLightingEffect(effect: LightingEffectPatch, zoneID: String? = nil) throws -> [USBLightingWriteResult]? {
        guard let targets = lightingTargets(zoneID: zoneID) else { return nil }
        return try targets.map { target in
            let args = BLEVendorProtocol.buildScrollLEDEffectArgs(effect: effect, ledID: target.ledID)
            return USBLightingWriteResult(
                target: target,
                args: args,
                succeeded: try writeLightingCommand(cmdID: 0x02, args: args)
            )
        }
    }

    func readButtonFunction(profile: UInt8, slot: UInt8, hypershift: UInt8 = 0x00) throws -> [UInt8]? {
        var args: [UInt8] = [profile, slot, hypershift]
        args.append(contentsOf: [UInt8](repeating: 0x00, count: 7))
        guard let response = try session.perform(
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
            profileID: profileID
        )
    }

    func writeButtonFunction(profile: UInt8, slot: UInt8, hypershift: UInt8 = 0x00, functionBlock: [UInt8]) throws -> Bool {
        guard functionBlock.count == 7 else {
            throw ProbeError.usage("Function block must be exactly 7 bytes")
        }
        let args = [profile, slot, hypershift] + functionBlock
        guard let response = try session.perform(
            classID: 0x02,
            cmdID: 0x0C,
            size: UInt8(args.count),
            args: args,
            allowTxnRescan: true,
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
        turboRate: Int,
        clutchDPI: Int?
    ) throws -> Bool {
        guard let bindingKind = ButtonBindingKind(rawValue: kind) else {
            throw ProbeError.usage("Invalid --kind '\(kind)'")
        }
        let functionBlock = ButtonBindingSupport.buildUSBFunctionBlock(
            slot: slot,
            kind: bindingKind,
            hidKey: hidKey,
            turboEnabled: turboEnabled && bindingKind.supportsTurbo,
            turboRate: turboRate,
            clutchDPI: clutchDPI,
            profileID: profileID
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

    func rawCommand(
        classID: UInt8,
        cmdID: UInt8,
        size: UInt8,
        args: [UInt8],
        allowTxnRescan: Bool = true,
        responseAttempts: Int = 12,
        responseDelayUs: useconds_t = 40_000
    ) throws -> [UInt8]? {
        try session.perform(
            classID: classID,
            cmdID: cmdID,
            size: size,
            args: args,
            allowTxnRescan: allowTxnRescan,
            responseAttempts: responseAttempts,
            responseDelayUs: responseDelayUs
        )
    }

    private func readLightingBrightness(ledID: UInt8) throws -> Int? {
        let args: [UInt8] = [0x01, ledID, 0x00]
        guard let response = try session.perform(
            classID: 0x0F,
            cmdID: 0x84,
            size: 0x03,
            args: args
        ), response[0] == 0x02, response.count > 10 else {
            return nil
        }
        return Int(response[10])
    }

    private func writeLightingCommand(cmdID: UInt8, args: [UInt8]) throws -> Bool {
        guard let response = try session.perform(
            classID: 0x0F,
            cmdID: cmdID,
            size: UInt8(max(0, min(255, args.count))),
            args: args
        ) else {
            return false
        }
        return response[0] == 0x02
    }
}

struct USBInputReportEvent: Sendable {
    let candidateIndex: Int
    let usagePage: Int
    let usage: Int
    let maxInputReportSize: Int
    let maxFeatureReportSize: Int
    let report: [UInt8]
    let elapsedSeconds: Double
    let passiveDPI: PassiveDPIReading?

    var usageLabel: String {
        String(format: "0x%02x:0x%02x", usagePage, usage)
    }
}

final class USBInputReportProbe: @unchecked Sendable {
    private final class CallbackContext {
        let emit: @Sendable ([UInt8]) -> Void

        init(emit: @escaping @Sendable ([UInt8]) -> Void) {
            self.emit = emit
        }
    }

    private struct Registration {
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let bufferLength: CFIndex
        let context: UnsafeMutableRawPointer
    }

    private let manager: IOHIDManager
    private let candidates: [USBProbeDeviceCandidate]
    private let queue = DispatchQueue(label: "open.snek.probe.usb-input")
    private let runLoopStateLock = NSLock()
    private let reportCountLock = NSLock()
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var keepAlivePort: Port?
    private var registrationsByIndex: [Int: Registration] = [:]
    private var captureStartedAt: Date = .distantPast
    private var reportCount = 0

    var candidateCount: Int { candidates.count }

    init(productID preferredProductID: Int? = nil) throws {
        let enumeration = try enumerateUSBProbeCandidates(preferredProductID: preferredProductID)
        self.manager = enumeration.manager
        self.candidates = enumeration.candidates
    }

    deinit {
        stopSynchronously()
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func describeCandidates() -> [String] {
        candidates.map { $0.describe() }
    }

    func capture(
        duration: TimeInterval,
        maxReports: Int? = nil,
        onReport: @escaping @Sendable (USBInputReportEvent) -> Void
    ) async throws -> Int {
        try await start(onReport: onReport)
        defer { stopSynchronously() }

        let deadline = Date().addingTimeInterval(max(0.1, duration))
        while Date() < deadline {
            if let maxReports, currentReportCount() >= maxReports {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        return currentReportCount()
    }

    private func start(onReport: @escaping @Sendable (USBInputReportEvent) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.ensureRunLoopLocked()
                self.performOnRunLoopLocked {
                    self.removeAllRegistrations()
                    self.captureStartedAt = Date()
                    self.resetReportCount()

                    for candidate in self.candidates {
                        _ = self.addRegistration(candidate: candidate, onReport: onReport)
                    }

                    if self.registrationsByIndex.isEmpty {
                        continuation.resume(throwing: ProbeError.protocolError("Failed to register any USB input-report callbacks"))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func ensureRunLoopLocked() {
        runLoopStateLock.lock()
        if runLoop != nil {
            runLoopStateLock.unlock()
            return
        }
        runLoopStateLock.unlock()

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }

            let keepAlivePort = Port()
            RunLoop.current.add(keepAlivePort, forMode: .default)
            let currentRunLoop = CFRunLoopGetCurrent()

            self.runLoopStateLock.lock()
            self.keepAlivePort = keepAlivePort
            self.runLoop = currentRunLoop
            self.runLoopStateLock.unlock()
            ready.signal()

            while !Thread.current.isCancelled {
                let _: Void = autoreleasepool {
                    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 1.0, false)
                }
            }
        }
        thread.name = "open.snek.probe.usb-input"
        runLoopStateLock.lock()
        self.thread = thread
        runLoopStateLock.unlock()
        thread.start()
        ready.wait()
    }

    private func performOnRunLoopLocked(_ block: @escaping () -> Void) {
        guard let runLoop else {
            block()
            return
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func addRegistration(
        candidate: USBProbeDeviceCandidate,
        onReport: @escaping @Sendable (USBInputReportEvent) -> Void
    ) -> Bool {
        let openResult = IOHIDDeviceOpen(candidate.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { return false }

        let reportLength = max(1, candidate.maxInputReportSize)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportLength)
        buffer.initialize(repeating: 0, count: reportLength)

        let captureStartedAt = self.captureStartedAt
        let contextBox = CallbackContext { [weak self] report in
            guard let self else { return }
            let observedAt = Date()
            let passiveDPI = candidate.passiveDescriptor.flatMap {
                PassiveDPIParser.parse(report: report, descriptor: $0)
            }
            self.incrementReportCount()
            onReport(
                USBInputReportEvent(
                    candidateIndex: candidate.index,
                    usagePage: candidate.usagePage,
                    usage: candidate.usage,
                    maxInputReportSize: candidate.maxInputReportSize,
                    maxFeatureReportSize: candidate.maxFeatureReportSize,
                    report: report,
                    elapsedSeconds: observedAt.timeIntervalSince(captureStartedAt),
                    passiveDPI: passiveDPI
                )
            )
        }
        let context = UnsafeMutableRawPointer(Unmanaged.passRetained(contextBox).toOpaque())

        IOHIDDeviceScheduleWithRunLoop(candidate.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(
            candidate.device,
            buffer,
            CFIndex(reportLength),
            Self.inputReportCallback,
            context
        )

        registrationsByIndex[candidate.index] = Registration(
            device: candidate.device,
            buffer: buffer,
            bufferLength: CFIndex(reportLength),
            context: context
        )
        return true
    }

    private func removeAllRegistrations() {
        for index in Array(registrationsByIndex.keys) {
            removeRegistration(index: index)
        }
    }

    private func removeRegistration(index: Int) {
        guard let registration = registrationsByIndex.removeValue(forKey: index) else { return }
        IOHIDDeviceUnscheduleFromRunLoop(
            registration.device,
            CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDDeviceClose(registration.device, IOOptionBits(kIOHIDOptionsTypeNone))
        registration.buffer.deinitialize(count: Int(registration.bufferLength))
        registration.buffer.deallocate()
        Unmanaged<CallbackContext>.fromOpaque(registration.context).release()
    }

    private func stopSynchronously() {
        let stopped = DispatchSemaphore(value: 0)
        queue.async {
            guard self.runLoop != nil || !self.registrationsByIndex.isEmpty else {
                stopped.signal()
                return
            }
            self.performOnRunLoopLocked {
                self.removeAllRegistrations()
                self.runLoopStateLock.lock()
                let runLoop = self.runLoop
                let thread = self.thread
                self.keepAlivePort = nil
                self.runLoop = nil
                self.thread = nil
                self.runLoopStateLock.unlock()
                thread?.cancel()
                if let runLoop {
                    CFRunLoopStop(runLoop)
                    CFRunLoopWakeUp(runLoop)
                }
                stopped.signal()
            }
        }
        stopped.wait()
    }

    private func resetReportCount() {
        reportCountLock.lock()
        reportCount = 0
        reportCountLock.unlock()
    }

    private func incrementReportCount() {
        reportCountLock.lock()
        reportCount += 1
        reportCountLock.unlock()
    }

    private func currentReportCount() -> Int {
        reportCountLock.lock()
        let count = reportCount
        reportCountLock.unlock()
        return count
    }

    private static let inputReportCallback: IOHIDReportCallback = { context, result, _, reportType, _, report, reportLength in
        guard result == kIOReturnSuccess, reportType == kIOHIDReportTypeInput, let context else { return }
        let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
        let bytes = Array(UnsafeBufferPointer(start: report, count: max(0, reportLength)))
        callbackContext.emit(bytes)
    }
}

struct USBInputValueEvent: Sendable {
    let candidateIndex: Int
    let deviceUsagePage: Int
    let deviceUsage: Int
    let elementUsagePage: Int
    let elementUsage: Int
    let reportID: Int
    let integerValue: Int
    let elapsedSeconds: Double

    var deviceUsageLabel: String {
        String(format: "0x%02x:0x%02x", deviceUsagePage, deviceUsage)
    }

    var elementUsageLabel: String {
        String(format: "0x%04x:0x%04x", elementUsagePage, elementUsage)
    }
}

final class USBInputValueProbe: @unchecked Sendable {
    private final class CallbackContext {
        let emit: @Sendable (IOHIDValue, UInt?) -> Void

        init(emit: @escaping @Sendable (IOHIDValue, UInt?) -> Void) {
            self.emit = emit
        }
    }

    private let manager: IOHIDManager
    private let candidates: [USBProbeDeviceCandidate]
    private let candidateByPointer: [UInt: USBProbeDeviceCandidate]
    private let queue = DispatchQueue(label: "open.snek.probe.usb-value")
    private let runLoopStateLock = NSLock()
    private let eventCountLock = NSLock()
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var keepAlivePort: Port?
    private var callbackContext: UnsafeMutableRawPointer?
    private var captureStartedAt: Date = .distantPast
    private var eventCount = 0

    var candidateCount: Int { candidates.count }

    init(productID preferredProductID: Int? = nil) throws {
        let enumeration = try enumerateUSBProbeCandidates(preferredProductID: preferredProductID)
        self.manager = enumeration.manager
        self.candidates = enumeration.candidates
        self.candidateByPointer = Dictionary(uniqueKeysWithValues: enumeration.candidates.map { ($0.devicePointer, $0) })
    }

    deinit {
        stopSynchronously()
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func describeCandidates() -> [String] {
        candidates.map { $0.describe() }
    }

    func capture(
        duration: TimeInterval,
        maxEvents: Int? = nil,
        onValue: @escaping @Sendable (USBInputValueEvent) -> Void
    ) async throws -> Int {
        try await start(onValue: onValue)
        defer { stopSynchronously() }

        let deadline = Date().addingTimeInterval(max(0.1, duration))
        while Date() < deadline {
            if let maxEvents, currentEventCount() >= maxEvents {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        return currentEventCount()
    }

    private func start(onValue: @escaping @Sendable (USBInputValueEvent) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.ensureRunLoopLocked()
                self.performOnRunLoopLocked {
                    self.stopManagerCallbackOnRunLoop()
                    self.captureStartedAt = Date()
                    self.resetEventCount()

                    let captureStartedAt = self.captureStartedAt
                    let candidateByPointer = self.candidateByPointer
                    let contextBox = CallbackContext { [weak self] value, senderPointer in
                        guard let self,
                              let senderPointer,
                              let candidate = candidateByPointer[senderPointer] else { return }
                        let element = IOHIDValueGetElement(value)
                        let observedAt = Date()
                        self.incrementEventCount()
                        onValue(
                            USBInputValueEvent(
                                candidateIndex: candidate.index,
                                deviceUsagePage: candidate.usagePage,
                                deviceUsage: candidate.usage,
                                elementUsagePage: Int(IOHIDElementGetUsagePage(element)),
                                elementUsage: Int(IOHIDElementGetUsage(element)),
                                reportID: Int(IOHIDElementGetReportID(element)),
                                integerValue: IOHIDValueGetIntegerValue(value),
                                elapsedSeconds: observedAt.timeIntervalSince(captureStartedAt)
                            )
                        )
                    }
                    let context = UnsafeMutableRawPointer(Unmanaged.passRetained(contextBox).toOpaque())
                    self.callbackContext = context

                    IOHIDManagerScheduleWithRunLoop(self.manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
                    IOHIDManagerRegisterInputValueCallback(self.manager, Self.inputValueCallback, context)
                    continuation.resume()
                }
            }
        }
    }

    private func ensureRunLoopLocked() {
        runLoopStateLock.lock()
        if runLoop != nil {
            runLoopStateLock.unlock()
            return
        }
        runLoopStateLock.unlock()

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }

            let keepAlivePort = Port()
            RunLoop.current.add(keepAlivePort, forMode: .default)
            let currentRunLoop = CFRunLoopGetCurrent()

            self.runLoopStateLock.lock()
            self.keepAlivePort = keepAlivePort
            self.runLoop = currentRunLoop
            self.runLoopStateLock.unlock()
            ready.signal()

            while !Thread.current.isCancelled {
                let _: Void = autoreleasepool {
                    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 1.0, false)
                }
            }
        }
        thread.name = "open.snek.probe.usb-value"
        runLoopStateLock.lock()
        self.thread = thread
        runLoopStateLock.unlock()
        thread.start()
        ready.wait()
    }

    private func performOnRunLoopLocked(_ block: @escaping () -> Void) {
        guard let runLoop else {
            block()
            return
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func stopSynchronously() {
        let stopped = DispatchSemaphore(value: 0)
        queue.async {
            guard self.runLoop != nil || self.callbackContext != nil else {
                stopped.signal()
                return
            }
            self.performOnRunLoopLocked {
                self.stopManagerCallbackOnRunLoop()
                self.runLoopStateLock.lock()
                let runLoop = self.runLoop
                let thread = self.thread
                self.keepAlivePort = nil
                self.runLoop = nil
                self.thread = nil
                self.runLoopStateLock.unlock()
                thread?.cancel()
                if let runLoop {
                    CFRunLoopStop(runLoop)
                    CFRunLoopWakeUp(runLoop)
                }
                stopped.signal()
            }
        }
        stopped.wait()
    }

    private func stopManagerCallbackOnRunLoop() {
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        if let callbackContext {
            Unmanaged<CallbackContext>.fromOpaque(callbackContext).release()
            self.callbackContext = nil
        }
    }

    private func resetEventCount() {
        eventCountLock.lock()
        eventCount = 0
        eventCountLock.unlock()
    }

    private func incrementEventCount() {
        eventCountLock.lock()
        eventCount += 1
        eventCountLock.unlock()
    }

    private func currentEventCount() -> Int {
        eventCountLock.lock()
        let count = eventCount
        eventCountLock.unlock()
        return count
    }

    private static let inputValueCallback: IOHIDValueCallback = { context, _, sender, value in
        guard let context else { return }
        let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
        let senderPointer = sender.map { UInt(bitPattern: $0) }
        callbackContext.emit(value, senderPointer)
    }
}

actor ProbeBridge {
    private let vendor = BLEVendorTransportClient()
    private var reqID: UInt8 = 0x30

    private func nextReq() -> UInt8 {
        defer { reqID = reqID &+ 1 }
        return reqID
    }

    func readDpi() async throws -> DpiSnapshot {
        for attempt in 0..<3 {
            let req = nextReq()
            let header = BLEVendorProtocol.buildReadHeader(req: req, key: .dpiStagesGet)
            let notifies = try await vendor.run(writes: [header], timeout: 1.2)
            if let payload = BLEVendorProtocol.parsePayloadFrames(notifies: notifies, req: req),
               let parsed = BLEVendorProtocol.parseDpiStageSnapshot(blob: payload) {
                return DpiSnapshot(
                    active: parsed.active,
                    count: parsed.count,
                    slots: parsed.slots,
                    stageIDs: parsed.stageIDs,
                    marker: parsed.marker
                )
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
        let mergedSlots = BLEVendorProtocol.mergedStageSlots(
            currentSlots: current.slots,
            requestedCount: count,
            requestedValues: values
        )
        let expected = DpiSnapshot(
            active: max(0, min(count - 1, active)),
            count: count,
            slots: mergedSlots,
            stageIDs: current.stageIDs,
            marker: current.marker
        )
        let payload = BLEVendorProtocol.buildDpiStagePayload(
            active: expected.active,
            count: expected.count,
            slots: expected.slots,
            marker: expected.marker,
            stageIDs: expected.stageIDs
        )

        let req = nextReq()
        let header = BLEVendorProtocol.buildWriteHeader(req: req, payloadLength: 0x26, key: .dpiStagesSet)
        let notifies = try await vendor.run(
            writes: [header, payload.prefix(20), payload.suffix(from: 20)],
            timeout: 1.0
        )
        guard let ack = notifies.compactMap({ BLEVendorProtocol.NotifyHeader(data: $0) }).first(where: { $0.req == req }),
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
