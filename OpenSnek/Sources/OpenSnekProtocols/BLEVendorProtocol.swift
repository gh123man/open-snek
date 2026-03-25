import Foundation
import OpenSnekCore

public enum BLEVendorProtocol {
    public static let serviceUUID = UUID(uuidString: "52401523-F97C-7F90-0E7F-6C6F4E36DB1C")!
    public static let writeUUID = UUID(uuidString: "52401524-F97C-7F90-0E7F-6C6F4E36DB1C")!
    public static let notifyUUID = UUID(uuidString: "52401525-F97C-7F90-0E7F-6C6F4E36DB1C")!

    public struct Key: Equatable, Sendable {
        public let b0: UInt8
        public let b1: UInt8
        public let b2: UInt8
        public let b3: UInt8

        public init(b0: UInt8, b1: UInt8, b2: UInt8, b3: UInt8) {
            self.b0 = b0
            self.b1 = b1
            self.b2 = b2
            self.b3 = b3
        }

        public var bytes: [UInt8] { [b0, b1, b2, b3] }

        public static let dpiStagesGet = Key(b0: 0x0B, b1: 0x84, b2: 0x01, b3: 0x00)
        public static let dpiStagesSet = Key(b0: 0x0B, b1: 0x04, b2: 0x01, b3: 0x00)
        public static let lightingZonesGet = Key(b0: 0x10, b1: 0x80, b2: 0x00, b3: 0x01)
        public static let lightingGet = lightingBrightnessGet()
        public static let lightingSet = lightingBrightnessSet()
        public static let lightingModeSet = Key(b0: 0x10, b1: 0x03, b2: 0x00, b3: 0x00)
        public static let lightingFrameGet = Key(b0: 0x10, b1: 0x84, b2: 0x00, b3: 0x00)
        public static let lightingFrameSet = Key(b0: 0x10, b1: 0x04, b2: 0x00, b3: 0x00)
        public static let powerTimeoutGet = Key(b0: 0x05, b1: 0x84, b2: 0x00, b3: 0x00)
        public static let powerTimeoutSet = Key(b0: 0x05, b1: 0x04, b2: 0x00, b3: 0x00)
        public static let batteryRaw = Key(b0: 0x05, b1: 0x81, b2: 0x00, b3: 0x01)
        public static let batteryStatus = Key(b0: 0x05, b1: 0x80, b2: 0x00, b3: 0x01)

        public static func buttonBind(slot: UInt8) -> Key {
            Key(b0: 0x08, b1: 0x04, b2: 0x01, b3: slot)
        }

        public static func lightingBrightnessGet(ledID: UInt8 = 0x01) -> Key {
            Key(b0: 0x10, b1: 0x85, b2: 0x01, b3: ledID)
        }

        public static func lightingBrightnessSet(ledID: UInt8 = 0x00) -> Key {
            Key(b0: 0x10, b1: 0x05, b2: 0x01, b3: ledID)
        }

        public static func lightingZoneStateGet(ledID: UInt8) -> Key {
            Key(b0: 0x10, b1: 0x83, b2: 0x00, b3: ledID)
        }

        public static func lightingZoneStateSet(ledID: UInt8) -> Key {
            Key(b0: 0x10, b1: 0x03, b2: 0x00, b3: ledID)
        }
    }

    public struct NotifyHeader: Equatable, Sendable {
        public let req: UInt8
        public let payloadLength: Int
        public let status: UInt8

        public init?(data: Data) {
            guard data.count >= 8 else { return nil }
            req = data[0]
            payloadLength = Int(data[1])
            status = data[7]
        }
    }

    public static func buildReadHeader(req: UInt8, key: Key) -> Data {
        Data([req, 0x00, 0x00, 0x00] + key.bytes)
    }

    public static func buildWriteHeader(req: UInt8, payloadLength: UInt8, key: Key) -> Data {
        Data([req, payloadLength, 0x00, 0x00] + key.bytes)
    }

    public static func parsePayloadFrames(notifies: [Data], req: UInt8) -> Data? {
        guard let headerIndex = notifies.firstIndex(where: { frame in
            guard let hdr = NotifyHeader(data: frame) else { return false }
            return hdr.req == req && [0x02, 0x03, 0x05].contains(hdr.status)
        }), let header = NotifyHeader(data: notifies[headerIndex]), header.status == 0x02 else {
            return nil
        }

        let continuation: [Data]
        if headerIndex + 1 < notifies.count {
            continuation = Array(notifies[(headerIndex + 1)...]).filter { !$0.isEmpty }
        } else {
            continuation = []
        }

        let payload: Data
        if continuation.isEmpty, header.payloadLength > 0 {
            payload = Data(notifies[headerIndex].dropFirst(8))
        } else {
            payload = continuation.reduce(into: Data()) { partialResult, frame in
                partialResult.append(frame)
            }
        }
        if header.payloadLength == 0 { return Data() }
        return payload.prefix(header.payloadLength)
    }

    public static func parseDpiStageSnapshot(blob: Data) -> (active: Int, count: Int, slots: [Int], pairs: [DpiPair], stageIDs: [UInt8], marker: UInt8)? {
        if blob.count >= 9 {
            let activeRaw = Int(blob[0])
            let declaredCount = max(1, min(5, Int(blob[1])))
            var slots: [Int] = []
            var pairs: [DpiPair] = []
            var stageIDs: [UInt8] = []
            var marker: UInt8 = 0x03

            for i in 0..<declaredCount {
                let off = 2 + (i * 7)
                guard off + 4 < blob.count else { break }
                let x = Int(blob[off + 1]) | (Int(blob[off + 2]) << 8)
                let y = Int(blob[off + 3]) | (Int(blob[off + 4]) << 8)
                slots.append(x)
                pairs.append(DpiPair(x: x, y: y))
                stageIDs.append(blob[off])
                if off + 6 < blob.count {
                    marker = blob[off + 6]
                }
            }

            if slots.isEmpty {
                return nil
            }
            while slots.count < declaredCount {
                let fallback = pairs.last ?? DpiPair(x: slots.last ?? 800, y: slots.last ?? 800)
                slots.append(fallback.x)
                pairs.append(fallback)
                stageIDs.append(stageIDs.last.map { $0 &+ 1 } ?? UInt8(stageIDs.count))
            }
            while slots.count < 5 {
                let fallback = pairs.last ?? DpiPair(x: slots.last ?? 800, y: slots.last ?? 800)
                slots.append(fallback.x)
                pairs.append(fallback)
                stageIDs.append(stageIDs.last.map { $0 &+ 1 } ?? UInt8(stageIDs.count))
            }

            let count = min(declaredCount, slots.count)
            let visibleIDs = Array(stageIDs.prefix(count))
            let active = resolveActiveStage(activeRaw: activeRaw, stageIDs: visibleIDs, count: count)
            return (
                active: active,
                count: count,
                slots: Array(slots.prefix(5)),
                pairs: Array(pairs.prefix(5)),
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
            let pair = DpiPair(x: value, y: value)
            return (
                active: active,
                count: count,
                slots: Array(repeating: value, count: 5),
                pairs: Array(repeating: pair, count: 5),
                stageIDs: Array(repeating: sid, count: 5),
                marker: 0x03
            )
        }

        return nil
    }

    public static func parseDpiStages(blob: Data) -> (active: Int, count: Int, values: [Int], pairs: [DpiPair], marker: UInt8)? {
        guard let snapshot = parseDpiStageSnapshot(blob: blob) else { return nil }
        return (
            active: snapshot.active,
            count: snapshot.count,
            values: Array(snapshot.slots.prefix(snapshot.count)),
            pairs: Array(snapshot.pairs.prefix(snapshot.count)),
            marker: snapshot.marker
        )
    }

    public static func mergedStageSlots(currentSlots: [Int], requestedCount: Int, requestedValues: [Int]) -> [Int] {
        mergedStagePairs(
            currentPairs: currentSlots.map { DpiPair(x: $0, y: $0) },
            requestedCount: requestedCount,
            requestedPairs: requestedValues.map { DpiPair(x: $0, y: $0) }
        ).map(\.x)
    }

    public static func mergedStagePairs(currentPairs: [DpiPair], requestedCount: Int, requestedPairs: [DpiPair]) -> [DpiPair] {
        let count = max(1, min(5, requestedCount))
        let clamped = requestedPairs.map { pair in
            DpiPair(
                x: max(100, min(30000, pair.x)),
                y: max(100, min(30000, pair.y))
            )
        }
        var pairs = Array(currentPairs.prefix(5))
        if pairs.count < 5 {
            pairs += Array(repeating: clamped.first ?? DpiPair(x: 800, y: 800), count: 5 - pairs.count)
        }

        if count == 1 {
            let single = clamped.first ?? pairs[0]
            return Array(repeating: single, count: 5)
        }

        for i in 0..<count {
            if i < clamped.count {
                pairs[i] = clamped[i]
            }
        }
        return Array(pairs.prefix(5))
    }

    public static func buildDpiStagePayload(active: Int, count: Int, slots: [Int], marker: UInt8, stageIDs: [UInt8]? = nil) -> Data {
        buildDpiStagePayload(
            active: active,
            count: count,
            pairs: slots.map { DpiPair(x: $0, y: $0) },
            marker: marker,
            stageIDs: stageIDs
        )
    }

    public static func buildDpiStagePayload(active: Int, count: Int, pairs: [DpiPair], marker: UInt8, stageIDs: [UInt8]? = nil) -> Data {
        let clippedCount = max(1, min(5, count))
        var ids = Array((stageIDs ?? [0, 1, 2, 3, 4]).prefix(5))
        while ids.count < 5 {
            ids.append(ids.last.map { $0 &+ 1 } ?? UInt8(ids.count))
        }
        let activeIndex = max(0, min(clippedCount - 1, active))
        var out = Data([ids[activeIndex], UInt8(clippedCount)])
        let clamped = pairs.map { pair in
            DpiPair(
                x: max(100, min(30000, pair.x)),
                y: max(100, min(30000, pair.y))
            )
        }

        for i in 0..<5 {
            let pair = clamped[min(i, max(0, clamped.count - 1))]
            let xLo = UInt8(pair.x & 0xFF)
            let xHi = UInt8((pair.x >> 8) & 0xFF)
            let yLo = UInt8(pair.y & 0xFF)
            let yHi = UInt8((pair.y >> 8) & 0xFF)
            out.append(ids[i])
            out.append(xLo)
            out.append(xHi)
            out.append(yLo)
            out.append(yHi)
            out.append(0x00)
            out.append(i == 4 ? marker : 0x00)
        }
        out.append(0x00)
        return out
    }

    public static func buildButtonPayload(
        slot: UInt8,
        kind: ButtonBindingKind,
        hidKey: UInt8?,
        turboEnabled: Bool = false,
        turboRate: UInt16? = nil
    ) -> Data {
        let clampedTurboRate = max(UInt16(1), min(UInt16(0x00FF), turboRate ?? 0x008E))
        if turboEnabled {
            if kind == .keyboardSimple {
                let key = hidKey ?? 0x04
                return Data([0x01, slot, 0x00, 0x0D, 0x04, 0x00, key, 0x00, UInt8(clampedTurboRate & 0xFF), UInt8((clampedTurboRate >> 8) & 0xFF)])
            }
            if let buttonID = mouseButtonID(for: kind) {
                let index = UInt16(max(0, Int(buttonID) - 1))
                let p0 = UInt16((index << 8) | 0x0003)
                return Data([0x01, slot, 0x00, 0x0E, UInt8(p0 & 0xFF), UInt8((p0 >> 8) & 0xFF), UInt8(clampedTurboRate & 0xFF), UInt8((clampedTurboRate >> 8) & 0xFF), 0x00, 0x00])
            }
        }

        switch kind {
        case .default:
            if slot == 0x60 {
                return Data([0x01, slot, 0x00, 0x06, 0x01, 0x06, 0x00, 0x00, 0x00, 0x00])
            }
            if let buttonID = defaultMouseButtonID(forSlot: slot) {
                return Data([0x01, slot, 0x00, 0x01, 0x01, buttonID, 0x00, 0x00, 0x00, 0x00])
            }
            return Data([0x01, slot, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        case .dpiCycle:
            return Data([0x01, slot, 0x00, 0x06, 0x01, 0x06, 0x00, 0x00, 0x00, 0x00])
        case .dpiClutch:
            // This action is only validated on the V3 Pro USB path.
            return Data([0x01, slot, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        case .leftClick:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00])
        case .rightClick:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00])
        case .middleClick:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00, 0x00])
        case .scrollUp:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x09, 0x00, 0x00, 0x00, 0x00])
        case .scrollDown:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x0A, 0x00, 0x00, 0x00, 0x00])
        case .scrollLeft:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x68, 0x00, 0x00, 0x00, 0x00])
        case .scrollRight:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x69, 0x00, 0x00, 0x00, 0x00])
        case .mouseBack:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00])
        case .mouseForward:
            return Data([0x01, slot, 0x00, 0x01, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00])
        case .keyboardSimple:
            return Data([0x01, slot, 0x00, 0x02, 0x02, 0x00, hidKey ?? 0x04, 0x00, 0x00, 0x00])
        case .clearLayer:
            return Data([0x01, slot, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        }
    }

    public static func buildScrollLEDEffectArgs(effect: LightingEffectPatch, ledID: UInt8 = 0x01) -> [UInt8] {
        switch effect.kind {
        case .off:
            return [0x01, ledID, 0x00, 0x00, 0x00, 0x00]
        case .staticColor:
            return [0x01, ledID, 0x01, 0x00, 0x00, 0x01, UInt8(effect.primary.r), UInt8(effect.primary.g), UInt8(effect.primary.b)]
        case .spectrum:
            return [0x01, ledID, 0x03, 0x00, 0x00, 0x00]
        case .wave:
            return [0x01, ledID, 0x04, UInt8(effect.waveDirection.rawValue), 0x28, 0x00]
        case .reactive:
            return [0x01, ledID, 0x05, 0x00, UInt8(max(1, min(4, effect.reactiveSpeed))), 0x01, UInt8(effect.primary.r), UInt8(effect.primary.g), UInt8(effect.primary.b)]
        case .pulseRandom:
            return [0x01, ledID, 0x02, 0x00, 0x00, 0x00]
        case .pulseSingle:
            return [0x01, ledID, 0x02, 0x01, 0x00, 0x01, UInt8(effect.primary.r), UInt8(effect.primary.g), UInt8(effect.primary.b)]
        case .pulseDual:
            return [0x01, ledID, 0x02, 0x02, 0x00, 0x02, UInt8(effect.primary.r), UInt8(effect.primary.g), UInt8(effect.primary.b), UInt8(effect.secondary.r), UInt8(effect.secondary.g), UInt8(effect.secondary.b)]
        }
    }

    public static func parseLightingLEDIDs(blob: Data) -> [UInt8]? {
        guard !blob.isEmpty else { return nil }
        var seen: Set<UInt8> = []
        var ids: [UInt8] = []
        for value in blob where !seen.contains(value) {
            seen.insert(value)
            ids.append(value)
        }
        return ids.isEmpty ? nil : ids
    }

    public static func buildV3ProLightingZoneStatePayload(r: Int, g: Int, b: Int) -> Data {
        Data([
            0x01, 0x00, 0x00, 0x01,
            UInt8(max(0, min(255, r))),
            UInt8(max(0, min(255, g))),
            UInt8(max(0, min(255, b))),
            0x00, 0x00, 0x00,
        ])
    }

    public static func parseV3ProLightingZoneStatePayload(_ payload: Data) -> RGBPatch? {
        guard payload.count >= 10 else { return nil }
        guard payload[0] == 0x01, payload[1] == 0x00, payload[2] == 0x00, payload[3] == 0x01 else {
            return nil
        }
        return RGBPatch(r: Int(payload[4]), g: Int(payload[5]), b: Int(payload[6]))
    }

    public static func resolveActiveStage(activeRaw: Int, stageIDs: [UInt8], count: Int) -> Int {
        guard count > 0 else { return 0 }
        if let mapped = stageIDs.firstIndex(of: UInt8(activeRaw & 0xFF)) {
            return mapped
        }
        if activeRaw >= 1, activeRaw <= count {
            return activeRaw - 1
        }
        return max(0, min(count - 1, activeRaw))
    }

    public static func mouseButtonID(for kind: ButtonBindingKind) -> UInt8? {
        switch kind {
        case .leftClick: return 0x01
        case .rightClick: return 0x02
        case .middleClick: return 0x03
        case .mouseBack: return 0x04
        case .mouseForward: return 0x05
        case .scrollUp: return 0x09
        case .scrollDown: return 0x0A
        case .scrollLeft: return 0x68
        case .scrollRight: return 0x69
        default: return nil
        }
    }

    public static func defaultMouseButtonID(forSlot slot: UInt8) -> UInt8? {
        switch slot {
        case 1: return 0x01
        case 2: return 0x02
        case 3: return 0x03
        case 4: return 0x04
        case 5: return 0x05
        case 9: return 0x09
        case 10: return 0x0A
        case 0x34: return 0x68
        case 0x35: return 0x69
        default: return nil
        }
    }

}
