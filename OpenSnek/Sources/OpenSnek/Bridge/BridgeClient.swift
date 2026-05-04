import Foundation
import IOKit.hid
import OpenSnekAppSupport
import OpenSnekCore
import OpenSnekHardware
import OpenSnekProtocols

actor BridgeClient {
    typealias USBDpiStageSnapshot = (active: Int, values: [Int], pairs: [DpiPair], stageIDs: [UInt8])
    typealias BluetoothExpectedDpiState = (
        active: Int,
        values: [Int],
        pairs: [DpiPair],
        previousActive: Int?,
        previousValues: [Int]?,
        previousPairs: [DpiPair]?,
        expiresAt: Date,
        remainingMasks: Int
    )
    static let bluetoothPassiveResetSilenceInterval: TimeInterval = 1.0
    static let bluetoothPassiveHeartbeatHealthyInterval: TimeInterval = 1.5
    static let usbReconnectSettleInterval: TimeInterval = 2.0

    var deviceSessions: [String: USBHIDControlSession] = [:]
    var deviceSessionCandidates: [String: [USBHIDControlSession]] = [:]
    var lastStateByDeviceID: [String: MouseState] = [:]
    var usbReconnectSettleUntilByDeviceID: [String: Date] = [:]
    let devicePresenceEvents = BroadcastStream<HIDDevicePresenceEvent>()
    let passiveDpiEvents = BroadcastStream<PassiveDPIEvent>()
    let passiveDpiHeartbeatEvents = BroadcastStream<PassiveDPIHeartbeatEvent>()
    var passiveDpiArmedDeviceIDs: Set<String> = []
    var passiveDpiHeartbeatDeviceIDs: Set<String> = []
    var passiveDpiObservedDeviceIDs: Set<String> = []
    var passiveDpiLastHeartbeatAtByDeviceID: [String: Date] = [:]
    var passiveDpiLastObservedAtByDeviceID: [String: Date] = [:]
    var passiveDpiTargetIDsByDeviceID: [String: Set<String>] = [:]
    var passiveDpiTargetsByDeviceID: [String: [PassiveDPIEventMonitor.WatchTarget]] = [:]
    var passiveDpiUpgradeNotBeforeByDeviceID: [String: Date] = [:]
    var btReqID: UInt8 = 0x30
    var btDpiSnapshotByDeviceID: [String: (active: Int, count: Int, slots: [Int], pairs: [DpiPair], stageIDs: [UInt8], marker: UInt8)] = [:]
    var btExpectedDpiByDeviceID: [String: BluetoothExpectedDpiState] = [:]
    let btVendorClient = BLEVendorTransportClient()
    let hidDevicePresenceMonitor = HIDDevicePresenceMonitor()
    let passiveDpiMonitor = PassiveDPIEventMonitor()
    var btExchangeLocked = false
    var btExchangeWaiters: [CheckedContinuation<Void, Never>] = []
    var hidAccessDenied = false
    var managerAccessDenied = false
    var lastOpenDeniedLogAt: Date?

    let usbVID = 0x1532
    let btVID = 0x068E
    private var hidManager: IOHIDManager?
    private var hidManagerOpenResult: IOReturn?

    init(startHIDMonitoring: Bool = true) {
        hidDevicePresenceMonitor.onChange = { [weak self] event in
            Task {
                await self?.handleHIDDevicePresenceEvent(event)
            }
        }
        passiveDpiMonitor.onEvent = { [weak self] event in
            Task {
                await self?.handlePassiveDpiEvent(event)
            }
        }
        passiveDpiMonitor.onHeartbeat = { [weak self] event in
            Task {
                await self?.handlePassiveDpiHeartbeat(event)
            }
        }
        if startHIDMonitoring {
            hidDevicePresenceMonitor.start()
        }
    }

    func devicePresenceEventStream() -> AsyncStream<HIDDevicePresenceEvent> {
        devicePresenceEvents.makeStream()
    }

    private func handleHIDDevicePresenceEvent(_ event: HIDDevicePresenceEvent) {
        updateUSBReconnectSettleDeadline(for: event)
        AppLog.event(
            "Bridge",
            "hidPresence change=\(event.change.rawValue) device=\(event.deviceID)"
        )
        invalidateDiscoveryState(for: event.deviceID, reason: "hid-\(event.change.rawValue)")
        devicePresenceEvents.yield(event)
    }

    private func invalidateDiscoveryState(for deviceID: String, reason: String) {
        deviceSessions.removeValue(forKey: deviceID)
        deviceSessionCandidates.removeValue(forKey: deviceID)
        lastStateByDeviceID.removeValue(forKey: deviceID)
        passiveDpiArmedDeviceIDs.remove(deviceID)
        passiveDpiHeartbeatDeviceIDs.remove(deviceID)
        passiveDpiLastHeartbeatAtByDeviceID.removeValue(forKey: deviceID)
        passiveDpiLastObservedAtByDeviceID.removeValue(forKey: deviceID)
        passiveDpiTargetIDsByDeviceID.removeValue(forKey: deviceID)
        passiveDpiTargetsByDeviceID.removeValue(forKey: deviceID)
        passiveDpiUpgradeNotBeforeByDeviceID.removeValue(forKey: deviceID)
        clearPassiveDpiObservation(deviceID: deviceID, reason: reason)
        clearManagedHIDManager()
    }

    private func managedHIDManager() -> (manager: IOHIDManager, openResult: IOReturn) {
        if let hidManager, let hidManagerOpenResult, hidManagerOpenResult == kIOReturnSuccess {
            return (hidManager, hidManagerOpenResult)
        }

        clearManagedHIDManager()

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDVendorIDKey: usbVID] as CFDictionary,
            [kIOHIDVendorIDKey: btVID] as CFDictionary,
        ] as CFArray)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        managerAccessDenied = openResult == kIOReturnNotPermitted
        if openResult != kIOReturnSuccess {
            AppLog.error("Bridge", "IOHIDManagerOpen failed (\(openResult)); continuing best-effort discovery")
            if openResult == kIOReturnNotPermitted {
                AppLog.error(
                    "Bridge",
                    "IOHID access not permitted; USB access may be blocked unless Input Monitoring permission is granted"
                )
            }
        }

        hidManager = manager
        hidManagerOpenResult = openResult
        return (manager, openResult)
    }

    private func clearManagedHIDManager() {
        if let hidManager {
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.hidManager = nil
        }
        hidManagerOpenResult = nil
        managerAccessDenied = false
    }

    func hidAccessStatus(forceRefresh: Bool = true) -> HIDAccessStatus {
        if forceRefresh {
            AppLog.debug("Bridge", "hidAccessStatus forcing IOHIDManager refresh")
            clearManagedHIDManager()
        } else {
            AppLog.debug("Bridge", "hidAccessStatus reusing shared IOHIDManager")
        }

        let (_, openResult) = managedHIDManager()
        let authorization: HIDAccessAuthorization
        let detail: String?

        switch openResult {
        case kIOReturnSuccess:
            authorization = .granted
            detail = nil
        case kIOReturnNotPermitted:
            authorization = .denied
            detail = "Input Monitoring is required before macOS will allow HID listeners and feature-report access."
        default:
            authorization = .unavailable
            detail = "IOHIDManagerOpen failed (\(openResult))."
        }

        return HIDAccessStatus(
            authorization: authorization,
            hostLabel: PermissionSupport.currentHostLabel(),
            bundleIdentifier: Bundle.main.bundleIdentifier,
            detail: detail
        )
    }

    func listDevices() async throws -> [MouseDevice] {
        let start = Date()
        let (manager, openResult) = managedHIDManager()
        let connectedBluetoothPeripheralNames = await btVendorClient.connectedPeripheralSummaries()?.map(\.name)

        let devices: [IOHIDDevice]
        if let set = IOHIDManagerCopyDevices(manager) {
            devices = (set as NSSet).allObjects.map { $0 as! IOHIDDevice }
        } else {
            devices = []
        }

        var modelsByID: [String: MouseDevice] = [:]
        var sessionsByID: [String: [(score: Int, session: USBHIDControlSession)]] = [:]
        var passiveDpiTargets: [PassiveDPIEventMonitor.WatchTarget] = []
        for device in devices {
            guard let vendor = USBHIDSupport.intProperty(device, key: kIOHIDVendorIDKey as CFString),
                  (vendor == usbVID || vendor == btVID),
                  let product = USBHIDSupport.intProperty(device, key: kIOHIDProductIDKey as CFString) else { continue }

            let name = USBHIDSupport.stringProperty(device, key: kIOHIDProductKey as CFString) ?? "Razer Mouse"
            let serial = USBHIDSupport.stringProperty(device, key: kIOHIDSerialNumberKey as CFString)
            let transportRaw = (USBHIDSupport.stringProperty(device, key: kIOHIDTransportKey as CFString) ?? "").lowercased()
            let transport: DeviceTransportKind = transportRaw.contains("bluetooth") || vendor == btVID ? .bluetooth : .usb
            if transport == .bluetooth,
               !Self.shouldIncludeBluetoothHIDDevice(
                hidDeviceName: name,
                connectedPeripheralNames: connectedBluetoothPeripheralNames
               ) {
                continue
            }
            let location = USBHIDSupport.intProperty(device, key: kIOHIDLocationIDKey as CFString) ?? 0
            let id = String(format: "%04x:%04x:%08x:%@", vendor, product, location, transport.rawValue)
            let profile = DeviceProfiles.resolve(vendorID: vendor, productID: product, transport: transport)

            let model = MouseDevice(
                id: id,
                vendor_id: vendor,
                product_id: product,
                product_name: name,
                transport: transport,
                path_b64: "",
                serial: serial,
                firmware: nil,
                location_id: location,
                profile_id: profile?.id,
                button_layout: profile?.buttonLayout,
                supports_advanced_lighting_effects: profile?.supportsAdvancedLightingEffects ?? false,
                onboard_profile_count: profile?.onboardProfileCount ?? 1
            )
            if modelsByID[id] == nil {
                modelsByID[id] = model
            }

            if let passiveTarget = passiveDpiWatchTarget(
                for: device,
                deviceID: id,
                profile: profile,
                transport: transport
            ) {
                passiveDpiTargets.append(passiveTarget)
            }

            let score = USBHIDSupport.handlePreferenceScore(device: device)
            sessionsByID[id, default: []].append((score: score, session: USBHIDControlSession(device: device, deviceID: id)))
        }
        var preferredSessionsByID: [String: USBHIDControlSession] = [:]
        var candidatesByID: [String: [USBHIDControlSession]] = [:]
        for (id, scoredHandles) in sessionsByID {
            let sorted = scoredHandles.sorted { lhs, rhs in
                if lhs.score == rhs.score { return false }
                return lhs.score > rhs.score
            }
            let sessions = sorted.map(\.session)
            candidatesByID[id] = sessions
            if let first = sessions.first {
                preferredSessionsByID[id] = first
            }
        }
        deviceSessionCandidates = candidatesByID
        deviceSessions = preferredSessionsByID
        await updatePassiveDpiTracking(with: passiveDpiTargets)
        var result = Array(modelsByID.values)

        let hasBluetoothDevice = result.contains(where: { $0.transport == .bluetooth })
        if !hasBluetoothDevice, result.isEmpty, openResult == kIOReturnNotPermitted {
            do {
                _ = try await btExchange([], timeout: 0.8)
                guard let summary = await btVendorClient.currentPeripheralSummary() else {
                    throw BridgeError.commandFailed("Bluetooth fallback discovery resolved no peripheral identity")
                }
                let fallback = Self.makeBluetoothFallbackDevice(summary: summary)
                result.append(fallback)
                AppLog.event(
                    "Bridge",
                    "listDevices added Bluetooth fallback device after HID permission denial " +
                    "name=\(fallback.product_name) product=0x\(String(format: "%04x", fallback.product_id)) " +
                    "supported=\(fallback.profile_id != nil)"
                )
            } catch {
                AppLog.error("Bridge", "Bluetooth fallback discovery failed: \(error.localizedDescription)")
            }
        }

        let sorted = result.sorted { $0.product_name < $1.product_name }
        if sorted.isEmpty, openResult == kIOReturnNotPermitted {
            throw BridgeError.commandFailed(
                "HID access denied by macOS (kIOReturnNotPermitted). " +
                "Enable Input Monitoring for OpenSnek (or Terminal/Xcode when running via swift run/Xcode), " +
                "or ensure a supported Bluetooth device is connected."
            )
        }
        AppLog.event("Bridge", "listDevices count=\(sorted.count) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        return sorted
    }

    nonisolated static func shouldIncludeBluetoothHIDDevice(
        hidDeviceName: String,
        connectedPeripheralNames: [String?]?
    ) -> Bool {
        guard let connectedPeripheralNames else { return true }
        guard !connectedPeripheralNames.isEmpty else { return false }
        guard let normalizedHIDName = normalizedPeripheralName(hidDeviceName) else { return true }

        var sawUnknownConnectedName = false
        for connectedName in connectedPeripheralNames {
            guard let normalizedConnectedName = normalizedPeripheralName(connectedName) else {
                sawUnknownConnectedName = true
                continue
            }
            if normalizedHIDName == normalizedConnectedName ||
                normalizedHIDName.contains(normalizedConnectedName) ||
                normalizedConnectedName.contains(normalizedHIDName) {
                return true
            }
        }

        return sawUnknownConnectedName
    }

    private nonisolated static func normalizedPeripheralName(_ value: String?) -> String? {
        BluetoothNameMatcher.normalized(value)
    }

    nonisolated static func isUSBTelemetryUnavailableError(_ error: any Error) -> Bool {
        let lowered = error.localizedDescription.lowercased()
        return lowered.contains("telemetry unavailable") || lowered.contains("usable responses")
    }

    nonisolated static func usbReconnectSettleDeadline(for event: HIDDevicePresenceEvent) -> Date? {
        guard event.transport == .usb, event.change == .connected else { return nil }
        return event.observedAt.addingTimeInterval(Self.usbReconnectSettleInterval)
    }

    nonisolated static func shouldDeferUSBReconnectRead(until settleDeadline: Date?, now: Date = Date()) -> Bool {
        guard let settleDeadline else { return false }
        return now < settleDeadline
    }

    private func updateUSBReconnectSettleDeadline(for event: HIDDevicePresenceEvent) {
        guard event.transport == .usb else { return }
        if let settleDeadline = Self.usbReconnectSettleDeadline(for: event) {
            usbReconnectSettleUntilByDeviceID[event.deviceID] = settleDeadline
        } else {
            usbReconnectSettleUntilByDeviceID.removeValue(forKey: event.deviceID)
        }
    }

    func deferUSBReconnectReadIfNeeded(deviceID: String, operation: String) async throws {
        let now = Date()
        guard let settleDeadline = usbReconnectSettleUntilByDeviceID[deviceID] else { return }
        guard Self.shouldDeferUSBReconnectRead(until: settleDeadline, now: now) else {
            usbReconnectSettleUntilByDeviceID.removeValue(forKey: deviceID)
            return
        }

        let remaining = settleDeadline.timeIntervalSince(now)
        AppLog.debug(
            "Bridge",
            "usb reconnect settle device=\(deviceID) operation=\(operation) " +
            "remaining=\(String(format: "%.3f", remaining))s"
        )
        try await Task.sleep(nanoseconds: UInt64(max(0, remaining) * 1_000_000_000))
        usbReconnectSettleUntilByDeviceID.removeValue(forKey: deviceID)
    }

    nonisolated static func shouldRetryUSBStateRead(firstScanErrors: [any Error]) -> Bool {
        guard !firstScanErrors.isEmpty else { return true }
        return !firstScanErrors.allSatisfy(Self.isUSBTelemetryUnavailableError)
    }

    nonisolated static func makeBluetoothFallbackDevice(
        summary: BLEVendorTransportClient.ConnectedPeripheralSummary
    ) -> MouseDevice {
        let profile = DeviceProfiles.resolveBluetoothFallback(name: summary.name)
        let productID = profile?.supportedProducts.first ?? 0
        let productName = summary.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? summary.name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (profile?.productName ?? "Razer Bluetooth Device")
        let locationID = Int(UInt32(truncatingIfNeeded: summary.identifier.uuidString.hashValue))
        let id = String(format: "%04x:%04x:%08x:%@", 0x068E, productID, locationID, DeviceTransportKind.bluetooth.rawValue)

        return MouseDevice(
            id: id,
            vendor_id: 0x068E,
            product_id: productID,
            product_name: productName,
            transport: .bluetooth,
            path_b64: "",
            serial: nil,
            firmware: nil,
            location_id: locationID,
            profile_id: profile?.id,
            button_layout: profile?.buttonLayout,
            supports_advanced_lighting_effects: profile?.supportsAdvancedLightingEffects ?? false,
            onboard_profile_count: profile?.onboardProfileCount ?? 1
        )
    }

    nonisolated static func preferredBluetoothControlWarmupName(
        vendorID: Int,
        productID: Int,
        transport: DeviceTransportKind
    ) -> String? {
        guard transport == .bluetooth else { return nil }
        return DeviceProfiles.resolve(
            vendorID: vendorID,
            productID: productID,
            transport: transport
        )?.productName
    }

    func prepareBluetoothControlConnection(preferredPeripheralName: String?) async -> Bool {
        let trimmedName = preferredPeripheralName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let start = Date()

        do {
            _ = try await btExchange(
                [],
                timeout: 1.0,
                preferredPeripheralName: trimmedName
            )
            AppLog.debug(
                "Bridge",
                "btPrepareConnection ready name=\(trimmedName ?? "any") " +
                "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s"
            )
            return true
        } catch {
            AppLog.debug(
                "Bridge",
                "btPrepareConnection failed name=\(trimmedName ?? "any"): \(error.localizedDescription)"
            )
            return false
        }
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        let start = Date()
        if device.transport == .bluetooth {
            do {
                let session = sessionFor(device: device)
                let state = try await readBluetoothState(device: device, session: session)
                lastStateByDeviceID[device.id] = state
                AppLog.debug("Bridge", "readState bt device=\(device.id) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
                return state
            } catch {
                clearPassiveDpiObservation(deviceID: device.id, reason: "read-state-failed")
                throw error
            }
        }

        try await deferUSBReconnectReadIfNeeded(deviceID: device.id, operation: "read-state")

        let sessions = sessionsFor(device: device)
        guard !sessions.isEmpty else {
            if managerAccessDenied {
                throw BridgeError.commandFailed(
                    "USB HID access denied by macOS. Enable Input Monitoring for OpenSnek " +
                    "(or Terminal/Xcode when running via swift run/Xcode), then relaunch."
                )
            }
            throw BridgeError.commandFailed("Device not available")
        }

        var firstError: Error?
        for scanAttempt in 0..<2 {
            firstError = nil
            var scanErrors: [any Error] = []
            for (index, session) in sessions.enumerated() {
                do {
                    let state = try await readUSBState(device: device, session: session)
                    if index > 0 {
                        deviceSessions[device.id] = session
                        AppLog.debug("Bridge", "readState usb switched to alternate session index=\(index) device=\(device.id)")
                    }
                    lastStateByDeviceID[device.id] = state
                    await maybeUpgradeUSBPassiveDpiFromPolling(device: device, reason: "read-state-ok")
                    AppLog.debug(
                        "Bridge",
                        "readState usb device=\(device.id) " +
                        "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s"
                    )
                    return state
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                    scanErrors.append(error)
                    AppLog.debug("Bridge", "readState usb candidate index=\(index) failed: \(error.localizedDescription)")
                }
            }
            if scanAttempt == 0 {
                guard Self.shouldRetryUSBStateRead(firstScanErrors: scanErrors) else {
                    AppLog.debug(
                        "Bridge",
                        "readState usb aborting retry after telemetry-unavailable sweep device=\(device.id)"
                    )
                    break
                }
                usleep(120_000)
            }
        }

        deviceSessions[device.id]?.invalidateCachedTransaction()
        if let firstError {
            clearPassiveDpiObservation(deviceID: device.id, reason: "read-state-failed")
            throw firstError
        }
        throw BridgeError.commandFailed("USB device telemetry unavailable")
    }

    func readDpiStagesFast(device: MouseDevice) async throws -> (active: Int, values: [Int])? {
        if device.transport == .bluetooth {
            guard let parsed = try await btGetDpiStages(device: device) else { return nil }
            let now = Date()
            if passiveDpiObservedDeviceIDs.contains(device.id),
               Self.shouldResetBluetoothPassiveObservation(
                previousState: lastStateByDeviceID[device.id],
                active: parsed.active,
                values: parsed.values,
                lastHeartbeatAt: passiveDpiLastHeartbeatAtByDeviceID[device.id],
                lastObservedAt: passiveDpiLastObservedAtByDeviceID[device.id],
                now: now
               ) {
                AppLog.debug(
                    "Bridge",
                    "passiveDpi reset device=\(device.id) reason=watchdog-miss; fast polling will resume"
                )
                clearPassiveDpiObservation(deviceID: device.id, reason: "watchdog-miss")
                await rearmPassiveDpi(deviceID: device.id, reason: "watchdog-miss")
            }
            return (active: parsed.active, values: parsed.values)
        }

        guard device.transport == .usb else { return nil }
        let orderedSessions = sessionsFor(device: device)
        guard !orderedSessions.isEmpty else { return nil }

        var firstError: Error?
        for session in orderedSessions {
            do {
                guard let stages = try getDPIStageSnapshot(session, device) else { continue }
                let liveDpi = try getDPI(session, device)?.0
                let active: Int
                if let liveDpi, let exact = stages.values.firstIndex(of: liveDpi) {
                    active = exact
                } else {
                    active = stages.active
                }
                deviceSessions[device.id] = session
                await maybeUpgradeUSBPassiveDpiFromPolling(device: device, reason: "fast-poll-ok")
                return (active: active, values: stages.values)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            throw firstError
        }
        return nil
    }

    func readLightingColor(device: MouseDevice) async throws -> RGBPatch? {
        guard device.transport == .bluetooth else { return nil }
        if isBluetoothV3ProLightingDevice(device) {
            let ledIDs = bluetoothLightingLEDIDs(device: device)
            var colors: [(UInt8, RGBPatch)] = []
            for ledID in ledIDs {
                if let color = try await btReadLightingColor(device: device, ledID: ledID) {
                    colors.append((ledID, color))
                }
            }
            guard let first = colors.first?.1 else { return nil }
            if colors.contains(where: { $0.1 != first }) {
                AppLog.debug(
                    "Bridge",
                    "readLightingColor zone-mismatch device=\(device.id) colors=\(formatLightingZoneColors(colors))"
                )
            }
            return first
        }

        return try await btReadLightingColor(device: device, ledID: 0x01)
    }

    func apply(device: MouseDevice, patch: DevicePatch, options: ApplyOptions = ApplyOptions()) async throws -> MouseState {
        if device.transport == .bluetooth {
            let changedDpi = patch.dpiStages != nil || patch.dpiStagePairs != nil || patch.activeStage != nil
            let changedLighting = patch.ledBrightness != nil || patch.ledRGB != nil || patch.lightingEffect != nil
            let changedPower = patch.sleepTimeout != nil

            if patch.dpiStages != nil || patch.dpiStagePairs != nil || patch.activeStage != nil {
                let current: (active: Int, count: Int, slots: [Int], pairs: [DpiPair], stageIDs: [UInt8], marker: UInt8)?
                if let cached = btDpiSnapshotByDeviceID[device.id] {
                    current = cached
                } else {
                    current = try await btGetDpiStageSnapshot(device: device)
                }
                guard let current else {
                    throw BridgeError.commandFailed("Failed to read current Bluetooth DPI stages")
                }
                let stages = (patch.dpiStagePairs?.map(\.x) ?? patch.dpiStages ?? Array(current.slots.prefix(current.count))).map {
                    DeviceProfiles.clampDPI($0, device: device)
                }
                let stagePairs = Self.resolveDpiStagePairs(
                    values: patch.dpiStages,
                    pairs: patch.dpiStagePairs,
                    fallbackPairs: Array(current.pairs.prefix(current.count))
                )?.map { pair in
                    DpiPair(
                        x: DeviceProfiles.clampDPI(pair.x, device: device),
                        y: DeviceProfiles.clampDPI(pair.y, device: device)
                    )
                } ?? stages.map { DpiPair(x: $0, y: $0) }
                let active = patch.activeStage ?? current.active
                guard try await btSetDpiStages(device: device, active: active, values: stages, pairs: stagePairs) else {
                    throw BridgeError.commandFailed("Failed to set Bluetooth DPI stages")
                }
            }

            if let brightness = patch.ledBrightness {
                guard try await btSetLightingValue(device: device, value: brightness) else {
                    throw BridgeError.commandFailed("Failed to set Bluetooth lighting value")
                }
            }

            if let rgb = patch.ledRGB {
                guard try await btSetLightingRGB(
                    device: device,
                    r: rgb.r,
                    g: rgb.g,
                    b: rgb.b,
                    ledIDs: patch.usbLightingZoneLEDIDs
                ) else {
                    throw BridgeError.commandFailed("Failed to set Bluetooth RGB")
                }
            }

            if let effect = patch.lightingEffect {
                let ledIDs = effect.kind == .staticColor ? patch.usbLightingZoneLEDIDs : nil
                let applied = try await btApplyLightingEffectFallback(device: device, effect: effect, ledIDs: ledIDs)
                if !applied {
                    AppLog.debug(
                        "Bridge",
                        "lighting effect fallback unavailable kind=\(effect.kind.rawValue) transport=\(device.transport.rawValue)"
                    )
                }
            }

            if let binding = patch.buttonBinding {
                let slot = UInt8(max(0, min(255, binding.slot)))
                let kind = binding.kind
                let hidKey = UInt8(max(0, min(255, binding.hidKey ?? 4)))
                let turboEnabled = kind.supportsTurbo && binding.turboEnabled
                let turboRate = UInt16(max(1, min(255, binding.turboRate ?? 0x8E)))
                guard try await btSetButtonBinding(
                    device: device,
                    slot: slot,
                    kind: kind,
                    hidKey: hidKey,
                    turboEnabled: turboEnabled,
                    turboRate: turboRate
                ) else {
                    throw BridgeError.commandFailed("Failed to set Bluetooth button binding")
                }
            }

            if let timeout = patch.sleepTimeout {
                let clamped = max(60, min(900, timeout))
                guard try await btSetScalar(
                    device: device,
                    key: .powerTimeoutSet,
                    value: clamped,
                    size: 2,
                    payloadLength: 0x02
                ) else {
                    throw BridgeError.commandFailed("Failed to set Bluetooth sleep timeout")
                }
            }

            return try await buildBluetoothDeltaState(
                device: device,
                includeDpi: changedDpi,
                includeLighting: changedLighting,
                includePower: changedPower
            )
        } else {
            let orderedSessions = sessionsFor(device: device)
            guard !orderedSessions.isEmpty else {
                if managerAccessDenied {
                    throw BridgeError.commandFailed(
                        "USB HID access denied by macOS. Enable Input Monitoring for OpenSnek " +
                        "(or Terminal/Xcode when running via swift run/Xcode), then relaunch."
                    )
                }
                throw BridgeError.commandFailed("Device not available")
            }
            func runUSBWrite(_ operation: (USBHIDControlSession) throws -> Bool) throws -> Bool {
                var firstError: Error?
                for session in orderedSessions {
                    do {
                        if try operation(session) {
                            deviceSessions[device.id] = session
                            return true
                        }
                    } catch {
                        if firstError == nil {
                            firstError = error
                        }
                    }
                }
                if let firstError {
                    throw firstError
                }
                return false
            }

            func readUSBCurrentDpiStages() throws -> USBDpiStageSnapshot? {
                var firstError: Error?
                for session in orderedSessions {
                    do {
                        if let current = try getDPIStageSnapshot(session, device) {
                            deviceSessions[device.id] = session
                            return current
                        }
                    } catch {
                        if firstError == nil {
                            firstError = error
                        }
                    }
                }
                if let firstError {
                    throw firstError
                }
                return nil
            }

            func readUSBCurrentDpi() throws -> (Int, Int)? {
                var firstError: Error?
                for session in orderedSessions {
                    do {
                        if let current = try getDPI(session, device) {
                            deviceSessions[device.id] = session
                            return current
                        }
                    } catch {
                        if firstError == nil {
                            firstError = error
                        }
                    }
                }
                if let firstError {
                    throw firstError
                }
                return nil
            }

            if let mode = patch.deviceMode {
                guard try runUSBWrite({ try setDeviceMode($0, device, mode: mode.mode, param: mode.param) }) else {
                    throw BridgeError.commandFailed("Failed to set device mode")
                }
            }

            if let threshold = patch.lowBatteryThresholdRaw {
                guard try runUSBWrite({ try setLowBatteryThreshold($0, device, thresholdRaw: threshold) }) else {
                    throw BridgeError.commandFailed("Failed to set low battery threshold")
                }
            }

            if let scrollMode = patch.scrollMode {
                guard try runUSBWrite({ try setScrollMode($0, device, mode: scrollMode) }) else {
                    throw BridgeError.commandFailed("Failed to set scroll mode")
                }
            }

            if let scrollAcceleration = patch.scrollAcceleration {
                guard try runUSBWrite({ try setScrollAcceleration($0, device, enabled: scrollAcceleration) }) else {
                    throw BridgeError.commandFailed("Failed to set scroll acceleration")
                }
            }

            if let scrollSmartReel = patch.scrollSmartReel {
                guard try runUSBWrite({ try setScrollSmartReel($0, device, enabled: scrollSmartReel) }) else {
                    throw BridgeError.commandFailed("Failed to set scroll smart reel")
                }
            }

            if let pollRate = patch.pollRate {
                guard try runUSBWrite({ try setPollRate($0, device, value: pollRate) }) else {
                    throw BridgeError.commandFailed("Failed to set poll rate")
                }
            }

            if let timeout = patch.sleepTimeout {
                guard try runUSBWrite({ try setIdleTime($0, device, seconds: timeout) }) else {
                    throw BridgeError.commandFailed("Failed to set sleep timeout")
                }
            }

            if patch.dpiStages != nil || patch.dpiStagePairs != nil || patch.activeStage != nil {
                let current = try readUSBCurrentDpiStages()
                let stages = (patch.dpiStagePairs?.map(\.x) ?? patch.dpiStages ?? current?.values)?.map {
                    DeviceProfiles.clampDPI($0, device: device)
                }
                let stagePairs = Self.resolveDpiStagePairs(
                    values: patch.dpiStages,
                    pairs: patch.dpiStagePairs,
                    fallbackPairs: current?.pairs
                )?.map { pair in
                    DpiPair(
                        x: DeviceProfiles.clampDPI(pair.x, device: device),
                        y: DeviceProfiles.clampDPI(pair.y, device: device)
                    )
                }
                let active = patch.activeStage ?? current?.active ?? 0
                let stageIDs = current?.stageIDs
                guard let stages, !stages.isEmpty else {
                    throw BridgeError.commandFailed("Failed to resolve current DPI stages")
                }
                let resolvedStagePairs = stagePairs ?? stages.map { DpiPair(x: $0, y: $0) }
                let requiresStrictStageVerify = patch.dpiStages != nil || patch.dpiStagePairs != nil
                let activeClamped = max(0, min(stages.count - 1, active))
                let livePair = resolvedStagePairs[activeClamped]
                if stages.count == 1 {
                    // Persist single-stage intent via stage-table command when possible.
                    do {
                        _ = try runUSBWrite({
                            try setDPIStages(
                                $0,
                                device,
                                stages: [livePair.x],
                                activeStage: 0,
                                stagePairs: [livePair],
                                stageIDs: stageIDs
                            )
                        })
                    } catch {
                        AppLog.debug("Bridge", "single-stage table persist failed: \(error.localizedDescription)")
                    }

                    var dpiWriteError: Error?
                    var dpiWriteAcked = false
                    var dpiWriteVerified = false
                    for _ in 0..<6 {
                        do {
                            guard try runUSBWrite({ try setDPI($0, device, dpiX: livePair.x, dpiY: livePair.y, store: false) }) else {
                                usleep(40_000)
                                continue
                            }
                            dpiWriteAcked = true
                            for _ in 0..<12 {
                                if let readback = try readUSBCurrentDpi(),
                                   readback.0 == livePair.x,
                                   readback.1 == livePair.y {
                                    dpiWriteVerified = true
                                    break
                                }
                                usleep(70_000)
                            }
                            if dpiWriteVerified {
                                break
                            }
                        } catch {
                            if dpiWriteError == nil {
                                dpiWriteError = error
                            }
                        }
                        usleep(50_000)
                    }
                    if !dpiWriteVerified {
                        if dpiWriteAcked {
                            if requiresStrictStageVerify {
                                throw BridgeError.commandFailed("Failed to verify DPI write")
                            }
                            AppLog.debug("Bridge", "single-stage dpi verify timeout live=(\(livePair.x),\(livePair.y)); proceeding after acked write")
                        } else {
                            if let dpiWriteError {
                                throw dpiWriteError
                            }
                            throw BridgeError.commandFailed("Failed to set DPI")
                        }
                    }
                } else {
                    var stageWriteAcked = false
                    var stageWriteVerified = false
                    var stageWriteError: Error?
                    for _ in 0..<6 {
                        do {
                            guard try runUSBWrite({
                                try setDPIStages(
                                    $0,
                                    device,
                                    stages: stages,
                                    activeStage: activeClamped,
                                    stagePairs: resolvedStagePairs,
                                    stageIDs: stageIDs
                                )
                            }) else {
                                usleep(50_000)
                                continue
                            }
                            stageWriteAcked = true

                            for _ in 0..<12 {
                                guard let readback = try readUSBCurrentDpiStages() else {
                                    usleep(70_000)
                                    continue
                                }
                                let readbackActive = max(0, min(stages.count - 1, readback.active))
                                let readbackValues = Array(readback.values.prefix(stages.count)).map { DeviceProfiles.clampDPI($0, device: device) }
                                let readbackPairs = Array(readback.pairs.prefix(resolvedStagePairs.count)).map { pair in
                                    DpiPair(
                                        x: DeviceProfiles.clampDPI(pair.x, device: device),
                                        y: DeviceProfiles.clampDPI(pair.y, device: device)
                                    )
                                }
                                if readbackPairs == resolvedStagePairs && readbackActive == activeClamped {
                                    stageWriteVerified = true
                                    break
                                }
                                AppLog.debug(
                                    "Bridge",
                                    "dpi stage verify mismatch wanted=\(stages) active=\(activeClamped) " +
                                    "got=\(readbackValues) active=\(readbackActive)"
                                )
                                usleep(70_000)
                            }
                            if stageWriteVerified {
                                break
                            }
                        } catch {
                            if stageWriteError == nil {
                                stageWriteError = error
                            }
                        }
                        usleep(50_000)
                        if stageWriteVerified {
                            break
                        }
                    }
                    if !stageWriteVerified {
                        if stageWriteAcked {
                            if requiresStrictStageVerify {
                                throw BridgeError.commandFailed("Failed to verify DPI stage write")
                            }
                            AppLog.debug("Bridge", "dpi stage verify timeout active=\(activeClamped) values=\(stages); proceeding after acked write")
                        } else {
                            if let stageWriteError {
                                throw stageWriteError
                            }
                            throw BridgeError.commandFailed("Failed to set DPI stages")
                        }
                    }

                    // After stage-table commit, best-effort apply active stage DPI immediately.
                    // Some firmware reports updated table first, then lags current DPI scalar.
                    do {
                        var liveApplied = false
                        for _ in 0..<4 where !liveApplied {
                            guard try runUSBWrite({ try setDPI($0, device, dpiX: livePair.x, dpiY: livePair.y, store: false) }) else {
                                usleep(50_000)
                                continue
                            }
                            for _ in 0..<6 {
                                if let readback = try readUSBCurrentDpi(),
                                   readback.0 == livePair.x,
                                   readback.1 == livePair.y {
                                    liveApplied = true
                                    break
                                }
                                usleep(70_000)
                            }
                        }
                        if !liveApplied {
                            AppLog.debug("Bridge", "post-stage live dpi verify timeout live=(\(livePair.x),\(livePair.y))")
                        }
                    } catch {
                        AppLog.debug("Bridge", "post-stage live dpi apply failed: \(error.localizedDescription)")
                    }
                }
            }

            if let brightness = patch.ledBrightness {
                guard try runUSBWrite({ try setScrollLEDBrightness($0, device, value: brightness) }) else {
                    throw BridgeError.commandFailed("Failed to set LED brightness")
                }
            }

            if let rgb = patch.ledRGB {
                let effect = LightingEffectPatch(
                    kind: .staticColor,
                    primary: RGBPatch(r: rgb.r, g: rgb.g, b: rgb.b)
                )
                let ledIDs = effect.kind == .staticColor ? patch.usbLightingZoneLEDIDs : nil
                guard try runUSBWrite({ try setScrollLEDEffect($0, device, effect: effect, ledIDs: ledIDs) }) else {
                    throw BridgeError.commandFailed("Failed to set LED color")
                }
            }

            if let effect = patch.lightingEffect {
                let ledIDs = effect.kind == .staticColor ? patch.usbLightingZoneLEDIDs : nil
                guard try runUSBWrite({ try setScrollLEDEffect($0, device, effect: effect, ledIDs: ledIDs) }) else {
                    throw BridgeError.commandFailed("Failed to set lighting effect")
                }
            }

            if let usbButtonProfileAction = patch.usbButtonProfileAction {
                switch usbButtonProfileAction.kind {
                case .projectToDirectLayer:
                    guard try runUSBWrite({
                        try projectUSBButtonProfileToDirectLayer(
                            $0,
                            device,
                            profile: UInt8(usbButtonProfileAction.targetProfile)
                        )
                    }) else {
                        throw BridgeError.commandFailed("Failed to project USB button profile to direct layer")
                    }
                case .duplicateToPersistentSlot:
                    guard let sourceProfile = usbButtonProfileAction.sourceProfile else {
                        throw BridgeError.commandFailed("Missing source USB button profile")
                    }
                    guard try runUSBWrite({
                        try duplicateUSBButtonProfile(
                            $0,
                            device,
                            sourceProfile: UInt8(sourceProfile),
                            targetProfile: UInt8(usbButtonProfileAction.targetProfile)
                        )
                    }) else {
                        throw BridgeError.commandFailed("Failed to duplicate USB button profile")
                    }
                case .resetPersistentSlot:
                    guard try runUSBWrite({
                        try resetUSBButtonProfile(
                            $0,
                            device,
                            profile: UInt8(usbButtonProfileAction.targetProfile)
                        )
                    }) else {
                        throw BridgeError.commandFailed("Failed to reset USB button profile")
                    }
                }
            }

            if let binding = patch.buttonBinding {
                let slot = binding.slot
                let kind = binding.kind.rawValue
                let hidKey = binding.hidKey ?? 4
                let turboEnabled = binding.kind.supportsTurbo && binding.turboEnabled
                let turboRate = max(1, min(255, binding.turboRate ?? 0x8E))
                let clutchDPI = binding.kind == .dpiClutch ? DeviceProfiles.clampDPI(binding.clutchDPI ?? ButtonBindingSupport.defaultBasiliskDPIClutchDPI, device: device) : nil
                guard try runUSBWrite({
                    try setButtonBindingUSB(
                        $0,
                        device,
                        slot: slot,
                        kind: kind,
                        hidKey: hidKey,
                        turboEnabled: turboEnabled,
                        turboRate: turboRate,
                        clutchDPI: clutchDPI,
                        persistentProfile: binding.persistentProfile,
                        writePersistentLayer: binding.writePersistentLayer,
                        writeDirectLayer: binding.writeDirectLayer
                    )
                }) else {
                    throw BridgeError.commandFailed("Failed to set button binding")
                }
            }

            if options.readbackPolicy == .skipStateReadback,
               let cached = lastStateByDeviceID[device.id] {
                let projected = projectedState(from: cached, applying: patch, device: device)
                lastStateByDeviceID[device.id] = projected
                return projected
            }

            do {
                return try await readStateAfterUSBWrite(device: device)
            } catch {
                if let cached = lastStateByDeviceID[device.id] {
                    let projected = projectedState(from: cached, applying: patch, device: device)
                    lastStateByDeviceID[device.id] = projected
                    AppLog.debug(
                        "Bridge",
                        "usb apply readback failed; returning projected state device=\(device.id): \(error.localizedDescription)"
                    )
                    return projected
                }
                throw error
            }
        }
    }

    private func readStateAfterUSBWrite(device: MouseDevice, attempts: Int = 4) async throws -> MouseState {
        var firstError: Error?
        let totalAttempts = max(1, attempts)
        for attempt in 0..<totalAttempts {
            do {
                return try await readState(device: device)
            } catch {
                if firstError == nil {
                    firstError = error
                }
                AppLog.debug(
                    "Bridge",
                    "usb post-write readback attempt \(attempt + 1)/\(totalAttempts) failed device=\(device.id): \(error.localizedDescription)"
                )
                if attempt + 1 < totalAttempts {
                    let backoffMs = UInt64(120 + (attempt * 120))
                    try? await Task.sleep(nanoseconds: backoffMs * 1_000_000)
                }
            }
        }
        throw firstError ?? BridgeError.commandFailed("USB readback failed after apply")
    }

    nonisolated static func resolveDpiStagePairs(
        values: [Int]?,
        pairs: [DpiPair]?,
        fallbackPairs: [DpiPair]? = nil
    ) -> [DpiPair]? {
        if let pairs {
            return pairs
        }
        guard let values else {
            return fallbackPairs
        }
        if let fallbackPairs, fallbackPairs.count == values.count {
            return zip(values, fallbackPairs).map { value, fallbackPair in
                DpiPair(x: value, y: fallbackPair.y)
            }
        }
        return values.map { DpiPair(x: $0, y: $0) }
    }

    private func projectedState(from base: MouseState, applying patch: DevicePatch, device: MouseDevice) -> MouseState {
        let nextValues = (
            patch.dpiStagePairs?.map(\.x) ??
                patch.dpiStages ??
                base.dpi_stages.values
        )?.map { DeviceProfiles.clampDPI($0, device: device) }
        let nextPairs = Self.resolveDpiStagePairs(
            values: nextValues,
            pairs: patch.dpiStagePairs?.map { pair in
                DpiPair(
                    x: DeviceProfiles.clampDPI(pair.x, device: device),
                    y: DeviceProfiles.clampDPI(pair.y, device: device)
                )
            },
            fallbackPairs: base.dpi_stages.pairs
        )
        let requestedActive = patch.activeStage ?? base.dpi_stages.active_stage

        let resolvedActive: Int?
        if let values = nextValues, !values.isEmpty {
            resolvedActive = max(0, min(values.count - 1, requestedActive ?? 0))
        } else {
            resolvedActive = requestedActive
        }

        let nextDpi: DpiPair?
        if let nextPairs, !nextPairs.isEmpty {
            let activeIndex = max(0, min(nextPairs.count - 1, resolvedActive ?? 0))
            nextDpi = nextPairs[activeIndex]
        } else if let values = nextValues, !values.isEmpty {
            let activeIndex = max(0, min(values.count - 1, resolvedActive ?? 0))
            let value = values[activeIndex]
            nextDpi = DpiPair(x: value, y: value)
        } else {
            nextDpi = base.dpi
        }

        return MouseState(
            device: base.device,
            connection: base.connection,
            battery_percent: base.battery_percent,
            charging: base.charging,
            dpi: nextDpi,
            dpi_stages: DpiStages(active_stage: resolvedActive, values: nextValues, pairs: nextPairs),
            poll_rate: patch.pollRate ?? base.poll_rate,
            sleep_timeout: patch.sleepTimeout ?? base.sleep_timeout,
            device_mode: patch.deviceMode ?? base.device_mode,
            low_battery_threshold_raw: patch.lowBatteryThresholdRaw ?? base.low_battery_threshold_raw,
            scroll_mode: patch.scrollMode ?? base.scroll_mode,
            scroll_acceleration: patch.scrollAcceleration ?? base.scroll_acceleration,
            scroll_smart_reel: patch.scrollSmartReel ?? base.scroll_smart_reel,
            active_onboard_profile: base.active_onboard_profile,
            onboard_profile_count: base.onboard_profile_count,
            led_value: patch.ledBrightness ?? base.led_value,
            capabilities: base.capabilities
        )
    }
}
