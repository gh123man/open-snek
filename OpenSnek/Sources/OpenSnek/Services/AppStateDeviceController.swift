import Foundation
import OpenSnekCore

@MainActor
final class AppStateDeviceController {
    private let environment: AppEnvironment
    private unowned let deviceStore: DeviceStore
    private weak var editorControllerStorage: AppStateEditorController?
    private weak var applyControllerStorage: AppStateApplyController?
    private weak var runtimeControllerStorage: AppStateRuntimeController?

    private var stateCacheByDeviceID: [String: MouseState] = [:]
    private var lastUpdatedByDeviceID: [String: Date] = [:]
    private var refreshingStateDeviceIDs: Set<String> = []
    private var refreshingFastDpiDeviceIDs: Set<String> = []
    private var suppressFastDpiUntilByDeviceID: [String: Date] = [:]
    private var lastUSBFastDpiAtByDeviceID: [String: Date] = [:]
    private var lastRealtimeCorrectionAtByDeviceID: [String: Date] = [:]
    private var lastPassiveHeartbeatAtByDeviceID: [String: Date] = [:]
    private var lastFullStateRefreshAtByDeviceID: [String: Date] = [:]
    private var isPollingDevices = false
    private var refreshFailureCountByDeviceID: [String: Int] = [:]
    private var stateRefreshSuppressedUntilByDeviceID: [String: Date] = [:]
    private var unavailableDeviceIDs: Set<String> = []
    private var dpiUpdateTransportStatusByDeviceID: [String: DpiUpdateTransportStatus] = [:]
    private var pendingLightingRestoreDeviceIDs: Set<String> = []
    private var restoringLightingDeviceIDs: Set<String> = []

    init(environment: AppEnvironment, deviceStore: DeviceStore) {
        self.environment = environment
        self.deviceStore = deviceStore
    }

    func tearDown() {
    }

    func bind(
        editorController: AppStateEditorController,
        applyController: AppStateApplyController,
        runtimeController: AppStateRuntimeController
    ) {
        self.editorControllerStorage = editorController
        self.applyControllerStorage = applyController
        self.runtimeControllerStorage = runtimeController
    }

    private var editorController: AppStateEditorController {
        guard let editorControllerStorage else {
            preconditionFailure("AppStateDeviceController accessed before editorController was bound")
        }
        return editorControllerStorage
    }

    private var applyController: AppStateApplyController {
        guard let applyControllerStorage else {
            preconditionFailure("AppStateDeviceController accessed before applyController was bound")
        }
        return applyControllerStorage
    }

    private var runtimeController: AppStateRuntimeController {
        guard let runtimeControllerStorage else {
            preconditionFailure("AppStateDeviceController accessed before runtimeController was bound")
        }
        return runtimeControllerStorage
    }

    func cachedState(for deviceID: String) -> MouseState? {
        stateCacheByDeviceID[deviceID]
    }

    func storeState(_ state: MouseState, for deviceID: String, updatedAt: Date) {
        stateCacheByDeviceID[deviceID] = state
        lastUpdatedByDeviceID[deviceID] = updatedAt
    }

    func setFastDpiSuppressed(until: Date, for deviceID: String) {
        suppressFastDpiUntilByDeviceID[deviceID] = until
    }

    func diagnosticsConnectionLines(for device: MouseDevice) -> [String] {
        let deviceConnectionState = connectionState(for: device)
        let presence = deviceStore.devices.contains(where: { $0.id == device.id }) ? "Detected by macOS" : "Not detected"
        let dpiPath = deviceConnectionState == .disconnected
            ? "Unavailable while disconnected"
            : dpiUpdateTransportStatus(for: device).diagnosticsLabel
        return [
            "Presence: \(presence)",
            "Telemetry: \(deviceConnectionState.diagnosticsLabel)",
            "DPI updates: \(dpiPath)",
        ]
    }

    func refreshConnectionDiagnostics(for device: MouseDevice) async {
        guard !isStrictlyUnsupported(device) else {
            setDpiUpdateTransportStatus(.unsupported, for: device.id)
            return
        }
        guard resolvedProfile(for: device)?.passiveDPIInput != nil else {
            setDpiUpdateTransportStatus(.unsupported, for: device.id)
            return
        }
        guard deviceStore.devices.contains(where: { $0.id == device.id }) || deviceStore.selectedDeviceID == device.id else {
            setDpiUpdateTransportStatus(.unknown, for: device.id)
            return
        }
        let transportStatus = await environment.backend.dpiUpdateTransportStatus(device: device)
        guard deviceStore.devices.contains(where: { $0.id == device.id }) || deviceStore.selectedDeviceID == device.id else {
            return
        }
        setDpiUpdateTransportStatus(transportStatus, for: device.id)
    }

    func handleBackendDeviceListUpdate(_ listed: [MouseDevice]) async {
        guard !environment.usesRemoteServiceTransport else { return }
        let previousIDs = Set(deviceStore.devices.map(\.id))
        _ = applyDeviceList(listed, source: "subscription")
        guard !listed.isEmpty else { return }
        let prioritizedDeviceIDs = listed
            .filter { $0.transport == .bluetooth && !previousIDs.contains($0.id) }
            .map(\.id)
        await refreshAllDeviceStates(prioritizing: prioritizedDeviceIDs)
        await refreshDpiUpdateTransportStatuses(for: listed)
    }

    func applyRemoteServiceSnapshot(_ snapshot: SharedServiceSnapshot) {
        guard environment.usesRemoteServiceTransport else { return }

        let liveIDs = Set(snapshot.devices.map(\.id))
        stateCacheByDeviceID = stateCacheByDeviceID.filter { liveIDs.contains($0.key) }
        lastUpdatedByDeviceID = lastUpdatedByDeviceID.filter { liveIDs.contains($0.key) }

        for (deviceID, remoteState) in snapshot.stateByDeviceID {
            let snapshotUpdatedAt = snapshot.lastUpdatedByDeviceID[deviceID] ?? Date()
            if let latestCachedAt = lastUpdatedByDeviceID[deviceID],
               latestCachedAt > snapshotUpdatedAt {
                AppLog.debug(
                    "AppState",
                    "remoteSnapshot superseded-drop device=\(deviceID) updatedAt=\(snapshotUpdatedAt.timeIntervalSince1970) " +
                    "cachedAt=\(latestCachedAt.timeIntervalSince1970)"
                )
                continue
            }
            stateCacheByDeviceID[deviceID] = remoteState
            lastUpdatedByDeviceID[deviceID] = snapshotUpdatedAt
            refreshFailureCountByDeviceID[deviceID] = 0
            unavailableDeviceIDs.remove(deviceID)
        }

        _ = applyDeviceList(snapshot.devices, source: "subscription")

        if let selectedDeviceID = deviceStore.selectedDeviceID,
           let selectedState = stateCacheByDeviceID[selectedDeviceID],
           let selectedDevice = deviceStore.selectedDevice {
            deviceStore.state = selectedState
            deviceStore.lastUpdated = lastUpdatedByDeviceID[selectedDeviceID]
            if applyController.shouldHydrateEditable {
                editorController.hydrateEditable(from: selectedState)
            }
            deviceStore.errorMessage = nil
            setTelemetryWarning(editorController.telemetryWarning(for: selectedState, device: selectedDevice), device: selectedDevice)
        } else if let selectedDeviceID = deviceStore.selectedDeviceID {
            syncSelectedDevicePresentation(deviceID: selectedDeviceID)
            deviceStore.errorMessage = nil
        } else {
            deviceStore.state = nil
            deviceStore.lastUpdated = nil
            deviceStore.warningMessage = nil
            deviceStore.errorMessage = nil
        }

        Task { [weak self] in
            await self?.refreshDpiUpdateTransportStatuses(for: snapshot.devices)
        }
    }

    func applyBackendDeviceStateUpdate(deviceID: String, state updatedState: MouseState, updatedAt: Date) {
        guard let sourceDevice = deviceStore.devices.first(where: { $0.id == deviceID }),
              let presentationDevice = presentationDevice(for: sourceDevice) else {
            return
        }

        let presentationDeviceID = presentationDevice.id
        if let latestCachedAt = latestCachedUpdateAt(sourceDeviceID: deviceID, presentationDeviceID: presentationDeviceID),
           latestCachedAt > updatedAt {
            AppLog.debug(
                "AppState",
                "backendStateUpdate superseded-drop device=\(presentationDeviceID) updatedAt=\(updatedAt.timeIntervalSince1970) " +
                "cachedAt=\(latestCachedAt.timeIntervalSince1970)"
            )
            return
        }

        let previous = stateCacheByDeviceID[presentationDeviceID] ?? stateCacheByDeviceID[deviceID]
        let merged = updatedState.merged(with: previous)
        let shouldFocusOnActivity = shouldFocusServiceSelectionOnActivity(previous: previous, next: merged)

        cacheState(merged, sourceDeviceID: deviceID, presentationDeviceID: presentationDeviceID, updatedAt: updatedAt)
        setDpiUpdateTransportStatus(.realTimeHID, for: deviceID)
        setDpiUpdateTransportStatus(.realTimeHID, for: presentationDeviceID)
        refreshFailureCountByDeviceID[deviceID] = 0
        refreshFailureCountByDeviceID[presentationDeviceID] = 0
        unavailableDeviceIDs.remove(deviceID)
        unavailableDeviceIDs.remove(presentationDeviceID)

        if shouldFocusOnActivity {
            focusServiceSelectionOnActivity(deviceID: presentationDeviceID)
        }
        runtimeController.updateStatusItemTransientDpi(previous: previous, next: merged, deviceID: presentationDeviceID)

        if deviceStore.selectedDeviceID == presentationDeviceID {
            if deviceStore.state != merged {
                deviceStore.state = merged
            }
            if applyController.shouldHydrateEditable {
                editorController.hydrateEditable(from: merged)
            }
            deviceStore.errorMessage = nil
            setTelemetryWarning(editorController.telemetryWarning(for: merged, device: presentationDevice), device: presentationDevice)
        }
    }

    func applyBackendDpiTransportStatusUpdate(deviceID: String, status: DpiUpdateTransportStatus, updatedAt: Date) {
        if status == .streamActive {
            lastPassiveHeartbeatAtByDeviceID[deviceID] = updatedAt
        }

        let currentStatus = dpiUpdateTransportStatusByDeviceID[deviceID]
        if !Self.shouldApplyBackendDpiTransportStatusUpdate(current: currentStatus, incoming: status) {
            return
        }

        setDpiUpdateTransportStatus(status, for: deviceID)

        guard let sourceDevice = deviceStore.devices.first(where: { $0.id == deviceID }),
              let presentationDevice = presentationDevice(for: sourceDevice) else {
            return
        }

        let presentationDeviceID = presentationDevice.id
        if status == .streamActive {
            lastPassiveHeartbeatAtByDeviceID[presentationDeviceID] = updatedAt
        }
        let presentationStatus = dpiUpdateTransportStatusByDeviceID[presentationDeviceID]
        if Self.shouldApplyBackendDpiTransportStatusUpdate(current: presentationStatus, incoming: status) {
            setDpiUpdateTransportStatus(status, for: presentationDeviceID)
        }
    }

    func refreshDevices() async {
        guard runtimeController.isBackendReady else {
            AppLog.debug("AppState", "refreshDevices deferred until backend is ready")
            return
        }
        let start = Date()
        AppLog.event("AppState", "refreshDevices start")
        deviceStore.isLoading = true
        defer { deviceStore.isLoading = false }

        do {
            let listed = try await environment.backend.listDevices()
            _ = applyDeviceList(listed, source: "refresh")
            deviceStore.errorMessage = nil
        } catch {
            AppLog.error("AppState", "refreshDevices failed: \(error.localizedDescription)")
            deviceStore.errorMessage = error.localizedDescription
        }

        await refreshAllDeviceStates()
        await refreshDpiUpdateTransportStatuses(for: deviceStore.devices)
        AppLog.event("AppState", "refreshDevices end elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
    }

    func pollDevicePresence() async {
        guard !isPollingDevices, !deviceStore.isLoading else { return }
        isPollingDevices = true
        defer { isPollingDevices = false }

        do {
            let listed = try await environment.backend.listDevices()
            let changed = applyDeviceList(listed, source: "poll")
            if changed {
                deviceStore.errorMessage = nil
                await refreshAllDeviceStates()
                await refreshDpiUpdateTransportStatuses(for: listed)
            } else if deviceStore.selectedDevice != nil, deviceStore.state == nil {
                await refreshState()
            } else if let selectedDevice = deviceStore.selectedDevice {
                await refreshConnectionDiagnostics(for: selectedDevice)
            }
        } catch {
            if deviceStore.devices.isEmpty {
                let lowered = error.localizedDescription.lowercased()
                if lowered.contains("no device") || lowered.contains("no supported device") || lowered.contains("not found") {
                    deviceStore.errorMessage = nil
                } else {
                    AppLog.warning("AppState", "pollDevicePresence failed with no visible devices: \(error.localizedDescription)")
                    deviceStore.errorMessage = error.localizedDescription
                }
            } else {
                AppLog.debug("AppState", "pollDevicePresence failed: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func applyDeviceList(_ listed: [MouseDevice], source: String) -> Bool {
        let sorted = listed.sorted { $0.product_name < $1.product_name }
        let previousDevices = deviceStore.devices
        let previousIDs = Set(previousDevices.map(\.id))
        let previousSelectedID = deviceStore.selectedDeviceID
        let previousSelectedDevice = previousDevices.first(where: { $0.id == previousSelectedID })
        let previousSelectedIdentity = previousSelectedDevice.map(deviceIdentityKey)

        let newIDs = Set(sorted.map(\.id))
        let removedIDs = previousIDs.subtracting(newIDs)
        if !removedIDs.isEmpty {
            editorController.removeHydratedState(for: removedIDs)
            for id in removedIDs {
                stateCacheByDeviceID[id] = nil
                refreshFailureCountByDeviceID[id] = nil
                stateRefreshSuppressedUntilByDeviceID[id] = nil
                unavailableDeviceIDs.remove(id)
                setDpiUpdateTransportStatus(nil, for: id)
                lastUpdatedByDeviceID[id] = nil
                lastFullStateRefreshAtByDeviceID[id] = nil
                suppressFastDpiUntilByDeviceID[id] = nil
                lastUSBFastDpiAtByDeviceID[id] = nil
                refreshingStateDeviceIDs.remove(id)
                refreshingFastDpiDeviceIDs.remove(id)
                pendingLightingRestoreDeviceIDs.remove(id)
                restoringLightingDeviceIDs.remove(id)
            }
        }

        let newlyVisibleIDs = newIDs.subtracting(previousIDs)
        if !newlyVisibleIDs.isEmpty {
            pendingLightingRestoreDeviceIDs.formUnion(newlyVisibleIDs)
        }
        if source == "subscription", previousIDs == newIDs, !newIDs.isEmpty {
            pendingLightingRestoreDeviceIDs.formUnion(newIDs)
        }

        deviceStore.devices = sorted
        if let previousSelectedID, newIDs.contains(previousSelectedID) {
            deviceStore.selectedDeviceID = previousSelectedID
        } else if let previousSelectedIdentity,
                  let match = sorted.first(where: { deviceIdentityKey($0) == previousSelectedIdentity }) {
            deviceStore.selectedDeviceID = match.id
        } else {
            deviceStore.selectedDeviceID = sorted.first?.id
        }

        if let recoverySelection = preferredBluetoothRecoverySelection(
            in: sorted,
            previousIDs: previousIDs,
            previousSelectedDevice: previousSelectedDevice
        ) {
            deviceStore.selectedDeviceID = recoverySelection.id
            AppLog.event(
                "AppState",
                "applyDeviceList recovery-select previous=\(previousSelectedDevice?.id ?? "nil") replacement=\(recoverySelection.id)"
            )
        }

        if let selectedDeviceID = deviceStore.selectedDeviceID {
            syncSelectedDevicePresentation(deviceID: selectedDeviceID)
        } else {
            deviceStore.state = nil
            deviceStore.errorMessage = nil
            deviceStore.warningMessage = nil
            deviceStore.lastUpdated = nil
        }

        let changed = previousIDs != newIDs || previousSelectedID != deviceStore.selectedDeviceID
        if changed {
            runtimeController.clearStatusItemTransientDpi()
            AppLog.event(
                "AppState",
                "applyDeviceList source=\(source) count=\(sorted.count) selected=\(deviceStore.selectedDeviceID ?? "nil")"
            )
        }
        if environment.usesRemoteServiceTransport, previousSelectedID != deviceStore.selectedDeviceID {
            runtimeController.sendRemoteClientPresence()
        }
        return changed
    }

    func preferredBluetoothRecoverySelection(
        in devices: [MouseDevice],
        previousIDs: Set<String>,
        previousSelectedDevice: MouseDevice?
    ) -> MouseDevice? {
        guard let previousSelectedDevice else { return nil }
        guard deviceStore.selectedDeviceID == previousSelectedDevice.id else { return nil }
        guard previousSelectedDevice.transport == .usb else { return nil }
        guard selectedDeviceNeedsRecovery(previousSelectedDevice) else { return nil }

        let newlyAddedBluetoothDevices = devices.filter { candidate in
            candidate.transport == .bluetooth && !previousIDs.contains(candidate.id)
        }
        guard !newlyAddedBluetoothDevices.isEmpty else { return nil }

        let previousSerial = normalizedSerial(for: previousSelectedDevice)
        if let previousSerial {
            let serialMatches = newlyAddedBluetoothDevices.filter {
                normalizedSerial(for: $0) == previousSerial
            }
            if serialMatches.count == 1 {
                return serialMatches[0]
            }
        }

        let nameMatches = newlyAddedBluetoothDevices.filter {
            $0.product_name == previousSelectedDevice.product_name
        }
        if nameMatches.count == 1 {
            return nameMatches[0]
        }

        return nil
    }

    func selectDevice(_ deviceID: String) {
        guard deviceStore.selectedDeviceID != deviceID else { return }
        runtimeController.clearStatusItemTransientDpi()
        deviceStore.selectedDeviceID = deviceID
        syncSelectedDevicePresentation(deviceID: deviceID)
        if let selectedDevice = deviceStore.selectedDevice {
            Task { [weak self] in
                await self?.refreshConnectionDiagnostics(for: selectedDevice)
            }
        }
        if environment.usesRemoteServiceTransport {
            runtimeController.sendRemoteClientPresence()
        }
    }

    func syncSelectedDevicePresentation(deviceID: String) {
        guard let device = deviceStore.devices.first(where: { $0.id == deviceID }) else {
            deviceStore.state = nil
            deviceStore.errorMessage = nil
            deviceStore.warningMessage = nil
            deviceStore.lastUpdated = nil
            deviceStore.isRefreshingState = false
            return
        }

        deviceStore.isRefreshingState = refreshingStateDeviceIDs.contains(deviceID)
        if applyController.shouldHydrateEditable {
            editorController.hydratePersistedLightingStateIfNeeded(device: device)
        }
        if unavailableDeviceIDs.contains(deviceID) {
            deviceStore.state = nil
            deviceStore.lastUpdated = nil
            deviceStore.warningMessage = nil
            if deviceStore.errorMessage == nil || !Self.isDeviceAvailabilityMessage(deviceStore.errorMessage ?? "") {
                deviceStore.errorMessage = "Device disconnected or unavailable"
            }
        } else if let cached = stateCacheByDeviceID[deviceID] {
            deviceStore.state = cached
            deviceStore.lastUpdated = lastUpdatedByDeviceID[deviceID]
            deviceStore.warningMessage = editorController.telemetryWarning(for: cached, device: device)
            if applyController.shouldHydrateEditable {
                editorController.hydrateEditable(from: cached)
            }
        } else if let state = deviceStore.state, stateSummaryMatchesDevice(state, device: device) {
            deviceStore.warningMessage = editorController.telemetryWarning(for: state, device: device)
            if applyController.shouldHydrateEditable {
                editorController.hydrateEditable(from: state)
            }
        } else {
            deviceStore.state = nil
            deviceStore.lastUpdated = nil
            deviceStore.warningMessage = nil
        }
        if !unavailableDeviceIDs.contains(deviceID) {
            deviceStore.errorMessage = nil
        }
    }

    func setTelemetryWarning(_ newValue: String?, device: MouseDevice) {
        if deviceStore.warningMessage != newValue, let newValue {
            AppLog.warning("AppState", "telemetry degraded device=\(device.id) transport=\(device.transport.rawValue): \(newValue)")
        }
        deviceStore.warningMessage = newValue
    }

    func connectionState(for device: MouseDevice) -> DeviceConnectionState {
        if isStrictlyUnsupported(device) {
            return .unsupported
        }

        if !deviceStore.devices.contains(where: { $0.id == device.id }) && deviceStore.selectedDeviceID != device.id {
            return .disconnected
        }

        if unavailableDeviceIDs.contains(device.id) {
            return .disconnected
        }

        if device.id == deviceStore.selectedDeviceID, let errorMessage = deviceStore.errorMessage, !errorMessage.isEmpty {
            let lowered = errorMessage.lowercased()
            return Self.isDeviceAvailabilityMessage(lowered) ? .disconnected : .error
        }

        let failures = refreshFailureCountByDeviceID[device.id] ?? 0
        if failures > 0 {
            return .reconnecting
        }

        guard let updatedAt = lastUpdatedTimestamp(for: device) else {
            return .reconnecting
        }

        let age = Date().timeIntervalSince(updatedAt)
        if age > max(4.5, runtimeController.currentPollingProfile.refreshStateInterval * 1.7) {
            return .reconnecting
        }

        return .connected
    }

    func statusIndicator(for device: MouseDevice) -> DeviceStatusIndicator {
        connectionState(for: device).indicator
    }

    func lastUpdatedTimestamp(for device: MouseDevice) -> Date? {
        lastUpdatedByDeviceID[device.id] ?? (device.id == deviceStore.selectedDeviceID ? deviceStore.lastUpdated : nil)
    }

    func dpiUpdateTransportStatus(for device: MouseDevice) -> DpiUpdateTransportStatus {
        if isStrictlyUnsupported(device) {
            return .unsupported
        }
        return dpiUpdateTransportStatusByDeviceID[device.id] ?? .unknown
    }

    func refreshDpiUpdateTransportStatuses(for devices: [MouseDevice]) async {
        for device in devices {
            await refreshConnectionDiagnostics(for: device)
        }
    }

    func focusServiceSelectionOnActivity(deviceID: String) {
        guard environment.launchRole.isService else { return }
        guard deviceStore.selectedDeviceID != deviceID else { return }
        guard deviceStore.devices.contains(where: { $0.id == deviceID }) else { return }
        deviceStore.selectedDeviceID = deviceID
        syncSelectedDevicePresentation(deviceID: deviceID)
    }

    func shouldFocusServiceSelectionOnActivity(previous: MouseState?, next: MouseState) -> Bool {
        guard environment.launchRole.isService else { return false }
        guard let previous else { return false }

        return previous.dpi != next.dpi ||
            previous.dpi_stages != next.dpi_stages ||
            previous.poll_rate != next.poll_rate ||
            previous.sleep_timeout != next.sleep_timeout ||
            previous.device_mode != next.device_mode ||
            previous.low_battery_threshold_raw != next.low_battery_threshold_raw ||
            previous.scroll_mode != next.scroll_mode ||
            previous.scroll_acceleration != next.scroll_acceleration ||
            previous.scroll_smart_reel != next.scroll_smart_reel ||
            previous.active_onboard_profile != next.active_onboard_profile ||
            previous.onboard_profile_count != next.onboard_profile_count ||
            previous.led_value != next.led_value
    }

    func deviceIdentityKey(_ device: MouseDevice) -> String {
        if let serial = device.serial?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serial.isEmpty {
            return "serial:\(serial.lowercased())"
        }
        return String(
            format: "vp:%04x:%04x:%@",
            device.vendor_id,
            device.product_id,
            device.transport.rawValue
        )
    }

    func stateSummaryMatchesDevice(_ state: MouseState, device: MouseDevice) -> Bool {
        let deviceSerial = device.serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stateSerial = state.device.serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let deviceSerial, !deviceSerial.isEmpty,
           let stateSerial, !stateSerial.isEmpty {
            return deviceSerial == stateSerial
        }

        return state.device.transport == device.transport &&
            state.device.product_name == device.product_name
    }

    func selectedDeviceNeedsRecovery(_ device: MouseDevice) -> Bool {
        if unavailableDeviceIDs.contains(device.id) {
            return true
        }
        if (refreshFailureCountByDeviceID[device.id] ?? 0) > 0 {
            return true
        }
        if stateCacheByDeviceID[device.id] != nil || lastUpdatedByDeviceID[device.id] != nil {
            return false
        }
        if deviceStore.selectedDeviceID == device.id,
           let state = deviceStore.state,
           stateSummaryMatchesDevice(state, device: device) {
            return false
        }
        return true
    }

    func normalizedSerial(for device: MouseDevice) -> String? {
        guard let serial = device.serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !serial.isEmpty else {
            return nil
        }
        return serial
    }

    func isStrictlyUnsupported(_ device: MouseDevice) -> Bool {
        resolvedProfile(for: device) == nil && device.transport == .bluetooth
    }

    func presentationDevice(for device: MouseDevice) -> MouseDevice? {
        if let exactMatch = deviceStore.devices.first(where: { $0.id == device.id }) {
            return exactMatch
        }
        let identityKey = deviceIdentityKey(device)
        return deviceStore.devices.first(where: { deviceIdentityKey($0) == identityKey })
    }

    private func resolvedProfile(for device: MouseDevice) -> DeviceProfile? {
        DeviceProfiles.resolve(
            vendorID: device.vendor_id,
            productID: device.product_id,
            transport: device.transport
        )
    }

    func refreshableDevicesInPriorityOrder(prioritizing prioritizedDeviceIDs: [String] = []) -> [MouseDevice] {
        guard !deviceStore.devices.isEmpty else { return [] }
        let now = Date()

        var ordered: [MouseDevice] = []
        var seen: Set<String> = []

        for deviceID in prioritizedDeviceIDs {
            guard let device = deviceStore.devices.first(where: { $0.id == deviceID }) else { continue }
            guard !isStrictlyUnsupported(device) else { continue }
            guard seen.insert(device.id).inserted else { continue }
            ordered.append(device)
        }

        if let selectedDevice = deviceStore.selectedDevice,
           !isStrictlyUnsupported(selectedDevice),
           seen.insert(selectedDevice.id).inserted {
            ordered.append(selectedDevice)
        }

        for device in deviceStore.devices where !isStrictlyUnsupported(device) {
            guard seen.insert(device.id).inserted else { continue }
            if deviceStore.selectedDeviceID != device.id,
               let suppressedUntil = stateRefreshSuppressedUntilByDeviceID[device.id],
               now < suppressedUntil {
                continue
            }
            ordered.append(device)
        }

        return ordered
    }

    func cacheState(_ state: MouseState, sourceDeviceID: String, presentationDeviceID: String, updatedAt: Date = Date()) {
        stateCacheByDeviceID[sourceDeviceID] = state
        lastUpdatedByDeviceID[sourceDeviceID] = updatedAt

        if presentationDeviceID != sourceDeviceID {
            stateCacheByDeviceID[presentationDeviceID] = state
            lastUpdatedByDeviceID[presentationDeviceID] = updatedAt
        }

        if deviceStore.selectedDeviceID == presentationDeviceID {
            deviceStore.lastUpdated = updatedAt
        }
    }

    func latestCachedUpdateAt(sourceDeviceID: String, presentationDeviceID: String) -> Date? {
        [lastUpdatedByDeviceID[sourceDeviceID], lastUpdatedByDeviceID[presentationDeviceID]]
            .compactMap { $0 }
            .max()
    }

    static func isDeviceAvailabilityMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("no device") ||
            lowered.contains("disconnected") ||
            lowered.contains("not available") ||
            lowered.contains("telemetry unavailable") ||
            lowered.contains("bt vendor timeout") ||
            lowered.contains("failed to connect") ||
            lowered.contains("bluetooth is powered off")
    }

    func stateRefreshBackoffInterval(for device: MouseDevice, failures: Int, error: any Error) -> TimeInterval {
        let lowered = error.localizedDescription.lowercased()
        if device.transport == .usb,
           lowered.contains("telemetry unavailable") || lowered.contains("usable responses") {
            return 30.0
        }

        switch failures {
        case ...1:
            return 8.0
        case 2:
            return 15.0
        case 3:
            return 30.0
        default:
            return 60.0
        }
    }

    func refreshState() async {
        guard let selectedDevice = deviceStore.selectedDevice else {
            deviceStore.state = nil
            deviceStore.errorMessage = nil
            deviceStore.warningMessage = nil
            deviceStore.lastUpdated = nil
            deviceStore.isRefreshingState = false
            return
        }
        guard !isStrictlyUnsupported(selectedDevice) else {
            deviceStore.state = nil
            deviceStore.warningMessage = nil
            deviceStore.errorMessage = nil
            deviceStore.lastUpdated = nil
            deviceStore.isRefreshingState = false
            return
        }
        _ = await refreshState(for: selectedDevice)
    }

    func refreshAllDeviceStates(prioritizing prioritizedDeviceIDs: [String] = []) async {
        let devicesToRefresh = refreshableDevicesInPriorityOrder(prioritizing: prioritizedDeviceIDs)
        guard !devicesToRefresh.isEmpty else {
            if let selectedDevice = deviceStore.selectedDevice, isStrictlyUnsupported(selectedDevice) {
                deviceStore.state = nil
                deviceStore.warningMessage = nil
                deviceStore.errorMessage = nil
                deviceStore.lastUpdated = nil
                deviceStore.isRefreshingState = false
            } else if let selectedDeviceID = deviceStore.selectedDeviceID {
                syncSelectedDevicePresentation(deviceID: selectedDeviceID)
            } else {
                deviceStore.state = nil
                deviceStore.warningMessage = nil
                deviceStore.errorMessage = nil
                deviceStore.lastUpdated = nil
                deviceStore.isRefreshingState = false
            }
            return
        }

        for device in devicesToRefresh {
            _ = await refreshState(for: device)
        }

        if let selectedDeviceID = deviceStore.selectedDeviceID {
            syncSelectedDevicePresentation(deviceID: selectedDeviceID)
        }
    }

    @discardableResult
    func refreshState(for device: MouseDevice) async -> Bool {
        guard !isStrictlyUnsupported(device) else { return false }
        guard !refreshingStateDeviceIDs.contains(device.id) else { return false }
        guard !deviceStore.isApplying else {
            AppLog.debug("AppState", "refreshState skipped applying device=\(device.id)")
            return false
        }
        guard !applyController.hasPendingLocalEditsAffecting(device) else {
            AppLog.debug("AppState", "refreshState skipped pending-local-edits device=\(device.id)")
            return false
        }

        let now = Date()
        if Self.shouldDelayBluetoothRealtimeStateRefresh(
            transport: device.transport,
            transportStatus: dpiUpdateTransportStatusByDeviceID[device.id],
            lastHeartbeatAt: lastPassiveHeartbeatAtByDeviceID[device.id],
            lastFullStateRefreshAt: lastFullStateRefreshAtByDeviceID[device.id],
            now: now
        ) {
            AppLog.debug("AppState", "refreshState deferred active-bt-realtime device=\(device.id)")
            return false
        }

        if deviceStore.selectedDeviceID == device.id, let cached = stateCacheByDeviceID[device.id] {
            deviceStore.state = cached
        }

        refreshingStateDeviceIDs.insert(device.id)
        if deviceStore.selectedDeviceID == device.id {
            deviceStore.isRefreshingState = true
        }
        defer {
            refreshingStateDeviceIDs.remove(device.id)
            if deviceStore.selectedDeviceID == device.id {
                deviceStore.isRefreshingState = false
            }
        }

        let refreshRevision = applyController.stateRevision
        let refreshDeviceID = device.id
        let start = Date()

        do {
            let fetched = try await environment.backend.readState(device: device)
            guard refreshRevision == applyController.stateRevision else {
                AppLog.debug("AppState", "refreshState stale-drop rev=\(refreshRevision) current=\(applyController.stateRevision)")
                return false
            }
            guard let presentationDevice = presentationDevice(for: device) else {
                AppLog.debug("AppState", "refreshState drop missing-presentation device=\(refreshDeviceID)")
                return false
            }

            let presentationDeviceID = presentationDevice.id
            if let latestCachedAt = latestCachedUpdateAt(sourceDeviceID: refreshDeviceID, presentationDeviceID: presentationDeviceID),
               latestCachedAt > start {
                AppLog.debug(
                    "AppState",
                    "refreshState superseded-drop device=\(presentationDeviceID) startedAt=\(start.timeIntervalSince1970) " +
                    "cachedAt=\(latestCachedAt.timeIntervalSince1970)"
                )
                return false
            }
            let previous = stateCacheByDeviceID[presentationDeviceID] ?? stateCacheByDeviceID[refreshDeviceID]
            let merged = fetched.merged(with: previous)
            let shouldFocusOnActivity = shouldFocusServiceSelectionOnActivity(previous: previous, next: merged)
            let updatedAt = Date()
            cacheState(merged, sourceDeviceID: refreshDeviceID, presentationDeviceID: presentationDeviceID, updatedAt: updatedAt)
            lastFullStateRefreshAtByDeviceID[refreshDeviceID] = updatedAt
            lastFullStateRefreshAtByDeviceID[presentationDeviceID] = updatedAt
            refreshFailureCountByDeviceID[refreshDeviceID] = 0
            refreshFailureCountByDeviceID[presentationDeviceID] = 0
            stateRefreshSuppressedUntilByDeviceID[refreshDeviceID] = nil
            stateRefreshSuppressedUntilByDeviceID[presentationDeviceID] = nil
            unavailableDeviceIDs.remove(refreshDeviceID)
            unavailableDeviceIDs.remove(presentationDeviceID)
            if shouldFocusOnActivity {
                focusServiceSelectionOnActivity(deviceID: presentationDeviceID)
            }
            runtimeController.updateStatusItemTransientDpi(previous: previous, next: merged, deviceID: presentationDeviceID)

            if deviceStore.selectedDeviceID == presentationDeviceID {
                if deviceStore.state != merged {
                    deviceStore.state = merged
                }
                if applyController.shouldHydrateEditable {
                    editorController.hydrateEditable(from: merged)
                    await editorController.hydrateLightingStateIfNeeded(device: presentationDevice)
                    await editorController.hydrateButtonBindingsIfNeeded(device: presentationDevice)
                }
                deviceStore.errorMessage = nil
                setTelemetryWarning(editorController.telemetryWarning(for: merged, device: presentationDevice), device: presentationDevice)
            }
            await restorePersistedLightingIfNeeded(for: presentationDevice)

            AppLog.debug(
                "AppState",
                "refreshState ok device=\(presentationDeviceID) active=\(merged.dpi_stages.active_stage.map(String.init) ?? "nil") " +
                "values=\(merged.dpi_stages.values?.map(String.init).joined(separator: ",") ?? "nil") " +
                "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s"
            )
            return true
        } catch {
            let presentationDeviceID = presentationDevice(for: device)?.id ?? refreshDeviceID
            let failures = (refreshFailureCountByDeviceID[presentationDeviceID] ?? 0) + 1
            refreshFailureCountByDeviceID[refreshDeviceID] = failures
            refreshFailureCountByDeviceID[presentationDeviceID] = failures
            let isAvailabilityFailure = Self.isDeviceAvailabilityMessage(error.localizedDescription)
            if isAvailabilityFailure {
                unavailableDeviceIDs.insert(refreshDeviceID)
                unavailableDeviceIDs.insert(presentationDeviceID)
            }

            if deviceStore.selectedDeviceID != presentationDeviceID {
                let suppressedUntil = Date().addingTimeInterval(
                    stateRefreshBackoffInterval(for: device, failures: failures, error: error)
                )
                stateRefreshSuppressedUntilByDeviceID[refreshDeviceID] = suppressedUntil
                stateRefreshSuppressedUntilByDeviceID[presentationDeviceID] = suppressedUntil
                AppLog.debug(
                    "AppState",
                    "refreshState backoff device=\(presentationDeviceID) failures=\(failures) " +
                    "until=\(suppressedUntil.timeIntervalSince1970): \(error.localizedDescription)"
                )
            }

            guard deviceStore.selectedDeviceID == presentationDeviceID else {
                AppLog.debug("AppState", "refreshState masked non-selected failure device=\(presentationDeviceID): \(error.localizedDescription)")
                return false
            }

            if isAvailabilityFailure {
                deviceStore.state = nil
                deviceStore.lastUpdated = nil
                deviceStore.warningMessage = nil
                deviceStore.errorMessage = error.localizedDescription
                return false
            }

            if stateCacheByDeviceID[presentationDeviceID] == nil {
                AppLog.error(
                    "AppState",
                    "refreshState failed device=\(presentationDeviceID) transport=\(device.transport.rawValue) no-cache: \(error.localizedDescription)"
                )
                deviceStore.errorMessage = error.localizedDescription
                deviceStore.warningMessage = nil
            } else {
                AppLog.debug("AppState", "refreshState transient-failure masked: \(error.localizedDescription)")
                if failures >= 3 {
                    if failures == 3 {
                        AppLog.warning(
                            "AppState",
                            "device read unstable device=\(presentationDeviceID) failures=\(failures): \(error.localizedDescription)"
                        )
                    }
                    deviceStore.errorMessage = "Device read is failing repeatedly (\(failures)x): \(error.localizedDescription)"
                } else {
                    deviceStore.errorMessage = nil
                }
                deviceStore.warningMessage = "Using the last known values while live telemetry settles."
            }
            return false
        }
    }

    func refreshDpiFast() async {
        guard !deviceStore.isApplying else { return }

        let now = Date()
        for deviceID in runtimeController.activeFastPollingDeviceIDs(at: now) {
            guard let device = deviceStore.devices.first(where: { $0.id == deviceID }) else { continue }
            await refreshDpiFast(for: device, now: now)
        }
    }

    private func refreshDpiFast(for device: MouseDevice, now: Date) async {
        guard device.transport == .bluetooth || device.transport == .usb else { return }
        guard !isStrictlyUnsupported(device) else { return }
        guard !refreshingFastDpiDeviceIDs.contains(device.id) else { return }
        guard !refreshingStateDeviceIDs.contains(device.id) else { return }
        guard !applyController.hasPendingLocalEditsAffecting(device) else { return }
        let usesFastPolling = await environment.backend.shouldUseFastDPIPolling(device: device)
        let correctionOnly = !usesFastPolling
        if correctionOnly,
           device.transport == .bluetooth,
           Self.shouldDelayBluetoothRealtimeCorrection(
            lastHeartbeatAt: lastPassiveHeartbeatAtByDeviceID[device.id],
            now: now
           ) {
            return
        }
        if correctionOnly {
            setDpiUpdateTransportStatus(.realTimeHID, for: device.id)
            let minimumInterval = realtimeCorrectionMinimumInterval(for: device)
            if let lastCorrectionAt = lastRealtimeCorrectionAtByDeviceID[device.id],
               now.timeIntervalSince(lastCorrectionAt) < minimumInterval {
                return
            }
            lastRealtimeCorrectionAtByDeviceID[device.id] = now
        }

        if device.transport == .usb,
           let lastUSBFastDpiAt = lastUSBFastDpiAtByDeviceID[device.id],
           now.timeIntervalSince(lastUSBFastDpiAt) < 0.55 {
            return
        }
        if let until = suppressFastDpiUntilByDeviceID[device.id] {
            if now < until { return }
            suppressFastDpiUntilByDeviceID[device.id] = nil
        }

        refreshingFastDpiDeviceIDs.insert(device.id)
        defer { refreshingFastDpiDeviceIDs.remove(device.id) }
        let fastRevision = applyController.stateRevision

        do {
            guard let fast = try await environment.backend.readDpiStagesFast(device: device) else { return }
            guard let presentationDevice = presentationDevice(for: device) else { return }
            let readAt = Date()
            if device.transport == .usb {
                lastUSBFastDpiAtByDeviceID[device.id] = readAt
                lastUSBFastDpiAtByDeviceID[presentationDevice.id] = readAt
            }
            guard fastRevision == applyController.stateRevision else {
                AppLog.debug("AppState", "refreshDpiFast stale-drop rev=\(fastRevision) current=\(applyController.stateRevision)")
                return
            }
            let presentationDeviceID = presentationDevice.id
            let previous = stateCacheByDeviceID[presentationDeviceID] ?? stateCacheByDeviceID[device.id] ?? deviceStore.state
            guard let previous else { return }
            let active = max(0, min(fast.values.count - 1, fast.active))
            let currentDpiValue = fast.values[active]
            let updated = MouseState(
                device: previous.device,
                connection: previous.connection,
                battery_percent: previous.battery_percent,
                charging: previous.charging,
                dpi: DpiPair(x: currentDpiValue, y: currentDpiValue),
                dpi_stages: DpiStages(active_stage: active, values: fast.values),
                poll_rate: previous.poll_rate,
                sleep_timeout: previous.sleep_timeout,
                device_mode: previous.device_mode,
                low_battery_threshold_raw: previous.low_battery_threshold_raw,
                scroll_mode: previous.scroll_mode,
                scroll_acceleration: previous.scroll_acceleration,
                scroll_smart_reel: previous.scroll_smart_reel,
                active_onboard_profile: previous.active_onboard_profile,
                onboard_profile_count: previous.onboard_profile_count,
                led_value: previous.led_value,
                capabilities: previous.capabilities
            )

            let shouldFocusOnActivity = shouldFocusServiceSelectionOnActivity(previous: previous, next: updated)
            cacheState(updated, sourceDeviceID: device.id, presentationDeviceID: presentationDeviceID, updatedAt: readAt)
            if correctionOnly {
                let stillUsesFastPolling = await environment.backend.shouldUseFastDPIPolling(device: device)
                let nextStatus: DpiUpdateTransportStatus = stillUsesFastPolling ? .pollingFallback : .realTimeHID
                setDpiUpdateTransportStatus(nextStatus, for: device.id)
                setDpiUpdateTransportStatus(nextStatus, for: presentationDeviceID)
            } else {
                let existingTransportStatus = dpiUpdateTransportStatusByDeviceID[presentationDeviceID]
                if existingTransportStatus != .listening && existingTransportStatus != .streamActive {
                    setDpiUpdateTransportStatus(.pollingFallback, for: device.id)
                    setDpiUpdateTransportStatus(.pollingFallback, for: presentationDeviceID)
                }
            }
            unavailableDeviceIDs.remove(device.id)
            unavailableDeviceIDs.remove(presentationDeviceID)
            if shouldFocusOnActivity {
                focusServiceSelectionOnActivity(deviceID: presentationDeviceID)
            }
            runtimeController.updateStatusItemTransientDpi(previous: previous, next: updated, deviceID: presentationDeviceID)
            if deviceStore.selectedDeviceID == presentationDeviceID {
                if deviceStore.state != updated {
                    deviceStore.state = updated
                }
                if applyController.shouldHydrateEditable {
                    editorController.hydrateEditable(from: updated)
                }
            }
            AppLog.debug(
                "AppState",
                "refreshDpiFast ok device=\(presentationDeviceID) active=\(active) " +
                "values=\(fast.values.map(String.init).joined(separator: ","))"
            )
        } catch {
            // Ignore fast-poll transient failures to keep UI stable.
        }
    }

    private func setDpiUpdateTransportStatus(_ status: DpiUpdateTransportStatus?, for deviceID: String) {
        let previous = dpiUpdateTransportStatusByDeviceID[deviceID]
        guard previous != status else { return }
        dpiUpdateTransportStatusByDeviceID[deviceID] = status
        deviceStore.invalidateConnectionDiagnostics()
    }

    private static func shouldApplyBackendDpiTransportStatusUpdate(
        current: DpiUpdateTransportStatus?,
        incoming: DpiUpdateTransportStatus
    ) -> Bool {
        guard let current else { return true }
        return dpiTransportStatusPriority(incoming) >= dpiTransportStatusPriority(current)
    }

    private static func dpiTransportStatusPriority(_ status: DpiUpdateTransportStatus) -> Int {
        switch status {
        case .unknown:
            0
        case .pollingFallback:
            1
        case .listening:
            2
        case .streamActive:
            3
        case .realTimeHID:
            4
        case .unsupported:
            5
        }
    }

    nonisolated static func shouldDelayBluetoothRealtimeCorrection(lastHeartbeatAt: Date?, now: Date) -> Bool {
        guard let lastHeartbeatAt else { return false }
        return now.timeIntervalSince(lastHeartbeatAt) < 0.4
    }

    nonisolated static func realtimeCorrectionMinimumInterval(isService: Bool) -> TimeInterval {
        isService ? 0.45 : 1.0
    }

    private func realtimeCorrectionMinimumInterval(for _: MouseDevice) -> TimeInterval {
        Self.realtimeCorrectionMinimumInterval(isService: environment.launchRole.isService)
    }

    nonisolated static func shouldDelayBluetoothRealtimeStateRefresh(
        transport: DeviceTransportKind,
        transportStatus: DpiUpdateTransportStatus?,
        lastHeartbeatAt: Date?,
        lastFullStateRefreshAt: Date?,
        now: Date
    ) -> Bool {
        guard transport == .bluetooth else { return false }
        guard transportStatus == .streamActive || transportStatus == .realTimeHID else { return false }
        guard let lastHeartbeatAt,
              now.timeIntervalSince(lastHeartbeatAt) < 0.8 else {
            return false
        }
        guard let lastFullStateRefreshAt else { return false }
        return now.timeIntervalSince(lastFullStateRefreshAt) < 8.0
    }

    private func restorePersistedLightingIfNeeded(for device: MouseDevice) async {
        guard pendingLightingRestoreDeviceIDs.contains(device.id) else { return }
        guard !restoringLightingDeviceIDs.contains(device.id) else { return }
        guard !(deviceStore.selectedDeviceID == device.id && !applyController.shouldHydrateEditable) else { return }
        guard !applyController.hasPendingLocalEditsAffecting(device) else { return }

        guard let restorePlan = editorController.persistedLightingRestorePlan(device: device) else {
            pendingLightingRestoreDeviceIDs.remove(device.id)
            return
        }

        restoringLightingDeviceIDs.insert(device.id)
        defer { restoringLightingDeviceIDs.remove(device.id) }

        let restored = await applyController.applyPersistedLightingRestore(
            restorePlan.patch,
            to: device,
            usbLightingZoneID: restorePlan.usbLightingZoneID
        )
        if restored {
            pendingLightingRestoreDeviceIDs.remove(device.id)
        }
    }
}
