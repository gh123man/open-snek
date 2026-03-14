import Foundation
import IOKit.hid
import OpenSnekCore
import OpenSnekHardware
import OpenSnekProtocols

actor BridgeClient {
    typealias USBDpiStageSnapshot = (active: Int, values: [Int], stageIDs: [UInt8])

    var deviceSessions: [String: USBHIDControlSession] = [:]
    var deviceSessionCandidates: [String: [USBHIDControlSession]] = [:]
    var lastStateByDeviceID: [String: MouseState] = [:]
    var devicePresenceContinuations: [UUID: AsyncStream<HIDDevicePresenceEvent>.Continuation] = [:]
    var passiveDpiEventContinuations: [UUID: AsyncStream<PassiveDPIEvent>.Continuation] = [:]
    var passiveDpiArmedDeviceIDs: Set<String> = []
    var passiveDpiObservedDeviceIDs: Set<String> = []
    var passiveDpiTargetPointersByDeviceID: [String: Set<UInt>] = [:]
    var passiveDpiTargetsByDeviceID: [String: [PassiveDPIEventMonitor.WatchTarget]] = [:]
    var passiveDpiUpgradeNotBeforeByDeviceID: [String: Date] = [:]
    var btReqID: UInt8 = 0x30
    var btDpiSnapshotByDeviceID: [String: (active: Int, count: Int, slots: [Int], stageIDs: [UInt8], marker: UInt8)] = [:]
    var btExpectedDpiByDeviceID: [String: (active: Int, values: [Int], expiresAt: Date, remainingMasks: Int)] = [:]
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

    init() {
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
        hidDevicePresenceMonitor.start()
    }

    func devicePresenceEventStream() -> AsyncStream<HIDDevicePresenceEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: HIDDevicePresenceEvent.self)
        devicePresenceContinuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removeDevicePresenceContinuation(id: id)
            }
        }
        return stream
    }

    func passiveDpiEventStream() -> AsyncStream<PassiveDPIEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: PassiveDPIEvent.self)
        passiveDpiEventContinuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removePassiveDpiContinuation(id: id)
            }
        }
        return stream
    }

    func shouldUseFastDPIPolling(device: MouseDevice) -> Bool {
        Self.shouldUseFastDPIPolling(
            device: device,
            armedPassiveDpiDeviceIDs: passiveDpiArmedDeviceIDs,
            observedPassiveDpiDeviceIDs: passiveDpiObservedDeviceIDs
        )
    }

    func dpiUpdateTransportStatus(device: MouseDevice) -> DpiUpdateTransportStatus {
        let profile = DeviceProfiles.resolve(
            vendorID: device.vendor_id,
            productID: device.product_id,
            transport: device.transport
        )
        guard profile?.passiveDPIInput != nil else {
            return .unsupported
        }
        if passiveDpiObservedDeviceIDs.contains(device.id) {
            return .realTimeHID
        }
        if passiveDpiArmedDeviceIDs.contains(device.id) {
            return .listening
        }
        return .pollingFallback
    }

    private func removePassiveDpiContinuation(id: UUID) {
        passiveDpiEventContinuations.removeValue(forKey: id)
    }

    private func removeDevicePresenceContinuation(id: UUID) {
        devicePresenceContinuations.removeValue(forKey: id)
    }

    private func handleHIDDevicePresenceEvent(_ event: HIDDevicePresenceEvent) {
        AppLog.event(
            "Bridge",
            "hidPresence change=\(event.change.rawValue) device=\(event.deviceID)"
        )
        invalidateDiscoveryState(for: event.deviceID, reason: "hid-\(event.change.rawValue)")
        for continuation in devicePresenceContinuations.values {
            continuation.yield(event)
        }
    }

    private func handlePassiveDpiEvent(_ event: PassiveDPIEvent) {
        guard passiveDpiArmedDeviceIDs.contains(event.deviceID) else { return }
        passiveDpiUpgradeNotBeforeByDeviceID.removeValue(forKey: event.deviceID)
        if Self.isBluetoothDeviceID(event.deviceID) {
            seedBluetoothPassiveDpiExpectation(event)
        }
        let firstObserved = passiveDpiObservedDeviceIDs.insert(event.deviceID).inserted
        if firstObserved {
            AppLog.event(
                "Bridge",
                "passiveDpi observed device=\(event.deviceID); disabling fast DPI polling for this device"
            )
        }
        for continuation in passiveDpiEventContinuations.values {
            continuation.yield(event)
        }
    }

    private func seedBluetoothPassiveDpiExpectation(_ event: PassiveDPIEvent) {
        if let projected = mergedStateFromPassiveDpiEvent(
            previous: lastStateByDeviceID[event.deviceID],
            event: event
        ) {
            lastStateByDeviceID[event.deviceID] = projected
        }

        guard let expected = Self.bluetoothPassiveDpiExpectation(
            event: event,
            snapshot: btDpiSnapshotByDeviceID[event.deviceID],
            state: lastStateByDeviceID[event.deviceID]
        ) else {
            return
        }

        btExpectedDpiByDeviceID[event.deviceID] = (
            active: expected.active,
            values: expected.values,
            expiresAt: Date().addingTimeInterval(1.2),
            remainingMasks: 4
        )

        if let snapshot = btDpiSnapshotByDeviceID[event.deviceID] {
            btDpiSnapshotByDeviceID[event.deviceID] = (
                active: expected.active,
                count: snapshot.count,
                slots: snapshot.slots,
                stageIDs: snapshot.stageIDs,
                marker: snapshot.marker
            )
        }

        AppLog.debug(
            "Bridge",
            "btPassiveDpi expected device=\(event.deviceID) active=\(expected.active) values=\(expected.values)"
        )
    }

    private func clearPassiveDpiObservation(deviceID: String, reason: String) {
        passiveDpiUpgradeNotBeforeByDeviceID.removeValue(forKey: deviceID)
        guard passiveDpiObservedDeviceIDs.remove(deviceID) != nil else { return }
        AppLog.debug(
            "Bridge",
            "passiveDpi reset device=\(deviceID) reason=\(reason); re-enabling fast DPI polling"
        )
    }

    private func invalidateDiscoveryState(for deviceID: String, reason: String) {
        deviceSessions.removeValue(forKey: deviceID)
        deviceSessionCandidates.removeValue(forKey: deviceID)
        lastStateByDeviceID.removeValue(forKey: deviceID)
        passiveDpiArmedDeviceIDs.remove(deviceID)
        passiveDpiTargetPointersByDeviceID.removeValue(forKey: deviceID)
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
            clearManagedHIDManager()
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
        passiveDpiTargetsByDeviceID = Self.passiveDpiTargetsByDeviceID(targets: passiveDpiTargets)
        let nextPassiveDpiTargetPointersByDeviceID = Self.passiveDpiTargetPointerSetsByDeviceID(targets: passiveDpiTargets)
        passiveDpiArmedDeviceIDs = await passiveDpiMonitor.replaceTargets(passiveDpiTargets)
        let activePassiveTargetPointersByDeviceID = nextPassiveDpiTargetPointersByDeviceID.filter {
            passiveDpiArmedDeviceIDs.contains($0.key)
        }
        let nextObservedPassiveDpiDeviceIDs = Self.reconciledObservedPassiveDpiDeviceIDs(
            observedDeviceIDs: passiveDpiObservedDeviceIDs,
            previousTargetPointersByDeviceID: passiveDpiTargetPointersByDeviceID,
            nextTargetPointersByDeviceID: activePassiveTargetPointersByDeviceID
        )
        let resetPassiveDpiDeviceIDs = passiveDpiObservedDeviceIDs.subtracting(nextObservedPassiveDpiDeviceIDs)
        for deviceID in resetPassiveDpiDeviceIDs {
            AppLog.debug(
                "Bridge",
                "passiveDpi reset device=\(deviceID) reason=registration-changed; re-enabling fast DPI polling"
            )
        }
        passiveDpiObservedDeviceIDs = nextObservedPassiveDpiDeviceIDs
        passiveDpiTargetPointersByDeviceID = activePassiveTargetPointersByDeviceID
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
                "Enable Input Monitoring for Open Snek (or Terminal/Xcode when running via swift run/Xcode), " +
                "or ensure a supported Bluetooth device is connected."
            )
        }
        AppLog.event("Bridge", "listDevices count=\(sorted.count) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        return sorted
    }

    private func maybeUpgradeUSBPassiveDpiFromPolling(device: MouseDevice, reason: String) async {
        guard Self.shouldAttemptPassiveDpiUpgrade(
            device: device,
            targetAvailable: passiveDpiTargetsByDeviceID[device.id]?.isEmpty == false,
            observedPassiveDpiDeviceIDs: passiveDpiObservedDeviceIDs,
            retryNotBefore: passiveDpiUpgradeNotBeforeByDeviceID[device.id],
            now: Date()
        ) else {
            return
        }

        let now = Date()
        passiveDpiUpgradeNotBeforeByDeviceID[device.id] = now.addingTimeInterval(1.5)
        let allTargets = Array(passiveDpiTargetsByDeviceID.values.joined())
        guard !allTargets.isEmpty else { return }

        AppLog.debug(
            "Bridge",
            "passiveDpi rearm device=\(device.id) reason=\(reason)"
        )
        passiveDpiArmedDeviceIDs = await passiveDpiMonitor.replaceTargets(
            allTargets,
            forceRebuildDeviceIDs: [device.id]
        )
        let nextTargetPointersByDeviceID = Self.passiveDpiTargetPointerSetsByDeviceID(targets: allTargets)
        passiveDpiTargetPointersByDeviceID = nextTargetPointersByDeviceID.filter {
            passiveDpiArmedDeviceIDs.contains($0.key)
        }
    }

    private func passiveDpiWatchTarget(
        for device: IOHIDDevice,
        deviceID: String,
        profile: DeviceProfile?,
        transport: DeviceTransportKind
    ) -> PassiveDPIEventMonitor.WatchTarget? {
        guard transport == .usb || transport == .bluetooth, let descriptor = profile?.passiveDPIInput else { return nil }

        let usagePage = USBHIDSupport.intProperty(device, key: kIOHIDPrimaryUsagePageKey as CFString) ?? -1
        let usage = USBHIDSupport.intProperty(device, key: kIOHIDPrimaryUsageKey as CFString) ?? -1
        let maxInput = USBHIDSupport.intProperty(device, key: kIOHIDMaxInputReportSizeKey as CFString) ?? 0
        let maxFeature = USBHIDSupport.intProperty(device, key: kIOHIDMaxFeatureReportSizeKey as CFString) ?? 0

        guard usagePage == descriptor.usagePage,
              usage == descriptor.usage,
              maxInput >= descriptor.minInputReportSize
        else {
            return nil
        }
        if let expectedMaxFeature = descriptor.maxFeatureReportSize, expectedMaxFeature != maxFeature {
            return nil
        }

        return PassiveDPIEventMonitor.WatchTarget(deviceID: deviceID, device: device, descriptor: descriptor)
    }

    nonisolated static func shouldUseFastDPIPolling(
        device: MouseDevice,
        armedPassiveDpiDeviceIDs: Set<String>,
        observedPassiveDpiDeviceIDs: Set<String>
    ) -> Bool {
        guard armedPassiveDpiDeviceIDs.contains(device.id) else { return true }
        return !observedPassiveDpiDeviceIDs.contains(device.id)
    }

    nonisolated static func shouldAttemptPassiveDpiUpgrade(
        device: MouseDevice,
        targetAvailable: Bool,
        observedPassiveDpiDeviceIDs: Set<String>,
        retryNotBefore: Date?,
        now: Date
    ) -> Bool {
        guard device.transport == .usb else { return false }
        guard targetAvailable else { return false }
        guard !observedPassiveDpiDeviceIDs.contains(device.id) else { return false }
        if let retryNotBefore, now < retryNotBefore {
            return false
        }
        return true
    }

    nonisolated static func bluetoothPassiveDpiExpectation(
        event: PassiveDPIEvent,
        snapshot: (active: Int, count: Int, slots: [Int], stageIDs: [UInt8], marker: UInt8)?,
        state: MouseState?
    ) -> (active: Int, values: [Int])? {
        let values: [Int]
        if let snapshot {
            values = Array(snapshot.slots.prefix(snapshot.count))
        } else if let stateValues = state?.dpi_stages.values {
            values = stateValues
        } else {
            return nil
        }

        let matchingIndices = values.enumerated().compactMap { index, value in
            value == event.dpiX ? index : nil
        }
        guard matchingIndices.count == 1 else { return nil }
        return (active: matchingIndices[0], values: values)
    }

    nonisolated static func isBluetoothDeviceID(_ deviceID: String) -> Bool {
        deviceID.hasSuffix(":\(DeviceTransportKind.bluetooth.rawValue)")
    }

    nonisolated static func reconciledObservedPassiveDpiDeviceIDs(
        observedDeviceIDs: Set<String>,
        previousTargetPointersByDeviceID: [String: Set<UInt>],
        nextTargetPointersByDeviceID: [String: Set<UInt>]
    ) -> Set<String> {
        observedDeviceIDs.filter { deviceID in
            guard let previous = previousTargetPointersByDeviceID[deviceID],
                  let next = nextTargetPointersByDeviceID[deviceID] else {
                return false
            }
            return previous == next
        }
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

    nonisolated static func passiveDpiTargetPointerSetsByDeviceID(
        targets: [PassiveDPIEventMonitor.WatchTarget]
    ) -> [String: Set<UInt>] {
        var targetPointersByDeviceID: [String: Set<UInt>] = [:]
        for target in targets {
            let devicePointer = UInt(bitPattern: Unmanaged.passUnretained(target.device).toOpaque())
            targetPointersByDeviceID[target.deviceID, default: []].insert(devicePointer)
        }
        return targetPointersByDeviceID
    }

    nonisolated static func passiveDpiTargetsByDeviceID(
        targets: [PassiveDPIEventMonitor.WatchTarget]
    ) -> [String: [PassiveDPIEventMonitor.WatchTarget]] {
        var targetsByDeviceID: [String: [PassiveDPIEventMonitor.WatchTarget]] = [:]
        for target in targets {
            targetsByDeviceID[target.deviceID, default: []].append(target)
        }
        return targetsByDeviceID
    }

    private nonisolated static func normalizedPeripheralName(_ value: String?) -> String? {
        BluetoothNameMatcher.normalized(value)
    }

    nonisolated static func isUSBTelemetryUnavailableError(_ error: any Error) -> Bool {
        let lowered = error.localizedDescription.lowercased()
        return lowered.contains("telemetry unavailable") || lowered.contains("usable responses")
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

        let sessions = sessionsFor(device: device)
        guard !sessions.isEmpty else {
            if hidAccessDenied || managerAccessDenied {
                throw BridgeError.commandFailed(
                    "USB HID access denied by macOS. Enable Input Monitoring for Open Snek " +
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
                    AppLog.debug("Bridge", "readState usb device=\(device.id) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
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

    func apply(device: MouseDevice, patch: DevicePatch) async throws -> MouseState {
        if device.transport == .bluetooth {
            let changedDpi = patch.dpiStages != nil || patch.activeStage != nil
            let changedLighting = patch.ledBrightness != nil || patch.ledRGB != nil || patch.lightingEffect != nil
            let changedPower = patch.sleepTimeout != nil

            if patch.dpiStages != nil || patch.activeStage != nil {
                let current: (active: Int, count: Int, slots: [Int], stageIDs: [UInt8], marker: UInt8)?
                if let cached = btDpiSnapshotByDeviceID[device.id] {
                    current = cached
                } else {
                    current = try await btGetDpiStageSnapshot(device: device)
                }
                guard let current else {
                    throw BridgeError.commandFailed("Failed to read current Bluetooth DPI stages")
                }
                let stages = patch.dpiStages ?? Array(current.slots.prefix(current.count))
                let active = patch.activeStage ?? current.active
                guard try await btSetDpiStages(device: device, active: active, values: stages) else {
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
                if hidAccessDenied {
                    throw BridgeError.commandFailed(
                        "USB HID access denied by macOS. Enable Input Monitoring for Open Snek " +
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

            if patch.dpiStages != nil || patch.activeStage != nil {
                let current = try readUSBCurrentDpiStages()
                let stages = (patch.dpiStages ?? current?.values)?.map { max(100, min(30_000, $0)) }
                let active = patch.activeStage ?? current?.active ?? 0
                let stageIDs = current?.stageIDs
                guard let stages, !stages.isEmpty else {
                    throw BridgeError.commandFailed("Failed to resolve current DPI stages")
                }
                let requiresStrictStageVerify = patch.dpiStages != nil
                let activeClamped = max(0, min(stages.count - 1, active))
                let liveDpi = stages[activeClamped]
                if stages.count == 1 {
                    // Persist single-stage intent via stage-table command when possible.
                    do {
                        _ = try runUSBWrite({
                            try setDPIStages($0, device, stages: [liveDpi], activeStage: 0, stageIDs: stageIDs)
                        })
                    } catch {
                        AppLog.debug("Bridge", "single-stage table persist failed: \(error.localizedDescription)")
                    }

                    var dpiWriteError: Error?
                    var dpiWriteAcked = false
                    var dpiWriteVerified = false
                    for _ in 0..<6 {
                        do {
                            guard try runUSBWrite({ try setDPI($0, device, dpiX: liveDpi, dpiY: liveDpi, store: false) }) else {
                                usleep(40_000)
                                continue
                            }
                            dpiWriteAcked = true
                            for _ in 0..<12 {
                                if let readback = try readUSBCurrentDpi(),
                                   readback.0 == liveDpi,
                                   readback.1 == liveDpi {
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
                            AppLog.debug("Bridge", "single-stage dpi verify timeout live=\(liveDpi); proceeding after acked write")
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
                                try setDPIStages($0, device, stages: stages, activeStage: activeClamped, stageIDs: stageIDs)
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
                                let readbackValues = Array(readback.values.prefix(stages.count)).map { max(100, min(30_000, $0)) }
                                if readbackValues == stages && readbackActive == activeClamped {
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
                            guard try runUSBWrite({ try setDPI($0, device, dpiX: liveDpi, dpiY: liveDpi, store: false) }) else {
                                usleep(50_000)
                                continue
                            }
                            for _ in 0..<6 {
                                if let readback = try readUSBCurrentDpi(),
                                   readback.0 == liveDpi,
                                   readback.1 == liveDpi {
                                    liveApplied = true
                                    break
                                }
                                usleep(70_000)
                            }
                        }
                        if !liveApplied {
                            AppLog.debug("Bridge", "post-stage live dpi verify timeout live=\(liveDpi)")
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

            if let binding = patch.buttonBinding {
                let slot = binding.slot
                let kind = binding.kind.rawValue
                let hidKey = binding.hidKey ?? 4
                let turboEnabled = binding.kind.supportsTurbo && binding.turboEnabled
                let turboRate = max(1, min(255, binding.turboRate ?? 0x8E))
                let clutchDPI = binding.kind == .dpiClutch ? max(100, min(30_000, binding.clutchDPI ?? ButtonBindingSupport.defaultV3ProDPIClutchDPI)) : nil
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
                        writeDirectLayer: binding.writeDirectLayer
                    )
                }) else {
                    throw BridgeError.commandFailed("Failed to set button binding")
                }
            }

            do {
                return try await readStateAfterUSBWrite(device: device)
            } catch {
                if let cached = lastStateByDeviceID[device.id] {
                    let projected = projectedState(from: cached, applying: patch)
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

    private func projectedState(from base: MouseState, applying patch: DevicePatch) -> MouseState {
        let nextValues = patch.dpiStages ?? base.dpi_stages.values
        let requestedActive = patch.activeStage ?? base.dpi_stages.active_stage

        let resolvedActive: Int?
        if let values = nextValues, !values.isEmpty {
            resolvedActive = max(0, min(values.count - 1, requestedActive ?? 0))
        } else {
            resolvedActive = requestedActive
        }

        let nextDpi: DpiPair?
        if let values = nextValues, !values.isEmpty {
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
            dpi_stages: DpiStages(active_stage: resolvedActive, values: nextValues),
            poll_rate: patch.pollRate ?? base.poll_rate,
            sleep_timeout: patch.sleepTimeout ?? base.sleep_timeout,
            device_mode: patch.deviceMode ?? base.device_mode,
            low_battery_threshold_raw: patch.lowBatteryThresholdRaw ?? base.low_battery_threshold_raw,
            scroll_mode: patch.scrollMode ?? base.scroll_mode,
            scroll_acceleration: patch.scrollAcceleration ?? base.scroll_acceleration,
            scroll_smart_reel: patch.scrollSmartReel ?? base.scroll_smart_reel,
            led_value: patch.ledBrightness ?? base.led_value,
            capabilities: base.capabilities
        )
    }
}
