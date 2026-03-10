import Foundation
import IOKit.hid
import OpenSnekProtocols

public enum USBHIDSupport {
    public static func intProperty(_ device: IOHIDDevice, key: CFString) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key) else { return nil }
        if CFGetTypeID(value) == CFNumberGetTypeID() {
            return (value as! NSNumber).intValue
        }
        return nil
    }

    public static func stringProperty(_ device: IOHIDDevice, key: CFString) -> String? {
        guard let value = IOHIDDeviceGetProperty(device, key) else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            return value as? String
        }
        return nil
    }

    public static func handlePreferenceScore(device: IOHIDDevice) -> Int {
        let maxFeatureReport = intProperty(device, key: kIOHIDMaxFeatureReportSizeKey as CFString) ?? 0
        let usagePage = intProperty(device, key: kIOHIDPrimaryUsagePageKey as CFString) ?? 0
        let usage = intProperty(device, key: kIOHIDPrimaryUsageKey as CFString) ?? 0

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
}

public final class USBHIDControlSession {
    public let device: IOHIDDevice
    public let deviceID: String

    private var cachedTxn: UInt8?

    public init(device: IOHIDDevice, deviceID: String) {
        self.device = device
        self.deviceID = deviceID
    }

    public func invalidateCachedTransaction() {
        cachedTxn = nil
    }

    public func perform(
        classID: UInt8,
        cmdID: UInt8,
        size: UInt8,
        args: [UInt8],
        allowTxnRescan: Bool = true,
        responseAttempts: Int = 6,
        responseDelayUs: useconds_t = 35_000
    ) throws -> [UInt8]? {
        for txn in transactionCandidates(allowTxnRescan: allowTxnRescan) {
            let report = USBHIDProtocol.createReport(txn: txn, classID: classID, cmdID: cmdID, size: size, args: args)
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

    private func transactionCandidates(allowTxnRescan: Bool) -> [UInt8] {
        if let cachedTxn {
            return allowTxnRescan ? [cachedTxn, 0x1F, 0x3F, 0xFF] : [cachedTxn]
        }
        return [0x1F, 0x3F, 0xFF]
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
                throw BridgeError.commandFailed("USB HID access denied. Grant Input Monitoring and relaunch.")
            }
            return nil
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let setResult = report.withUnsafeBufferPointer { ptr -> IOReturn in
            guard let base = ptr.baseAddress else { return kIOReturnError }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(0), base, ptr.count)
        }
        guard setResult == kIOReturnSuccess else {
            if setResult == kIOReturnNotPermitted {
                throw BridgeError.commandFailed("USB HID access denied. Grant Input Monitoring and relaunch.")
            }
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
            if !USBHIDProtocol.isValidResponse(candidate, classID: expectedClassID, cmdID: expectedCmdID) { continue }
            return candidate
        }
        return nil
    }
}
