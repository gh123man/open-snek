@preconcurrency import Foundation
import IOKit.hid
import OpenSnekCore

public struct PassiveDPIReading: Hashable, Codable, Sendable {
    public let dpiX: Int
    public let dpiY: Int

    public init(dpiX: Int, dpiY: Int) {
        self.dpiX = dpiX
        self.dpiY = dpiY
    }
}

public struct PassiveDPIEvent: Hashable, Sendable {
    public let deviceID: String
    public let dpiX: Int
    public let dpiY: Int
    public let observedAt: Date

    public init(deviceID: String, dpiX: Int, dpiY: Int, observedAt: Date) {
        self.deviceID = deviceID
        self.dpiX = dpiX
        self.dpiY = dpiY
        self.observedAt = observedAt
    }
}

public struct PassiveDPIHeartbeatEvent: Sendable {
    public let deviceID: String
    public let observedAt: Date

    public init(
        deviceID: String,
        observedAt: Date
    ) {
        self.deviceID = deviceID
        self.observedAt = observedAt
    }
}

public enum PassiveDPIInputClassification: Hashable, Sendable {
    case dpi(PassiveDPIReading)
    case heartbeat
    case other
}

public enum PassiveDPIParser {
    public static func classify(
        report: [UInt8],
        descriptor: PassiveDPIInputDescriptor
    ) -> PassiveDPIInputClassification {
        let allowedSubtypes = [descriptor.subtype, descriptor.heartbeatSubtype].compactMap { $0 }
        guard report.count >= descriptor.minInputReportSize,
              let payloadStart = payloadStartIndex(
                  in: report,
                  descriptor: descriptor,
                  allowedSubtypes: allowedSubtypes
              ) else {
            return .other
        }

        let subtype = report[payloadStart]
        if subtype == descriptor.subtype {
            guard report.count > payloadStart + 4 else { return .other }

            let dpiX = (Int(report[payloadStart + 1]) << 8) | Int(report[payloadStart + 2])
            let dpiY = (Int(report[payloadStart + 3]) << 8) | Int(report[payloadStart + 4])
            guard (100...30_000).contains(dpiX), (100...30_000).contains(dpiY) else { return .other }
            return .dpi(PassiveDPIReading(dpiX: dpiX, dpiY: dpiY))
        }

        if let heartbeatSubtype = descriptor.heartbeatSubtype, subtype == heartbeatSubtype {
            return .heartbeat
        }

        return .other
    }

    public static func parse(
        report: [UInt8],
        descriptor: PassiveDPIInputDescriptor
    ) -> PassiveDPIReading? {
        guard case .dpi(let reading) = classify(report: report, descriptor: descriptor) else { return nil }
        return reading
    }

    private static func payloadStartIndex(
        in report: [UInt8],
        descriptor: PassiveDPIInputDescriptor,
        allowedSubtypes: [UInt8]
    ) -> Int? {
        if let first = report.first, allowedSubtypes.contains(first) {
            return 0
        }

        var index = 0
        while index < report.count, report[index] == descriptor.reportID {
            let candidate = index + 1
            if candidate < report.count, allowedSubtypes.contains(report[candidate]) {
                return candidate
            }
            index += 1
        }

        return nil
    }
}

public final class PassiveDPIEventMonitor: @unchecked Sendable {
    public struct WatchTarget: @unchecked Sendable {
        public let deviceID: String
        public let targetID: String
        public let device: IOHIDDevice
        public let descriptor: PassiveDPIInputDescriptor

        public init(deviceID: String, targetID: String, device: IOHIDDevice, descriptor: PassiveDPIInputDescriptor) {
            self.deviceID = deviceID
            self.targetID = targetID
            self.device = device
            self.descriptor = descriptor
        }
    }

    private final class CallbackContext {
        let deviceID: String
        let descriptor: PassiveDPIInputDescriptor
        let emit: @Sendable (PassiveDPIEvent) -> Void
        let emitHeartbeat: @Sendable (PassiveDPIHeartbeatEvent) -> Void

        init(
            deviceID: String,
            descriptor: PassiveDPIInputDescriptor,
            emit: @escaping @Sendable (PassiveDPIEvent) -> Void,
            emitHeartbeat: @escaping @Sendable (PassiveDPIHeartbeatEvent) -> Void
        ) {
            self.deviceID = deviceID
            self.descriptor = descriptor
            self.emit = emit
            self.emitHeartbeat = emitHeartbeat
        }
    }

    private struct RegistrationKey: Hashable {
        let deviceID: String
        let targetID: String
    }

    private struct Registration {
        let deviceID: String
        let targetID: String
        let device: IOHIDDevice
        let descriptor: PassiveDPIInputDescriptor
        let buffer: UnsafeMutablePointer<UInt8>
        let bufferLength: CFIndex
        let context: UnsafeMutableRawPointer
    }

    public var onEvent: (@Sendable (PassiveDPIEvent) -> Void)?
    public var onHeartbeat: (@Sendable (PassiveDPIHeartbeatEvent) -> Void)?

    private let queue = DispatchQueue(label: "open.snek.hid.passive-dpi")
    private let runLoopStateLock = NSLock()
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var keepAlivePort: Port?
    private var registrationsByKey: [RegistrationKey: Registration] = [:]

    public init() {}

    public func replaceTargets(
        _ targets: [WatchTarget],
        forceRebuildDeviceIDs: Set<String> = []
    ) async -> Set<String> {
        await withCheckedContinuation { continuation in
            queue.async {
                self.ensureRunLoopLocked()
                self.performOnRunLoopLocked {
                    let active = self.replaceTargetsOnRunLoop(
                        targets,
                        forceRebuildDeviceIDs: forceRebuildDeviceIDs
                    )
                    continuation.resume(returning: active)
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
        thread.name = "open.snek.hid.passive-dpi"
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

    private func replaceTargetsOnRunLoop(
        _ targets: [WatchTarget],
        forceRebuildDeviceIDs: Set<String>
    ) -> Set<String> {
        var desiredByKey: [RegistrationKey: WatchTarget] = [:]
        for target in targets {
            let key = RegistrationKey(
                deviceID: target.deviceID,
                targetID: target.targetID
            )
            desiredByKey[key] = target
        }

        let obsoleteKeys = Set(registrationsByKey.keys).subtracting(desiredByKey.keys)
        for key in obsoleteKeys {
            removeRegistration(key: key)
        }
        if !forceRebuildDeviceIDs.isEmpty {
            let forcedKeys = registrationsByKey.keys.filter { forceRebuildDeviceIDs.contains($0.deviceID) }
            for key in forcedKeys {
                removeRegistration(key: key)
            }
        }

        var activeDeviceIDs: Set<String> = []
        for (key, target) in desiredByKey {
            if let existing = registrationsByKey[key],
               existing.descriptor == target.descriptor,
               !Self.deviceReferenceChanged(existing.device, target.device) {
                activeDeviceIDs.insert(target.deviceID)
                continue
            }

            removeRegistration(key: key)
            if addRegistration(target: target, key: key) {
                activeDeviceIDs.insert(target.deviceID)
            }
        }

        return activeDeviceIDs
    }

    private func addRegistration(target: WatchTarget, key: RegistrationKey) -> Bool {
        let openResult = IOHIDDeviceOpen(target.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { return false }

        let reportLength = max(
            target.descriptor.minInputReportSize,
            USBHIDSupport.intProperty(target.device, key: kIOHIDMaxInputReportSizeKey as CFString) ?? target.descriptor.minInputReportSize
        )
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportLength)
        buffer.initialize(repeating: 0, count: reportLength)

        let contextBox = CallbackContext(
            deviceID: target.deviceID,
            descriptor: target.descriptor
        ) { [weak self] event in
            self?.onEvent?(event)
        } emitHeartbeat: { [weak self] event in
            self?.onHeartbeat?(event)
        }
        let context = UnsafeMutableRawPointer(Unmanaged.passRetained(contextBox).toOpaque())

        IOHIDDeviceScheduleWithRunLoop(target.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(
            target.device,
            buffer,
            CFIndex(reportLength),
            Self.inputReportCallback,
            context
        )

        registrationsByKey[key] = Registration(
            deviceID: target.deviceID,
            targetID: target.targetID,
            device: target.device,
            descriptor: target.descriptor,
            buffer: buffer,
            bufferLength: CFIndex(reportLength),
            context: context
        )
        return true
    }

    private func removeRegistration(key: RegistrationKey) {
        guard let registration = registrationsByKey.removeValue(forKey: key) else { return }
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

    private static func deviceReferenceChanged(_ lhs: IOHIDDevice, _ rhs: IOHIDDevice) -> Bool {
        Unmanaged.passUnretained(lhs).toOpaque() != Unmanaged.passUnretained(rhs).toOpaque()
    }

    private static let inputReportCallback: IOHIDReportCallback = { context, result, _, reportType, _, report, reportLength in
        guard result == kIOReturnSuccess, reportType == kIOHIDReportTypeInput, let context else { return }
        let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
        let bytes = Array(UnsafeBufferPointer(start: report, count: max(0, reportLength)))
        let observedAt = Date()
        switch PassiveDPIParser.classify(report: bytes, descriptor: callbackContext.descriptor) {
        case .dpi(let reading):
            callbackContext.emit(
                PassiveDPIEvent(
                    deviceID: callbackContext.deviceID,
                    dpiX: reading.dpiX,
                    dpiY: reading.dpiY,
                    observedAt: observedAt
                )
            )
        case .heartbeat:
            callbackContext.emitHeartbeat(
                PassiveDPIHeartbeatEvent(
                    deviceID: callbackContext.deviceID,
                    observedAt: observedAt
                )
            )
        case .other:
            break
        }
    }
}
