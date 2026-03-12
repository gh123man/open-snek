@preconcurrency import Foundation
import IOKit.hid
import OpenSnekCore

public enum HIDDevicePresenceChangeKind: String, Hashable, Sendable {
    case connected
    case disconnected
}

public struct HIDDevicePresenceEvent: Hashable, Sendable {
    public let deviceID: String
    public let vendorID: Int
    public let productID: Int
    public let locationID: Int
    public let transport: DeviceTransportKind
    public let change: HIDDevicePresenceChangeKind
    public let observedAt: Date

    public init(
        deviceID: String,
        vendorID: Int,
        productID: Int,
        locationID: Int,
        transport: DeviceTransportKind,
        change: HIDDevicePresenceChangeKind,
        observedAt: Date
    ) {
        self.deviceID = deviceID
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.transport = transport
        self.change = change
        self.observedAt = observedAt
    }
}

public final class HIDDevicePresenceMonitor: @unchecked Sendable {
    private final class CallbackContext {
        let change: HIDDevicePresenceChangeKind
        let emit: @Sendable (HIDDevicePresenceEvent) -> Void

        init(
            change: HIDDevicePresenceChangeKind,
            emit: @escaping @Sendable (HIDDevicePresenceEvent) -> Void
        ) {
            self.change = change
            self.emit = emit
        }
    }

    public var onChange: (@Sendable (HIDDevicePresenceEvent) -> Void)?

    private let vendorIDs: [Int]
    private let queue = DispatchQueue(label: "open.snek.hid.presence")
    private let runLoopStateLock = NSLock()
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var keepAlivePort: Port?
    private var manager: IOHIDManager?
    private var matchingCallbackContext: UnsafeMutableRawPointer?
    private var removalCallbackContext: UnsafeMutableRawPointer?

    public init(vendorIDs: [Int] = [0x1532, 0x068E]) {
        self.vendorIDs = vendorIDs
    }

    public func start() {
        queue.async {
            self.ensureRunLoopLocked()
            self.performOnRunLoopLocked {
                self.startOnRunLoop()
            }
        }
    }

    private func startOnRunLoop() {
        guard manager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = vendorIDs.map { vendorID in
            [kIOHIDVendorIDKey: vendorID] as CFDictionary
        } as CFArray
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching)

        let matchingContextBox = CallbackContext(change: .connected) { [weak self] event in
            self?.onChange?(event)
        }
        let removalContextBox = CallbackContext(change: .disconnected) { [weak self] event in
            self?.onChange?(event)
        }
        let matchingContext = UnsafeMutableRawPointer(Unmanaged.passRetained(matchingContextBox).toOpaque())
        let removalContext = UnsafeMutableRawPointer(Unmanaged.passRetained(removalContextBox).toOpaque())
        matchingCallbackContext = matchingContext
        removalCallbackContext = removalContext

        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceCallback, matchingContext)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceCallback, removalContext)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            Unmanaged<CallbackContext>.fromOpaque(matchingContext).release()
            Unmanaged<CallbackContext>.fromOpaque(removalContext).release()
            matchingCallbackContext = nil
            removalCallbackContext = nil
            return
        }

        self.manager = manager
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
        thread.name = "open.snek.hid.presence"
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

    private static let deviceCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context, let event = makeEvent(device: device, context: context) else { return }
        let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
        callbackContext.emit(event)
    }

    private static func makeEvent(
        device: IOHIDDevice,
        context: UnsafeMutableRawPointer
    ) -> HIDDevicePresenceEvent? {
        let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
        guard let vendorID = USBHIDSupport.intProperty(device, key: kIOHIDVendorIDKey as CFString),
              let productID = USBHIDSupport.intProperty(device, key: kIOHIDProductIDKey as CFString) else {
            return nil
        }

        let locationID = USBHIDSupport.intProperty(device, key: kIOHIDLocationIDKey as CFString) ?? 0
        let transportRaw = (USBHIDSupport.stringProperty(device, key: kIOHIDTransportKey as CFString) ?? "").lowercased()
        let transport: DeviceTransportKind = transportRaw.contains("bluetooth") || vendorID == 0x068E ? .bluetooth : .usb
        let deviceID = String(
            format: "%04x:%04x:%08x:%@",
            vendorID,
            productID,
            locationID,
            transport.rawValue
        )

        return HIDDevicePresenceEvent(
            deviceID: deviceID,
            vendorID: vendorID,
            productID: productID,
            locationID: locationID,
            transport: transport,
            change: callbackContext.change,
            observedAt: Date()
        )
    }
}
