import Foundation

enum BLEVendorProtocol {
    static let serviceUUID = UUID(uuidString: "52401523-F97C-7F90-0E7F-6C6F4E36DB1C")!
    static let writeUUID = UUID(uuidString: "52401524-F97C-7F90-0E7F-6C6F4E36DB1C")!
    static let notifyUUID = UUID(uuidString: "52401525-F97C-7F90-0E7F-6C6F4E36DB1C")!

    struct Key: Equatable {
        let b0: UInt8
        let b1: UInt8
        let b2: UInt8
        let b3: UInt8

        var bytes: [UInt8] { [b0, b1, b2, b3] }

        static let dpiStagesGet = Key(b0: 0x0B, b1: 0x84, b2: 0x01, b3: 0x00)
        static let dpiStagesSet = Key(b0: 0x0B, b1: 0x04, b2: 0x01, b3: 0x00)
        static let lightingGet = Key(b0: 0x10, b1: 0x85, b2: 0x01, b3: 0x01)
        static let lightingSet = Key(b0: 0x10, b1: 0x05, b2: 0x01, b3: 0x00)
        static let lightingFrameGet = Key(b0: 0x10, b1: 0x84, b2: 0x00, b3: 0x00)
        static let lightingFrameSet = Key(b0: 0x10, b1: 0x04, b2: 0x00, b3: 0x00)
        static let powerTimeoutGet = Key(b0: 0x05, b1: 0x84, b2: 0x00, b3: 0x00)
        static let powerTimeoutSet = Key(b0: 0x05, b1: 0x04, b2: 0x00, b3: 0x00)
        static let batteryRaw = Key(b0: 0x05, b1: 0x81, b2: 0x00, b3: 0x01)
        static let batteryStatus = Key(b0: 0x05, b1: 0x80, b2: 0x00, b3: 0x01)

        static func buttonBind(slot: UInt8) -> Key {
            Key(b0: 0x08, b1: 0x04, b2: 0x01, b3: slot)
        }
    }

    struct NotifyHeader: Equatable {
        let req: UInt8
        let payloadLength: Int
        let status: UInt8

        init?(data: Data) {
            guard data.count == 20 else { return nil }
            req = data[0]
            payloadLength = Int(data[1])
            status = data[7]
        }
    }

    static func buildReadHeader(req: UInt8, key: Key) -> Data {
        Data([req, 0x00, 0x00, 0x00] + key.bytes)
    }

    static func buildWriteHeader(req: UInt8, payloadLength: UInt8, key: Key) -> Data {
        Data([req, payloadLength, 0x00, 0x00] + key.bytes)
    }

    static func parsePayloadFrames(notifies: [Data], req: UInt8) -> Data? {
        guard let headerIndex = notifies.firstIndex(where: { frame in
            guard let hdr = NotifyHeader(data: frame) else { return false }
            return hdr.req == req && [0x02, 0x03, 0x05].contains(hdr.status)
        }), let header = NotifyHeader(data: notifies[headerIndex]), header.status == 0x02 else {
            return nil
        }

        let continuation: [Data]
        if headerIndex + 1 < notifies.count {
            continuation = Array(notifies[(headerIndex + 1)...]).filter { $0.count == 20 }
        } else {
            continuation = []
        }
        let payload: Data
        if continuation.isEmpty, header.payloadLength > 0 {
            // Some short responses arrive as a single notify frame with payload
            // bytes appended after the 8-byte header.
            payload = Data(notifies[headerIndex].dropFirst(8))
        } else {
            payload = continuation.reduce(into: Data()) { partialResult, frame in
                partialResult.append(frame)
            }
        }
        if header.payloadLength == 0 { return Data() }
        return payload.prefix(header.payloadLength)
    }

    static func parseDpiStageSnapshot(blob: Data) -> (active: Int, count: Int, slots: [Int], stageIDs: [UInt8], marker: UInt8)? {
        // Variable-length staged blob:
        // [active][count] + count*7-byte stage entries
        // each entry: [stage_id][dpi_x_le16][dpi_y_le16][reserved][marker_or_reserved]
        if blob.count >= 9 {
            let activeRaw = Int(blob[0])
            let declaredCount = max(1, min(5, Int(blob[1])))
            var slots: [Int] = []
            var stageIDs: [UInt8] = []
            var marker: UInt8 = 0x03

            for i in 0..<declaredCount {
                let off = 2 + (i * 7)
                // Capture-backed reads can report payload length one byte short,
                // dropping the last entry marker. Parse as long as DPI X/Y bytes exist.
                guard off + 4 < blob.count else { break }
                let value = Int(blob[off + 1]) | (Int(blob[off + 2]) << 8)
                // On validated firmware, stage_id bytes are not a stable user-stage ordinal
                // across all count modes. Preserve wire entry order for stage semantics.
                slots.append(value)
                stageIDs.append(blob[off])
                if off + 6 < blob.count {
                    marker = blob[off + 6]
                }
            }

            if slots.isEmpty {
                return nil
            }
            while slots.count < declaredCount {
                slots.append(slots.last ?? 800)
                stageIDs.append(stageIDs.last.map { $0 &+ 1 } ?? UInt8(stageIDs.count))
            }
            while slots.count < 5 {
                slots.append(slots.last ?? 800)
                stageIDs.append(stageIDs.last.map { $0 &+ 1 } ?? UInt8(stageIDs.count))
            }

            let count = min(declaredCount, slots.count)
            let visibleIDs = Array(stageIDs.prefix(count))
            let active: Int
            if let mapped = visibleIDs.firstIndex(of: UInt8(activeRaw & 0xFF)) {
                active = mapped
            } else if activeRaw >= 1, activeRaw <= count {
                active = activeRaw - 1
            } else {
                active = max(0, min(count - 1, activeRaw))
            }
            return (
                active: active,
                count: count,
                slots: Array(slots.prefix(5)),
                stageIDs: Array(stageIDs.prefix(5)),
                marker: marker
            )
        }

        if blob.count >= 7 {
            let activeRaw = Int(blob[0])
            let count = max(1, min(5, Int(blob[1])))
            let value = Int(blob[3]) | (Int(blob[4]) << 8)
            let active = activeRaw >= 1 ? max(0, min(count - 1, activeRaw - 1)) : 0
            let sid = blob.count > 2 ? blob[2] : 0
            return (
                active: active,
                count: count,
                slots: Array(repeating: value, count: 5),
                stageIDs: Array(repeating: sid, count: 5),
                marker: 0x03
            )
        }

        return nil
    }

    static func parseDpiStages(blob: Data) -> (active: Int, count: Int, values: [Int], marker: UInt8)? {
        guard let snapshot = parseDpiStageSnapshot(blob: blob) else { return nil }
        return (
            active: snapshot.active,
            count: snapshot.count,
            values: Array(snapshot.slots.prefix(snapshot.count)),
            marker: snapshot.marker
        )
    }

    static func mergedStageSlots(currentSlots: [Int], requestedCount: Int, requestedValues: [Int]) -> [Int] {
        let count = max(1, min(5, requestedCount))
        let clamped = requestedValues.map { max(100, min(30000, $0)) }
        var slots = Array(currentSlots.prefix(5))
        if slots.count < 5 {
            slots += Array(repeating: clamped.first ?? 800, count: 5 - slots.count)
        }

        if count == 1 {
            let single = clamped.first ?? slots[0]
            return Array(repeating: single, count: 5)
        }

        for i in 0..<count {
            if i < clamped.count {
                slots[i] = clamped[i]
            }
        }
        return Array(slots.prefix(5))
    }

    static func buildDpiStagePayload(active: Int, count: Int, slots: [Int], marker: UInt8, stageIDs: [UInt8]? = nil) -> Data {
        let clippedCount = max(1, min(5, count))
        var ids = Array((stageIDs ?? [0, 1, 2, 3, 4]).prefix(5))
        while ids.count < 5 {
            ids.append(ids.last.map { $0 &+ 1 } ?? UInt8(ids.count))
        }
        let activeIndex = max(0, min(clippedCount - 1, active))
        var out = Data([ids[activeIndex], UInt8(clippedCount)])
        let clamped = slots.map { max(100, min(30000, $0)) }

        for i in 0..<5 {
            let value = clamped[min(i, max(0, clamped.count - 1))]
            let lo = UInt8(value & 0xFF)
            let hi = UInt8((value >> 8) & 0xFF)
            out.append(ids[i])
            out.append(lo)
            out.append(hi)
            out.append(lo)
            out.append(hi)
            out.append(0x00)
            out.append(i == 4 ? marker : 0x00)
        }
        out.append(0x00)
        return out
    }

    static func buildButtonPayload(slot: UInt8, kind: ButtonBindingKind, hidKey: UInt8?) -> Data {
        switch kind {
        case .default:
            // Capture-backed default restore variants:
            // - slot 0x02 uses explicit right-click payload
            // - slot 0x60 (DPI cycle button) uses action 0x06 payload
            if slot == 0x02 {
                return Data([0x01, slot, 0x00, 0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00])
            }
            if slot == 0x60 {
                return Data([0x01, slot, 0x00, 0x06, 0x01, 0x06, 0x00, 0x00, 0x00, 0x00])
            }
            return Data([0x01, slot, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        case .leftClick:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00])
        case .rightClick:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00])
        case .middleClick:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00, 0x00])
        case .scrollUp:
            // scroll-up-down-rebind.pcapng: slot 0x09 payload uses p0=0x0901
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x09, 0x00, 0x00, 0x00, 0x00])
        case .scrollDown:
            // scroll-up-down-rebind.pcapng: slot 0x0A payload uses p0=0x0A01
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x0A, 0x00, 0x00, 0x00, 0x00])
        case .mouseBack:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00])
        case .mouseForward:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00])
        case .keyboardSimple:
            let key = hidKey ?? 0x04
            return Data([0x01, slot, 0x00, 0x02, 0x02, 0x00, key, 0x00, 0x00, 0x00])
        case .clearLayer:
            return Data([0x01, slot, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        }
    }
}
