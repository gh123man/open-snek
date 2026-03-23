import Foundation
import IOKit.hid
import OpenSnekAppSupport
import OpenSnekCore
import OpenSnekHardware

extension BridgeClient {
    func passiveDpiEventStream() -> AsyncStream<PassiveDPIEvent> {
        passiveDpiEvents.makeStream()
    }

    func passiveDpiHeartbeatStream() -> AsyncStream<PassiveDPIHeartbeatEvent> {
        passiveDpiHeartbeatEvents.makeStream()
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
        guard DeveloperRuntimeOptions.passiveHIDUpdatesEnabled() else {
            return .pollingFallback
        }
        if passiveDpiObservedDeviceIDs.contains(device.id) {
            return .realTimeHID
        }
        if passiveDpiHeartbeatDeviceIDs.contains(device.id) {
            return .streamActive
        }
        if passiveDpiArmedDeviceIDs.contains(device.id) {
            return .listening
        }
        return .pollingFallback
    }

    func updatePassiveDpiTracking(with targets: [PassiveDPIEventMonitor.WatchTarget]) async {
        let passiveUpdatesEnabled = DeveloperRuntimeOptions.passiveHIDUpdatesEnabled()
        let activeTargets = passiveUpdatesEnabled ? targets : []
        passiveDpiTargetsByDeviceID = Self.passiveDpiTargetsByDeviceID(targets: activeTargets)
        let nextTargetIDsByDeviceID = Self.passiveDpiTargetIDsByDeviceID(targets: activeTargets)
        passiveDpiArmedDeviceIDs = await passiveDpiMonitor.replaceTargets(activeTargets)
        let activeTargetIDsByDeviceID = nextTargetIDsByDeviceID.filter {
            passiveDpiArmedDeviceIDs.contains($0.key)
        }
        let nextObservedDeviceIDs = Self.reconciledObservedPassiveDpiDeviceIDs(
            observedDeviceIDs: passiveDpiObservedDeviceIDs,
            previousTargetIDsByDeviceID: passiveDpiTargetIDsByDeviceID,
            nextTargetIDsByDeviceID: activeTargetIDsByDeviceID
        )
        let nextHeartbeatDeviceIDs = Self.reconciledObservedPassiveDpiDeviceIDs(
            observedDeviceIDs: passiveDpiHeartbeatDeviceIDs,
            previousTargetIDsByDeviceID: passiveDpiTargetIDsByDeviceID,
            nextTargetIDsByDeviceID: activeTargetIDsByDeviceID
        )
        let resetDeviceIDs = passiveDpiObservedDeviceIDs.subtracting(nextObservedDeviceIDs)
        for deviceID in resetDeviceIDs {
            AppLog.debug(
                "Bridge",
                "passiveDpi reset device=\(deviceID) reason=registration-changed; re-enabling fast DPI polling"
            )
        }
        passiveDpiHeartbeatDeviceIDs = nextHeartbeatDeviceIDs
        passiveDpiObservedDeviceIDs = nextObservedDeviceIDs
        passiveDpiTargetIDsByDeviceID = activeTargetIDsByDeviceID
    }

    func handlePassiveDpiEvent(_ event: PassiveDPIEvent) {
        guard DeveloperRuntimeOptions.passiveHIDUpdatesEnabled() else { return }
        guard passiveDpiArmedDeviceIDs.contains(event.deviceID) else { return }
        passiveDpiUpgradeNotBeforeByDeviceID.removeValue(forKey: event.deviceID)
        passiveDpiLastObservedAtByDeviceID[event.deviceID] = event.observedAt
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
        passiveDpiEvents.yield(event)
    }

    func handlePassiveDpiHeartbeat(_ event: PassiveDPIHeartbeatEvent) {
        guard DeveloperRuntimeOptions.passiveHIDUpdatesEnabled() else { return }
        guard passiveDpiArmedDeviceIDs.contains(event.deviceID) else { return }
        passiveDpiLastHeartbeatAtByDeviceID[event.deviceID] = event.observedAt
        let firstHeartbeat = passiveDpiHeartbeatDeviceIDs.insert(event.deviceID).inserted
        if firstHeartbeat {
            AppLog.debug(
                "Bridge",
                "passiveDpi heartbeat device=\(event.deviceID); HID stream is active"
            )
        }
        passiveDpiHeartbeatEvents.yield(event)
    }

    func seedBluetoothPassiveDpiExpectation(_ event: PassiveDPIEvent) {
        let previousState = lastStateByDeviceID[event.deviceID]
        if let projected = mergedStateFromPassiveDpiEvent(
            previous: previousState,
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
            previousActive: Self.clampedDpiActiveIndex(for: previousState),
            previousValues: previousState?.dpi_stages.values,
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

    func clearPassiveDpiObservation(deviceID: String, reason: String) {
        passiveDpiUpgradeNotBeforeByDeviceID.removeValue(forKey: deviceID)
        passiveDpiLastHeartbeatAtByDeviceID.removeValue(forKey: deviceID)
        passiveDpiLastObservedAtByDeviceID.removeValue(forKey: deviceID)
        passiveDpiHeartbeatDeviceIDs.remove(deviceID)
        guard passiveDpiObservedDeviceIDs.remove(deviceID) != nil else { return }
        AppLog.debug(
            "Bridge",
            "passiveDpi reset device=\(deviceID) reason=\(reason); re-enabling fast DPI polling"
        )
    }

    func maybeUpgradeUSBPassiveDpiFromPolling(device: MouseDevice, reason: String) async {
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

        AppLog.debug("Bridge", "passiveDpi rearm device=\(device.id) reason=\(reason)")
        passiveDpiArmedDeviceIDs = await passiveDpiMonitor.replaceTargets(
            allTargets,
            forceRebuildDeviceIDs: [device.id]
        )
        let nextTargetIDsByDeviceID = Self.passiveDpiTargetIDsByDeviceID(targets: allTargets)
        passiveDpiTargetIDsByDeviceID = nextTargetIDsByDeviceID.filter {
            passiveDpiArmedDeviceIDs.contains($0.key)
        }
    }

    func rearmPassiveDpi(deviceID: String, reason: String) async {
        let allTargets = Array(passiveDpiTargetsByDeviceID.values.joined())
        guard !allTargets.isEmpty else { return }

        AppLog.debug("Bridge", "passiveDpi rearm device=\(deviceID) reason=\(reason)")
        passiveDpiArmedDeviceIDs = await passiveDpiMonitor.replaceTargets(
            allTargets,
            forceRebuildDeviceIDs: [deviceID]
        )
        let nextTargetIDsByDeviceID = Self.passiveDpiTargetIDsByDeviceID(targets: allTargets)
        passiveDpiTargetIDsByDeviceID = nextTargetIDsByDeviceID.filter {
            passiveDpiArmedDeviceIDs.contains($0.key)
        }
    }

    func passiveDpiWatchTarget(
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

        let targetID = Self.passiveDpiTargetID(
            usagePage: usagePage,
            usage: usage,
            maxInput: maxInput,
            maxFeature: maxFeature
        )

        return PassiveDPIEventMonitor.WatchTarget(
            deviceID: deviceID,
            targetID: targetID,
            device: device,
            deviceIdentityToken: USBHIDSupport.deviceIdentityToken(device),
            descriptor: descriptor
        )
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

    nonisolated static func shouldResetBluetoothPassiveObservation(
        previousState: MouseState?,
        active: Int,
        values: [Int],
        lastHeartbeatAt: Date?,
        lastObservedAt: Date?,
        now: Date
    ) -> Bool {
        guard let previousState,
              let previousValues = previousState.dpi_stages.values,
              !values.isEmpty else {
            return false
        }

        let previousActive = max(0, min(previousValues.count - 1, previousState.dpi_stages.active_stage ?? 0))
        let nextActive = max(0, min(values.count - 1, active))
        let previousValue = previousValues[previousActive]
        let nextValue = values[nextActive]
        guard previousActive != nextActive || previousValue != nextValue || previousValues != values else {
            return false
        }

        guard let lastObservedAt else { return true }
        if isBluetoothPassiveHeartbeatHealthy(lastHeartbeatAt: lastHeartbeatAt, now: now) {
            return false
        }
        return now.timeIntervalSince(lastObservedAt) > bluetoothPassiveResetSilenceInterval
    }

    nonisolated static func shouldMaskBluetoothExpectedRead(
        parsedActive: Int,
        parsedValues: [Int],
        expected: BluetoothExpectedDpiState
    ) -> Bool {
        guard let previousActive = expected.previousActive,
              let previousValues = expected.previousValues,
              !previousValues.isEmpty else {
            return false
        }

        let clampedPreviousActive = max(0, min(previousValues.count - 1, previousActive))
        let normalizedParsedValues = Array(parsedValues.prefix(previousValues.count))
        return parsedActive == clampedPreviousActive && normalizedParsedValues == previousValues
    }

    nonisolated static func clampedDpiActiveIndex(for state: MouseState?) -> Int? {
        guard let values = state?.dpi_stages.values, !values.isEmpty else { return nil }
        let active = state?.dpi_stages.active_stage ?? 0
        return max(0, min(values.count - 1, active))
    }

    nonisolated static func isBluetoothPassiveHeartbeatHealthy(lastHeartbeatAt: Date?, now: Date) -> Bool {
        guard let lastHeartbeatAt else { return false }
        return now.timeIntervalSince(lastHeartbeatAt) <= bluetoothPassiveHeartbeatHealthyInterval
    }

    nonisolated static func reconciledObservedPassiveDpiDeviceIDs(
        observedDeviceIDs: Set<String>,
        previousTargetIDsByDeviceID: [String: Set<String>],
        nextTargetIDsByDeviceID: [String: Set<String>]
    ) -> Set<String> {
        observedDeviceIDs.filter { deviceID in
            if isBluetoothDeviceID(deviceID) {
                return nextTargetIDsByDeviceID[deviceID]?.isEmpty == false
            }
            guard let previous = previousTargetIDsByDeviceID[deviceID],
                  let next = nextTargetIDsByDeviceID[deviceID] else {
                return false
            }
            return previous == next
        }
    }

    nonisolated static func passiveDpiTargetID(
        usagePage: Int,
        usage: Int,
        maxInput: Int,
        maxFeature: Int
    ) -> String {
        "\(usagePage):\(usage):\(maxInput):\(maxFeature)"
    }

    nonisolated static func passiveDpiTargetIDsByDeviceID(
        targets: [PassiveDPIEventMonitor.WatchTarget]
    ) -> [String: Set<String>] {
        var targetIDsByDeviceID: [String: Set<String>] = [:]
        for target in targets {
            targetIDsByDeviceID[target.deviceID, default: []].insert(target.targetID)
        }
        return targetIDsByDeviceID
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
}
