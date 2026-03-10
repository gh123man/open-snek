import Foundation
import OpenSnekCore
import OpenSnekHardware
import OpenSnekProtocols

extension BridgeClient {
    func readBluetoothState(device: MouseDevice, session: USBHIDControlSession?) async throws -> MouseState {
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
        } else if let session {
            batteryPct = (try? getBattery(session, device))??.0
        } else {
            batteryPct = nil
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

    func buildBluetoothDeltaState(
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

    func nextBTReq() -> UInt8 {
        defer { btReqID = btReqID &+ 1 }
        return btReqID
    }

    func btExchange(_ writes: [Data], timeout: TimeInterval = 0.8) async throws -> [Data] {
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

    func btAcquireExchangeLock() async {
        if !btExchangeLocked {
            btExchangeLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            btExchangeWaiters.append(continuation)
        }
    }

    func btReleaseExchangeLock() {
        if btExchangeWaiters.isEmpty {
            btExchangeLocked = false
            return
        }
        let next = btExchangeWaiters.removeFirst()
        next.resume()
    }

    func btGetScalar(key: BLEVendorProtocol.Key, size: Int) async throws -> Int? {
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

    func btSetScalar(key: BLEVendorProtocol.Key, value: Int, size: Int, payloadLength: UInt8) async throws -> Bool {
        let req = nextBTReq()
        let header = BLEVendorProtocol.buildWriteHeader(req: req, payloadLength: payloadLength, key: key)
        let payload = Data((0..<size).map { idx in UInt8((value >> (8 * idx)) & 0xFF) })
        let notifies = try await btExchange([header, payload], timeout: 0.9)
        return btAckSuccess(notifies: notifies, req: req)
    }

    func btAckSuccess(notifies: [Data], req: UInt8) -> Bool {
        for frame in notifies {
            guard let header = BLEVendorProtocol.NotifyHeader(data: frame) else { continue }
            if header.req == req {
                return header.status == 0x02
            }
        }
        return false
    }

    func btGetDpiStages(deviceID: String) async throws -> (active: Int, values: [Int], marker: UInt8)? {
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

    func btGetDpiStageSnapshot(deviceID: String) async throws -> (active: Int, count: Int, slots: [Int], stageIDs: [UInt8], marker: UInt8)? {
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

    func btSetDpiStages(deviceID: String, active: Int, values: [Int]) async throws -> Bool {
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

    func btSetLightingValue(value: Int) async throws -> Bool {
        try await btSetScalar(key: .lightingSet, value: max(0, min(255, value)), size: 1, payloadLength: 0x01)
    }

    func btSetLightingRGB(r: Int, g: Int, b: Int) async throws -> Bool {
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

    func btApplyLightingEffectFallback(effect: LightingEffectPatch) async throws -> Bool {
        switch effect.kind {
        case .off:
            return try await btSetLightingValue(value: 0)
        case .staticColor:
            return try await btSetLightingRGB(r: effect.primary.r, g: effect.primary.g, b: effect.primary.b)
        case .spectrum, .wave, .reactive, .pulseRandom, .pulseSingle, .pulseDual:
            return false
        }
    }

    func parseLightingRGB(payload: Data) -> RGBPatch? {
        guard !payload.isEmpty else { return nil }

        if payload.count >= 8, payload[0] == 0x04 {
            return RGBPatch(r: Int(payload[5]), g: Int(payload[6]), b: Int(payload[7]))
        }
        if payload.count >= 4 {
            return RGBPatch(r: Int(payload[1]), g: Int(payload[2]), b: Int(payload[3]))
        }
        return nil
    }

    func btSetButtonBinding(
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
}
