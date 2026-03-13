import AppKit
import Foundation
import OpenSnekCore

@MainActor
final class AppStateRuntimeController {
    private let environment: AppEnvironment
    private unowned let deviceStore: DeviceStore
    private unowned let runtimeStore: RuntimeStore
    private weak var deviceControllerStorage: AppStateDeviceController?

    private var runtimeTask: Task<Void, Never>?
    private var didStartRuntime = false
    private var compactMenuPresented = false
    private var compactInteractionUntil: Date?
    private var lastRefreshStatePollAt: Date = .distantPast
    private var lastDevicePresencePollAt: Date = .distantPast
    private var lastFastDpiPollAt: Date = .distantPast
    private var transientStatusUntil: Date?
    private(set) var isBackendReady = false
    private var clientPresenceObserver: NSObjectProtocol?
    private var backendStateUpdatesTask: Task<Void, Never>?
    private var remoteClientPresenceByProcessID: [Int32: RemoteClientPresenceState] = [:]
    private var lastRemoteClientPresencePingAt: Date = .distantPast
    private var statusItemTransientDpiResetTask: Task<Void, Never>?

    init(environment: AppEnvironment, deviceStore: DeviceStore, runtimeStore: RuntimeStore) {
        self.environment = environment
        self.deviceStore = deviceStore
        self.runtimeStore = runtimeStore
    }

    func tearDown() {
        runtimeTask?.cancel()
        backendStateUpdatesTask?.cancel()
        statusItemTransientDpiResetTask?.cancel()
        if let clientPresenceObserver {
            CrossProcessStateSync.removeObserver(clientPresenceObserver)
        }
        clientPresenceObserver = nil
    }

    func bind(deviceController: AppStateDeviceController) {
        self.deviceControllerStorage = deviceController
    }

    private var deviceController: AppStateDeviceController {
        guard let deviceControllerStorage else {
            preconditionFailure("AppStateRuntimeController accessed before deviceController was bound")
        }
        return deviceControllerStorage
    }

    var compactStatusMessage: String? {
        guard let serviceStatusMessage = runtimeStore.serviceStatusMessage,
              let transientStatusUntil,
              Date() < transientStatusUntil else {
            return nil
        }
        return serviceStatusMessage
    }

    func setBackendReady(_ ready: Bool) {
        isBackendReady = ready
    }

    func refreshHIDAccessStatus() async {
        runtimeStore.hidAccessStatus = await environment.backend.hidAccessStatus()
    }

    func resetAllPermissions() async {
        guard !runtimeStore.isResettingPermissions else { return }

        runtimeStore.isResettingPermissions = true
        defer { runtimeStore.isResettingPermissions = false }

        do {
            let result = try PermissionSupport.resetAllPermissions(
                bundleIdentifier: runtimeStore.hidAccessStatus.bundleIdentifier
            )
            runtimeStore.permissionStatusMessage =
                "Permissions reset for \(result.bundleIdentifier). Re-enable Input Monitoring, then relaunch Open Snek."
            PermissionSupport.openInputMonitoringSettings()
        } catch {
            runtimeStore.permissionStatusMessage = "Permission reset failed: \(error.localizedDescription)"
        }

        await refreshHIDAccessStatus()
    }

    func setCompactInteraction(until date: Date?) {
        compactInteractionUntil = date
    }

    func setTransientStatus(until date: Date?) {
        transientStatusUntil = date
    }

    func clearStatusItemTransientDpi(cancelTask: Bool = true) {
        if cancelTask {
            statusItemTransientDpiResetTask?.cancel()
        }
        statusItemTransientDpiResetTask = nil
        runtimeStore.statusItemTransientDpi = nil
    }

    func updateStatusItemTransientDpi(previous: MouseState?, next: MouseState, deviceID: String) {
        guard environment.launchRole.isService else { return }
        guard deviceStore.selectedDeviceID == deviceID else { return }
        guard let previousDpi = resolvedDpi(from: previous),
              let nextDpi = resolvedDpi(from: next),
              previousDpi != nextDpi else {
            return
        }

        presentStatusItemTransientDpi(nextDpi)
    }

    var currentPollingProfile: PollingProfile {
        pollingProfile(at: Date())
    }

    func pollingProfile(at now: Date) -> PollingProfile {
        if !environment.launchRole.isService {
            return .foreground
        }
        if compactMenuPresented {
            return .serviceInteractive
        }
        if hasActiveRemoteClients(at: now) {
            return .serviceInteractive
        }
        if let compactInteractionUntil, now < compactInteractionUntil {
            return .serviceInteractive
        }
        return .serviceIdle
    }

    func activeFastPollingDeviceIDs(at now: Date) -> [String] {
        let liveIDs = Set(deviceStore.devices.map(\.id))
        var ordered: [String] = []
        var seen: Set<String> = []

        for deviceID in localFastPollingDeviceIDs(at: now) {
            guard liveIDs.contains(deviceID) else { continue }
            guard seen.insert(deviceID).inserted else { continue }
            ordered.append(deviceID)
        }

        let remoteSelectedDeviceIDs = activeRemoteSelectedDeviceIDs(at: now)
        for deviceID in remoteSelectedDeviceIDs {
            guard liveIDs.contains(deviceID) else { continue }
            guard seen.insert(deviceID).inserted else { continue }
            ordered.append(deviceID)
        }

        if environment.launchRole.isService,
           hasActiveRemoteClients(at: now),
           remoteSelectedDeviceIDs.isEmpty,
           let selectedDeviceID = deviceStore.selectedDeviceID,
           liveIDs.contains(selectedDeviceID),
           seen.insert(selectedDeviceID).inserted {
            ordered.append(selectedDeviceID)
        }

        return ordered
    }

    func recordRemoteClientPresence(_ presence: CrossProcessClientPresence, now: Date = Date()) {
        guard environment.launchRole.isService else { return }
        guard presence.sourceProcessID > 0 else { return }
        let hadActiveRemoteClients = hasActiveRemoteClients(at: now)
        pruneExpiredRemoteClientPresence(now: now)
        let previous = remoteClientPresenceByProcessID[presence.sourceProcessID]
        remoteClientPresenceByProcessID[presence.sourceProcessID] = RemoteClientPresenceState(
            expiresAt: now.addingTimeInterval(2.5),
            selectedDeviceID: presence.selectedDeviceID
        )
        let selectedDeviceChanged = previous?.selectedDeviceID != presence.selectedDeviceID
        if !hadActiveRemoteClients || selectedDeviceChanged {
            requestImmediateRuntimePoll(resetPollingDeadlines: true)
        }
    }

    func installCrossProcessObservers() {
        guard clientPresenceObserver == nil else { return }
        clientPresenceObserver = CrossProcessStateSync.observeClientPresence { [weak self] presence in
            Task { [weak self] in
                await self?.handleRemoteClientPresence(presence)
            }
        }
    }

    func restartBackendStateUpdates() async {
        backendStateUpdatesTask?.cancel()
        let stream = await environment.backend.stateUpdates()
        backendStateUpdatesTask = Task { [weak self] in
            guard let self else { return }
            for await update in stream {
                await self.handleBackendStateUpdate(update)
            }
        }
    }

    private func handleBackendStateUpdate(_ update: BackendStateUpdate) async {
        guard isBackendReady else { return }
        switch update {
        case .deviceList(let devices, _):
            await deviceController.handleBackendDeviceListUpdate(devices)
        case .snapshot(let snapshot):
            guard environment.usesRemoteServiceUpdates else { return }
            deviceController.applyRemoteServiceSnapshot(snapshot)
        case .deviceState(let deviceID, let updatedState, let updatedAt):
            deviceController.applyBackendDeviceStateUpdate(deviceID: deviceID, state: updatedState, updatedAt: updatedAt)
        }
    }

    private func handleRemoteClientPresence(_ presence: CrossProcessClientPresence) async {
        recordRemoteClientPresence(presence)
    }

    private func resolvedDpi(from state: MouseState?) -> Int? {
        guard let state else { return nil }

        if let liveDpi = state.dpi?.x, liveDpi > 0 {
            return liveDpi
        }

        guard let values = state.dpi_stages.values, !values.isEmpty else { return nil }
        let active = max(0, min(values.count - 1, state.dpi_stages.active_stage ?? 0))
        return values[active]
    }

    private func presentStatusItemTransientDpi(_ dpi: Int) {
        guard dpi > 0 else { return }

        runtimeStore.statusItemTransientDpi = dpi
        statusItemTransientDpiResetTask?.cancel()
        let durationNanos = UInt64(max(0, runtimeStore.statusItemDpiDisplayDuration) * 1_000_000_000)
        statusItemTransientDpiResetTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: durationNanos)
            } catch {
                return
            }

            self?.clearStatusItemTransientDpi(cancelTask: false)
        }
    }

    func start() async {
        guard !didStartRuntime else { return }
        didStartRuntime = true

        if environment.launchRole.isService {
            do {
                try await environment.serviceCoordinator.registerServiceHostIfNeeded(backend: LocalBridgeBackend.shared)
            } catch {
                runtimeStore.serviceStatusMessage = "Service host failed: \(error.localizedDescription)"
            }
            isBackendReady = true
        } else {
            await configureBackendForCurrentPreferences()
        }

        await refreshHIDAccessStatus()

        if environment.usesRemoteServiceUpdates {
            await bootstrapRemoteStateIfNeeded()
            sendRemoteClientPresence()
        } else {
            await deviceController.refreshDevices()
        }
        if !environment.launchRole.isService {
            await checkForUpdates()
        }

        runtimeTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollRuntimeOnce()
                let sleepInterval = self.runtimeSleepInterval(after: Date())
                let sleepNanos = UInt64((sleepInterval * 1_000_000_000).rounded())
                try? await Task.sleep(nanoseconds: sleepNanos)
            }
        }
    }

    func setCompactMenuPresented(_ isPresented: Bool) {
        let presentationChanged = compactMenuPresented != isPresented
        compactMenuPresented = isPresented
        if isPresented {
            compactInteractionUntil = Date().addingTimeInterval(3.0)
            if presentationChanged {
                requestImmediateRuntimePoll(resetPollingDeadlines: true)
            }
        }
    }

    func setBackgroundServiceEnabled(_ enabled: Bool) async {
        runtimeStore.backgroundServiceEnabled = enabled
        environment.serviceCoordinator.setBackgroundServiceEnabled(enabled)
        if !enabled, runtimeStore.launchAtStartupEnabled {
            setLaunchAtStartupEnabled(false)
        }

        if enabled {
            do {
                environment.backend = try await environment.serviceCoordinator.connectOrLaunchService()
                await restartBackendStateUpdates()
                isBackendReady = true
                await refreshHIDAccessStatus()
                runtimeStore.serviceStatusMessage = "Menu bar service connected"
                transientStatusUntil = Date().addingTimeInterval(3.0)
                deviceStore.errorMessage = nil
            } catch {
                environment.backend = LocalBridgeBackend.shared
                await restartBackendStateUpdates()
                isBackendReady = true
                await refreshHIDAccessStatus()
                runtimeStore.backgroundServiceEnabled = false
                environment.serviceCoordinator.setBackgroundServiceEnabled(false)
                deviceStore.errorMessage = "Background service unavailable: \(error.localizedDescription)"
            }
        } else {
            environment.backend = LocalBridgeBackend.shared
            await restartBackendStateUpdates()
            isBackendReady = true
            await refreshHIDAccessStatus()
            if environment.launchRole.isService {
                environment.serviceCoordinator.stopCurrentServiceHostIfNeeded()
                NSApp.terminate(nil)
                return
            } else {
                environment.serviceCoordinator.stopServiceProcess()
            }
            runtimeStore.serviceStatusMessage = "Menu bar service stopped"
            transientStatusUntil = Date().addingTimeInterval(3.0)
        }

        if environment.usesRemoteServiceUpdates {
            await bootstrapRemoteStateIfNeeded()
            sendRemoteClientPresence()
        } else {
            await deviceController.refreshDevices()
        }
    }

    func setLaunchAtStartupEnabled(_ enabled: Bool) {
        do {
            try environment.serviceCoordinator.setLaunchAtStartupEnabled(enabled)
            runtimeStore.launchAtStartupEnabled = enabled
        } catch {
            deviceStore.errorMessage = "Launch at startup failed: \(error.localizedDescription)"
            runtimeStore.launchAtStartupEnabled = environment.serviceCoordinator.launchAtStartupEnabled
        }
    }

    func openFullAppFromService() {
        environment.serviceCoordinator.launchFullAppProcess()
    }

    func openSettingsFromService() {
        environment.serviceCoordinator.launchFullAppProcess(arguments: ["--open-settings"])
    }

    func prepareForCurrentServiceProcessTermination() {
        environment.serviceCoordinator.stopCurrentServiceHostIfNeeded()
    }

    func terminateServiceProcess() {
        environment.serviceCoordinator.terminateOtherRunningApplicationInstances()
        prepareForCurrentServiceProcessTermination()
        NSApp.terminate(nil)
    }

    func refreshNow() async {
        if environment.usesRemoteServiceUpdates {
            await bootstrapRemoteStateIfNeeded(force: true)
            sendRemoteClientPresence()
        } else {
            await deviceController.refreshDevices()
        }
        compactInteractionUntil = Date().addingTimeInterval(3.0)
    }

    func sendRemoteClientPresence() {
        guard environment.usesRemoteServiceUpdates else { return }
        lastRemoteClientPresencePingAt = Date()
        CrossProcessStateSync.postClientPresence(selectedDeviceID: deviceStore.selectedDeviceID)
    }

    private func configureBackendForCurrentPreferences() async {
        do {
            environment.backend = try await environment.serviceCoordinator.makeBackendForCurrentMode()
            await restartBackendStateUpdates()
            isBackendReady = true
            await refreshHIDAccessStatus()
            if runtimeStore.backgroundServiceEnabled {
                runtimeStore.serviceStatusMessage = "Menu bar service connected"
                transientStatusUntil = Date().addingTimeInterval(2.0)
            }
        } catch {
            environment.backend = LocalBridgeBackend.shared
            await restartBackendStateUpdates()
            isBackendReady = true
            await refreshHIDAccessStatus()
            deviceStore.errorMessage = "Background service unavailable: \(error.localizedDescription)"
        }
    }

    private func checkForUpdates(force: Bool = false) async {
        guard force || !environment.hasCheckedForUpdates else { return }
        environment.hasCheckedForUpdates = true

        guard let currentVersion = ReleaseUpdateChecker.currentAppVersion() else { return }

        do {
            deviceStore.availableUpdate = try await environment.releaseUpdateChecker.checkForUpdate(currentVersion: currentVersion)
            if let availableUpdate = deviceStore.availableUpdate {
                AppLog.event("AppState", "update available current=\(currentVersion) latest=\(availableUpdate.latestVersion)")
            }
        } catch {
            AppLog.debug("AppState", "checkForUpdates failed: \(error.localizedDescription)")
        }
    }

    private func bootstrapRemoteStateIfNeeded(force: Bool = false) async {
        guard environment.usesRemoteServiceUpdates else { return }
        if !force,
           !deviceStore.devices.isEmpty,
           deviceStore.state != nil {
            return
        }
        await deviceController.refreshDevices()
    }

    func runtimeSleepInterval(after now: Date) -> TimeInterval {
        RuntimeWakeSchedule.nextSleepInterval(
            now: now,
            profile: pollingProfile(at: now),
            usesRemoteServiceUpdates: environment.usesRemoteServiceUpdates,
            lastDevicePresencePollAt: lastDevicePresencePollAt,
            lastRefreshStatePollAt: lastRefreshStatePollAt,
            lastFastDpiPollAt: lastFastDpiPollAt,
            lastRemoteClientPresencePingAt: lastRemoteClientPresencePingAt,
            transientStatusUntil: transientStatusUntil,
            nextRemoteClientPresenceExpiry: remoteClientPresenceByProcessID
                .values
                .map(\.expiresAt)
                .filter { $0 > now }
                .min()
        )
    }

    private func pollRuntimeOnce() async {
        let now = Date()
        let profile = pollingProfile(at: now)
        pruneExpiredRemoteClientPresence(now: now)

        if environment.usesRemoteServiceUpdates {
            if now.timeIntervalSince(lastRemoteClientPresencePingAt) >= 1.0 {
                lastRemoteClientPresencePingAt = now
                CrossProcessStateSync.postClientPresence(selectedDeviceID: deviceStore.selectedDeviceID)
            }
            clearTransientStatusIfExpired(now: now)
            return
        }

        if now.timeIntervalSince(lastDevicePresencePollAt) >= profile.devicePresenceInterval {
            lastDevicePresencePollAt = now
            await deviceController.pollDevicePresence()
        }

        if now.timeIntervalSince(lastRefreshStatePollAt) >= profile.refreshStateInterval {
            lastRefreshStatePollAt = now
            await deviceController.refreshAllDeviceStates()
        }

        if let fastInterval = profile.fastDpiInterval,
           now.timeIntervalSince(lastFastDpiPollAt) >= fastInterval {
            lastFastDpiPollAt = now
            await deviceController.refreshDpiFast()
        }

        clearTransientStatusIfExpired(now: now)
    }

    private func clearTransientStatusIfExpired(now: Date) {
        if let transientStatusUntil, now >= transientStatusUntil {
            self.transientStatusUntil = nil
            if compactStatusMessage == nil {
                runtimeStore.serviceStatusMessage = nil
            }
        }
    }

    private func requestImmediateRuntimePoll(resetPollingDeadlines: Bool) {
        guard didStartRuntime else { return }
        if resetPollingDeadlines {
            lastDevicePresencePollAt = .distantPast
            lastRefreshStatePollAt = .distantPast
            lastFastDpiPollAt = .distantPast
        }
        Task { [weak self] in
            await self?.pollRuntimeOnce()
        }
    }

    private func hasActiveRemoteClients(at now: Date) -> Bool {
        remoteClientPresenceByProcessID.values.contains { $0.expiresAt > now }
    }

    private func activeRemoteSelectedDeviceIDs(at now: Date) -> [String] {
        remoteClientPresenceByProcessID
            .values
            .filter { $0.expiresAt > now }
            .compactMap(\.selectedDeviceID)
    }

    private func localFastPollingDeviceIDs(at now: Date) -> [String] {
        guard let selectedDeviceID = deviceStore.selectedDeviceID else { return [] }
        if environment.launchRole.isService {
            let localInteractive = compactMenuPresented || (compactInteractionUntil.map { now < $0 } ?? false)
            return localInteractive ? [selectedDeviceID] : []
        }
        return environment.usesRemoteServiceUpdates ? [] : [selectedDeviceID]
    }

    private func pruneExpiredRemoteClientPresence(now: Date) {
        guard !remoteClientPresenceByProcessID.isEmpty else { return }
        let expiredProcessIDs = remoteClientPresenceByProcessID.compactMap { processID, state in
            state.expiresAt <= now ? processID : nil
        }
        guard !expiredProcessIDs.isEmpty else { return }
        for processID in expiredProcessIDs {
            remoteClientPresenceByProcessID.removeValue(forKey: processID)
        }
    }
}
