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

final class USBProbeClient {
    private let usbVID = 0x1532
    private let manager: IOHIDManager
    private let session: USBHIDControlSession
    private let deviceID: String
    private let productID: Int
    private let profileID: DeviceProfileID?

    init(productID preferredProductID: Int? = nil) throws {
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
                USBHIDSupport.intProperty(candidate, key: kIOHIDVendorIDKey as CFString) == usbVID,
                let product = USBHIDSupport.intProperty(candidate, key: kIOHIDProductIDKey as CFString)
            else { continue }
            if let preferredProductID, product != preferredProductID { continue }
            let transport = (USBHIDSupport.stringProperty(candidate, key: kIOHIDTransportKey as CFString) ?? "").lowercased()
            if transport.contains("bluetooth") { continue }

            let location = USBHIDSupport.intProperty(candidate, key: kIOHIDLocationIDKey as CFString) ?? 0
            let id = String(format: "%04x:%04x:%08x:usb", usbVID, product, location)
            let score = USBHIDSupport.handlePreferenceScore(device: candidate)
            if best == nil || score > best!.score {
                best = (score: score, device: candidate, id: id, pid: product)
            }
        }

        guard let best else {
            if let preferredProductID {
                throw ProbeError.protocolError(
                    "No non-Bluetooth USB Razer HID control interface found for pid 0x\(String(format: "%04x", preferredProductID))"
                )
            }
            throw ProbeError.protocolError("No non-Bluetooth USB Razer HID control interface found")
        }

        self.manager = manager
        self.session = USBHIDControlSession(device: best.device, deviceID: best.id)
        self.deviceID = best.id
        self.productID = best.pid
        self.profileID = DeviceProfiles.resolve(vendorID: usbVID, productID: best.pid, transport: .usb)?.id
    }

    func describe() -> String {
        "\(deviceID) pid=0x\(String(format: "%04x", productID))"
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
