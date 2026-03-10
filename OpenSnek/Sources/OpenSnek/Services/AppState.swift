import Foundation
import Observation
import OpenSnekAppSupport
import OpenSnekCore
import SwiftUI

struct DeviceStatusIndicator {
    let label: String
    let color: Color
}

@MainActor
@Observable
final class AppState {
    var devices: [MouseDevice] = []
    var selectedDeviceID: String?
    var state: MouseState?
    var availableUpdate: ReleaseAvailability?

    var isLoading = false
    var isApplying = false
    var isRefreshingState = false
    var errorMessage: String?
    var warningMessage: String?
    var lastUpdated: Date?

    var editableStageValues: [Int] = [800, 1600, 3200, 6400, 12000]
    var editableStageCount = 3
    var editableActiveStage = 1
    var editablePollRate = 1000
    var editableSleepTimeout = 300
    var editableDeviceMode = 0x00
    var editableLowBatteryThresholdRaw = 0x26
    var editableScrollMode = 0
    var editableScrollAcceleration = false
    var editableScrollSmartReel = false
    var editableLedBrightness = 64
    var editableLightingEffect: LightingEffectKind = .staticColor
    var editableLightingWaveDirection: LightingWaveDirection = .left
    var editableLightingReactiveSpeed = 2
    var editableColor = RGBColor(r: 0, g: 255, b: 0)
    var editableSecondaryColor = RGBColor(r: 0, g: 170, b: 255)
    let buttonSlots = ButtonSlotDescriptor.defaults
    var editableButtonBindings: [Int: ButtonBindingDraft] = [:]
    var keyboardTextDraftBySlot: [Int: String] = [:]

    private let client = BridgeClient()
    private let applyCoordinator = ApplyCoordinator()
    private let preferenceStore = DevicePreferenceStore()
    private let releaseUpdateChecker = ReleaseUpdateChecker()
    private var isHydrating = false
    private var dpiApplyTask: Task<Void, Never>?
    private var pollApplyTask: Task<Void, Never>?
    private var powerApplyTask: Task<Void, Never>?
    private var deviceModeApplyTask: Task<Void, Never>?
    private var lowBatteryApplyTask: Task<Void, Never>?
    private var scrollModeApplyTask: Task<Void, Never>?
    private var scrollAccelerationApplyTask: Task<Void, Never>?
    private var scrollSmartReelApplyTask: Task<Void, Never>?
    private var ledApplyTask: Task<Void, Never>?
    private var colorApplyTask: Task<Void, Never>?
    private var lightingEffectApplyTask: Task<Void, Never>?
    private var buttonApplyTask: Task<Void, Never>?
    private var activeStageApplyTask: Task<Void, Never>?
    private var hasPendingLocalEdits = false
    private var applyDrainTask: Task<Void, Never>?
    private var stateCacheByDeviceID: [String: MouseState] = [:]
    private var isRefreshingDpiFast = false
    private var suppressFastDpiUntil: Date?
    private var lastUSBFastDpiAt: Date?
    var isEditingDpiControl = false
    private var lastLocalEditAt: Date?
    private var hydratedLightingStateByDeviceID: Set<String> = []
    private var hydratedButtonBindingsDeviceID: String?
    private var keyboardDraftApplyTaskBySlot: [Int: Task<Void, Never>] = [:]
    private var isPollingDevices = false
    private var refreshFailureCountByDeviceID: [String: Int] = [:]
    private var hasCheckedForUpdates = false

    var selectedDevice: MouseDevice? {
        guard let selectedDeviceID else { return nil }
        return devices.first(where: { $0.id == selectedDeviceID })
    }

    var visibleButtonSlots: [ButtonSlotDescriptor] {
        selectedDevice?.button_layout?.visibleSlots ?? buttonSlots
    }

    var currentDeviceStatusIndicator: DeviceStatusIndicator {
        if selectedDevice == nil {
            return DeviceStatusIndicator(label: "Disconnected", color: Color(hex: 0xFF453A))
        }

        if let errorMessage, !errorMessage.isEmpty {
            let lowered = errorMessage.lowercased()
            let label = lowered.contains("no device") || lowered.contains("disconnected") ? "Disconnected" : "Error"
            return DeviceStatusIndicator(label: label, color: Color(hex: 0xFF453A))
        }

        if let selectedDevice {
            let failures = refreshFailureCountByDeviceID[selectedDevice.id] ?? 0
            if failures > 0 {
                return DeviceStatusIndicator(label: "Poll Delayed", color: Color(hex: 0xFFD60A))
            }
        }

        if let lastUpdated {
            let age = Date().timeIntervalSince(lastUpdated)
            if age > 4.5 {
                return DeviceStatusIndicator(label: "Poll Delayed", color: Color(hex: 0xFFD60A))
            }
            return DeviceStatusIndicator(label: "Connected", color: Color(hex: 0x30D158))
        }

        return DeviceStatusIndicator(label: "Poll Delayed", color: Color(hex: 0xFFD60A))
    }

    func isButtonSlotEditable(_ slot: Int) -> Bool {
        selectedDevice?.button_layout?.isEditable(slot) ?? true
    }

    func buttonSlotNotice(_ slot: Int) -> String? {
        selectedDevice?.button_layout?.notice(for: slot)
    }

    func refreshDevices() async {
        let start = Date()
        AppLog.event("AppState", "refreshDevices start")
        isLoading = true
        defer { isLoading = false }

        do {
            let listed = try await client.listDevices()
            _ = applyDeviceList(listed, source: "refresh")
            errorMessage = nil
        } catch {
            AppLog.error("AppState", "refreshDevices failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        await refreshState()
        AppLog.event("AppState", "refreshDevices end elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
    }

    func checkForUpdates(force: Bool = false) async {
        guard force || !hasCheckedForUpdates else { return }
        hasCheckedForUpdates = true

        guard let currentVersion = ReleaseUpdateChecker.currentAppVersion() else { return }

        do {
            availableUpdate = try await releaseUpdateChecker.checkForUpdate(currentVersion: currentVersion)
            if let availableUpdate {
                AppLog.event("AppState", "update available current=\(currentVersion) latest=\(availableUpdate.latestVersion)")
            }
        } catch {
            AppLog.debug("AppState", "checkForUpdates failed: \(error.localizedDescription)")
        }
    }

    func pollDevicePresence() async {
        guard !isPollingDevices, !isLoading else { return }
        isPollingDevices = true
        defer { isPollingDevices = false }

        do {
            let listed = try await client.listDevices()
            let changed = applyDeviceList(listed, source: "poll")
            if changed {
                errorMessage = nil
                await refreshState()
            } else if selectedDevice != nil, state == nil {
                await refreshState()
            }
        } catch {
            AppLog.debug("AppState", "pollDevicePresence failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func applyDeviceList(_ listed: [MouseDevice], source: String) -> Bool {
        let sorted = listed.sorted { $0.product_name < $1.product_name }
        let previousDevices = devices
        let previousIDs = Set(previousDevices.map(\.id))
        let previousSelectedID = selectedDeviceID
        let previousSelectedDevice = previousDevices.first(where: { $0.id == previousSelectedID })
        let previousSelectedIdentity = previousSelectedDevice.map { deviceIdentityKey($0) }

        let newIDs = Set(sorted.map(\.id))
        let removedIDs = previousIDs.subtracting(newIDs)
        if !removedIDs.isEmpty {
            hydratedLightingStateByDeviceID.subtract(removedIDs)
            if let hydratedButtonBindingsDeviceID, removedIDs.contains(hydratedButtonBindingsDeviceID) {
                self.hydratedButtonBindingsDeviceID = nil
            }
            for id in removedIDs {
                refreshFailureCountByDeviceID[id] = nil
            }
        }

        devices = sorted
        if let previousSelectedID, newIDs.contains(previousSelectedID) {
            selectedDeviceID = previousSelectedID
        } else if let previousSelectedIdentity,
                  let match = sorted.first(where: { deviceIdentityKey($0) == previousSelectedIdentity }) {
            selectedDeviceID = match.id
        } else {
            selectedDeviceID = sorted.first?.id
        }

        if let selectedDeviceID, let cached = stateCacheByDeviceID[selectedDeviceID] {
            state = cached
        } else if selectedDeviceID == nil {
            state = nil
        }

        let changed = previousIDs != newIDs || previousSelectedID != selectedDeviceID
        if changed {
            AppLog.event(
                "AppState",
                "applyDeviceList source=\(source) count=\(sorted.count) selected=\(selectedDeviceID ?? "nil")"
            )
        }
        return changed
    }

    private func deviceIdentityKey(_ device: MouseDevice) -> String {
        if let serial = device.serial?
            .trimmingCharacters(in: .whitespacesAndNewlines),
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

    func refreshState() async {
        guard let selectedDevice else {
            state = nil
            return
        }
        guard !isRefreshingState, !isApplying, !hasPendingLocalEdits else {
            AppLog.debug(
                "AppState",
                "refreshState skipped refreshing=\(isRefreshingState) applying=\(isApplying) pendingEdits=\(hasPendingLocalEdits)"
            )
            return
        }

        if let cached = stateCacheByDeviceID[selectedDevice.id] {
            state = cached
        }

        isRefreshingState = true
        defer { isRefreshingState = false }
        let refreshRevision = applyCoordinator.stateRevision

        let start = Date()
        do {
            let fetched = try await client.readState(device: selectedDevice)
            guard refreshRevision == applyCoordinator.stateRevision else {
                AppLog.debug("AppState", "refreshState stale-drop rev=\(refreshRevision) current=\(applyCoordinator.stateRevision)")
                return
            }
            let merged = fetched.merged(with: stateCacheByDeviceID[selectedDevice.id])
            stateCacheByDeviceID[selectedDevice.id] = merged
            refreshFailureCountByDeviceID[selectedDevice.id] = 0
            if state != merged {
                state = merged
            }
            lastUpdated = Date()
            if shouldHydrateEditable {
                hydrateEditable(from: merged)
                await hydrateLightingStateIfNeeded(device: selectedDevice)
                await hydrateButtonBindingsIfNeeded(device: selectedDevice)
            }
            errorMessage = nil
            warningMessage = telemetryWarning(for: merged, device: selectedDevice)
            AppLog.debug(
                "AppState",
                "refreshState ok device=\(selectedDevice.id) active=\(merged.dpi_stages.active_stage.map(String.init) ?? "nil") " +
                "values=\(merged.dpi_stages.values?.map(String.init).joined(separator: ",") ?? "nil") " +
                "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s"
            )
        } catch {
            let failures = (refreshFailureCountByDeviceID[selectedDevice.id] ?? 0) + 1
            refreshFailureCountByDeviceID[selectedDevice.id] = failures
            if stateCacheByDeviceID[selectedDevice.id] == nil {
                AppLog.error("AppState", "refreshState failed no-cache: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
                warningMessage = nil
            } else {
                // Keep last known-good UI stable on transient polling failures.
                AppLog.debug("AppState", "refreshState transient-failure masked: \(error.localizedDescription)")
                if failures >= 3 {
                    errorMessage = "Device read is failing repeatedly (\(failures)x): \(error.localizedDescription)"
                } else {
                    errorMessage = nil
                }
                warningMessage = "Using the last known values while live telemetry settles."
            }
        }
    }

    func updateStage(_ index: Int, value: Int) {
        guard index >= 0 && index < editableStageValues.count else { return }
        editableStageValues[index] = max(100, min(30000, value))
    }

    func stageValue(_ index: Int) -> Int {
        guard index >= 0 && index < editableStageValues.count else { return 800 }
        return editableStageValues[index]
    }

    func applyDpiStages() async {
        let count = max(1, min(5, editableStageCount))
        let values = Array(editableStageValues.prefix(count)).map { max(100, min(30000, $0)) }
        let active = max(0, min(count - 1, editableActiveStage - 1))

        enqueueApply(DevicePatch(dpiStages: values, activeStage: active))
    }

    func scheduleAutoApplyDpi() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        dpiApplyTask?.cancel()
        dpiApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 320_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyDpiStages()
        }
    }

    func applyActiveStageOnly() async {
        let count = max(1, min(5, editableStageCount))
        let values = Array(editableStageValues.prefix(count)).map { max(100, min(30000, $0)) }
        let active = max(0, min(count - 1, editableActiveStage - 1))
        enqueueApply(DevicePatch(dpiStages: values, activeStage: active))
    }

    func scheduleAutoApplyActiveStage() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        activeStageApplyTask?.cancel()
        activeStageApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyActiveStageOnly()
        }
    }

    func applyPollRate() async {
        enqueueApply(DevicePatch(pollRate: editablePollRate))
    }

    func scheduleAutoApplyPollRate() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        pollApplyTask?.cancel()
        pollApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyPollRate()
        }
    }

    func applySleepTimeout() async {
        enqueueApply(DevicePatch(sleepTimeout: editableSleepTimeout))
    }

    func scheduleAutoApplySleepTimeout() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        powerApplyTask?.cancel()
        powerApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 260_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applySleepTimeout()
        }
    }

    func applyDeviceMode() async {
        let mode = editableDeviceMode == 0x03 ? 0x03 : 0x00
        enqueueApply(DevicePatch(deviceMode: DeviceMode(mode: mode, param: 0x00)))
    }

    func scheduleAutoApplyDeviceMode() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        deviceModeApplyTask?.cancel()
        deviceModeApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyDeviceMode()
        }
    }

    func applyLowBatteryThreshold() async {
        let raw = max(0x0C, min(0x3F, editableLowBatteryThresholdRaw))
        enqueueApply(DevicePatch(lowBatteryThresholdRaw: raw))
    }

    func scheduleAutoApplyLowBatteryThreshold() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        lowBatteryApplyTask?.cancel()
        lowBatteryApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyLowBatteryThreshold()
        }
    }

    func applyScrollMode() async {
        enqueueApply(DevicePatch(scrollMode: max(0, min(1, editableScrollMode))))
    }

    func scheduleAutoApplyScrollMode() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        scrollModeApplyTask?.cancel()
        scrollModeApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyScrollMode()
        }
    }

    func applyScrollAcceleration() async {
        enqueueApply(DevicePatch(scrollAcceleration: editableScrollAcceleration))
    }

    func scheduleAutoApplyScrollAcceleration() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        scrollAccelerationApplyTask?.cancel()
        scrollAccelerationApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyScrollAcceleration()
        }
    }

    func applyScrollSmartReel() async {
        enqueueApply(DevicePatch(scrollSmartReel: editableScrollSmartReel))
    }

    func scheduleAutoApplyScrollSmartReel() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        scrollSmartReelApplyTask?.cancel()
        scrollSmartReelApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyScrollSmartReel()
        }
    }

    func applyLedBrightness() async {
        enqueueApply(DevicePatch(ledBrightness: editableLedBrightness))
    }

    func scheduleAutoApplyLedBrightness() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        ledApplyTask?.cancel()
        ledApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyLedBrightness()
        }
    }

    func applyLedColor() async {
        enqueueApply(DevicePatch(ledRGB: RGBPatch(r: editableColor.r, g: editableColor.g, b: editableColor.b)))
    }

    func scheduleAutoApplyLedColor() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        colorApplyTask?.cancel()
        colorApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyLedColor()
        }
    }

    func applyLightingEffect() async {
        guard let selectedDevice else { return }
        if !selectedDevice.supports_advanced_lighting_effects {
            editableLightingEffect = .staticColor
            enqueueApply(DevicePatch(ledRGB: RGBPatch(r: editableColor.r, g: editableColor.g, b: editableColor.b)))
            return
        }
        enqueueApply(DevicePatch(lightingEffect: currentLightingEffectPatch()))
    }

    func scheduleAutoApplyLightingEffect() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        lightingEffectApplyTask?.cancel()
        lightingEffectApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyLightingEffect()
        }
    }

    func updateLightingEffect(_ kind: LightingEffectKind) {
        guard selectedDevice?.supports_advanced_lighting_effects == true else {
            editableLightingEffect = .staticColor
            return
        }
        editableLightingEffect = kind
    }

    func updateLightingWaveDirection(_ direction: LightingWaveDirection) {
        editableLightingWaveDirection = direction
    }

    func updateLightingReactiveSpeed(_ speed: Int) {
        editableLightingReactiveSpeed = max(1, min(4, speed))
    }

    private func applyButtonBinding(slot: Int) async {
        let resolved = editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        let binding = ButtonBindingPatch(
            slot: slot,
            kind: resolved.kind,
            hidKey: resolved.kind == .keyboardSimple ? resolved.hidKey : nil,
            turboEnabled: resolved.kind.supportsTurbo ? resolved.turboEnabled : false,
            turboRate: resolved.kind.supportsTurbo && resolved.turboEnabled ? resolved.turboRate : nil
        )
        enqueueApply(DevicePatch(buttonBinding: binding))
    }

    func scheduleAutoApplyButton(slot: Int) {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        buttonApplyTask?.cancel()
        buttonApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 260_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyButtonBinding(slot: slot)
        }
    }

    func buttonBindingKind(for slot: Int) -> ButtonBindingKind {
        editableButtonBindings[slot]?.kind ?? defaultButtonBinding(for: slot).kind
    }

    func buttonBindingHidKey(for slot: Int) -> Int {
        editableButtonBindings[slot]?.hidKey ?? defaultButtonBinding(for: slot).hidKey
    }

    func buttonBindingTurboEnabled(for slot: Int) -> Bool {
        editableButtonBindings[slot]?.turboEnabled ?? defaultButtonBinding(for: slot).turboEnabled
    }

    func buttonBindingTurboRate(for slot: Int) -> Int {
        editableButtonBindings[slot]?.turboRate ?? defaultButtonBinding(for: slot).turboRate
    }

    func buttonBindingTurboRatePressesPerSecond(for slot: Int) -> Int {
        Self.turboRawToPressesPerSecond(buttonBindingTurboRate(for: slot))
    }

    func updateButtonBindingKind(slot: Int, kind: ButtonBindingKind) {
        guard buttonSlots.contains(where: { $0.slot == slot }) else { return }
        var next = editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        next.kind = kind
        if kind != .keyboardSimple {
            keyboardDraftApplyTaskBySlot[slot]?.cancel()
            keyboardDraftApplyTaskBySlot[slot] = nil
            next.hidKey = 4
            keyboardTextDraftBySlot[slot] = nil
        } else {
            keyboardTextDraftBySlot[slot] = AppState.keyboardText(forHidKey: next.hidKey) ?? ""
        }
        if !kind.supportsTurbo {
            next.turboEnabled = false
        }
        editableButtonBindings[slot] = next
        scheduleAutoApplyButton(slot: slot)
    }

    func updateButtonBindingHidKey(slot: Int, hidKey: Int) {
        guard buttonSlots.contains(where: { $0.slot == slot }) else { return }
        var next = editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        next.kind = .keyboardSimple
        next.hidKey = max(4, min(231, hidKey))
        editableButtonBindings[slot] = next
        keyboardTextDraftBySlot[slot] = AppState.keyboardText(forHidKey: next.hidKey) ?? ""
        scheduleAutoApplyButton(slot: slot)
    }

    func updateButtonBindingTurboEnabled(slot: Int, enabled: Bool) {
        guard buttonSlots.contains(where: { $0.slot == slot }) else { return }
        var next = editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        guard next.kind.supportsTurbo else { return }
        next.turboEnabled = enabled
        editableButtonBindings[slot] = next
        scheduleAutoApplyButton(slot: slot)
    }

    func updateButtonBindingTurboRate(slot: Int, rate: Int) {
        guard buttonSlots.contains(where: { $0.slot == slot }) else { return }
        var next = editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        guard next.kind.supportsTurbo else { return }
        next.turboRate = max(1, min(255, rate))
        editableButtonBindings[slot] = next
        scheduleAutoApplyButton(slot: slot)
    }

    func updateButtonBindingTurboPressesPerSecond(slot: Int, pressesPerSecond: Int) {
        let pps = max(1, min(20, pressesPerSecond))
        updateButtonBindingTurboRate(slot: slot, rate: Self.turboPressesPerSecondToRaw(pps))
    }

    func keyboardTextDraft(for slot: Int) -> String {
        if let draft = keyboardTextDraftBySlot[slot] {
            return draft
        }
        let hidKey = buttonBindingHidKey(for: slot)
        return AppState.keyboardText(forHidKey: hidKey) ?? ""
    }

    func updateKeyboardTextDraft(slot: Int, text: String) {
        guard buttonSlots.contains(where: { $0.slot == slot }) else { return }
        keyboardTextDraftBySlot[slot] = text
        keyboardDraftApplyTaskBySlot[slot]?.cancel()
        keyboardDraftApplyTaskBySlot[slot] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 320_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.applyKeyboardTextDraft(slot: slot)
        }
    }

    func refreshDpiFast() async {
        guard let selectedDevice else { return }
        guard selectedDevice.transport == .bluetooth || selectedDevice.transport == .usb else { return }
        guard !isRefreshingDpiFast, !isRefreshingState, !isApplying else { return }
        guard !hasPendingLocalEdits else { return }
        if selectedDevice.transport == .usb,
           let lastUSBFastDpiAt,
           Date().timeIntervalSince(lastUSBFastDpiAt) < 0.55 {
            return
        }
        if let until = suppressFastDpiUntil {
            if Date() < until { return }
            suppressFastDpiUntil = nil
        }

        isRefreshingDpiFast = true
        defer { isRefreshingDpiFast = false }
            let fastRevision = applyCoordinator.stateRevision

        do {
            guard let fast = try await client.readDpiStagesFast(device: selectedDevice) else { return }
            if selectedDevice.transport == .usb {
                lastUSBFastDpiAt = Date()
            }
            guard fastRevision == applyCoordinator.stateRevision else {
                AppLog.debug("AppState", "refreshDpiFast stale-drop rev=\(fastRevision) current=\(applyCoordinator.stateRevision)")
                return
            }
            let previous = stateCacheByDeviceID[selectedDevice.id] ?? state
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
                led_value: previous.led_value,
                capabilities: previous.capabilities
            )

            stateCacheByDeviceID[selectedDevice.id] = updated
            if state != updated {
                state = updated
            }
            if shouldHydrateEditable {
                hydrateEditable(from: updated)
            }
        } catch {
            // Ignore fast-poll transient failures to keep UI stable.
        }
    }

    private func enqueueApply(_ patch: DevicePatch) {
        _ = applyCoordinator.enqueue(patch)
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()

        if applyDrainTask == nil {
            applyDrainTask = Task { [weak self] in
                await self?.drainApplyQueue()
            }
        }
    }

    private func drainApplyQueue() async {
        while let patch = applyCoordinator.dequeue() {
            await applyNow(patch: patch)
            hasPendingLocalEdits = applyCoordinator.hasPending
        }
        hasPendingLocalEdits = false
        applyDrainTask = nil
    }

    private func applyNow(patch: DevicePatch) async {
        guard let selectedDevice else {
            errorMessage = "No device selected"
            return
        }

        applyCoordinator.bumpRevision()
        AppLog.event("AppState", "apply start device=\(selectedDevice.id) patch=\(patch.describe)")
        isApplying = true
        defer { isApplying = false }

        let start = Date()
        do {
            let next = try await client.apply(device: selectedDevice, patch: patch)
            let merged = next.merged(with: stateCacheByDeviceID[selectedDevice.id])
            stateCacheByDeviceID[selectedDevice.id] = merged
            if state != merged {
                state = merged
            }
            let localEditsChangedDuringApply = (lastLocalEditAt ?? .distantPast) > start
            let shouldHydrateEditableState = !localEditsChangedDuringApply && !applyCoordinator.hasPending
            if patch.dpiStages != nil || patch.activeStage != nil {
                // Avoid showing transient in-flight stage states from fast polling
                // while BLE latching settles after a write.
                suppressFastDpiUntil = Date().addingTimeInterval(0.9)
            }
            lastUpdated = Date()
            if shouldHydrateEditableState {
                lastLocalEditAt = nil
                hydrateEditable(from: merged)
            } else {
                AppLog.debug(
                    "AppState",
                    "apply hydrate skipped pending=\(applyCoordinator.hasPending) localEditsDuringApply=\(localEditsChangedDuringApply)"
                )
            }
            if patch.ledRGB != nil {
                persistLightingColor(editableColor, device: selectedDevice)
                hydratedLightingStateByDeviceID.insert(selectedDevice.id)
            }
            if let lightingEffect = patch.lightingEffect {
                persistLightingEffect(lightingEffect, device: selectedDevice)
                persistLightingColor(
                    RGBColor(
                        r: lightingEffect.primary.r,
                        g: lightingEffect.primary.g,
                        b: lightingEffect.primary.b
                    ),
                    device: selectedDevice
                )
                hydratedLightingStateByDeviceID.insert(selectedDevice.id)
            }
            if let buttonBinding = patch.buttonBinding {
                persistButtonBinding(buttonBinding, device: selectedDevice)
                hydratedButtonBindingsDeviceID = selectedDevice.id
            }
            errorMessage = nil
            warningMessage = telemetryWarning(for: merged, device: selectedDevice)
            AppLog.event(
                "AppState",
                "apply ok device=\(selectedDevice.id) active=\(merged.dpi_stages.active_stage.map(String.init) ?? "nil") " +
                "values=\(merged.dpi_stages.values?.map(String.init).joined(separator: ",") ?? "nil") " +
                "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s"
            )
        } catch {
            AppLog.error("AppState", "apply failed device=\(selectedDevice.id): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            warningMessage = nil
        }
    }

    private var shouldHydrateEditable: Bool {
        guard !isApplying, !isEditingDpiControl, !hasPendingLocalEdits else { return false }
        guard let lastLocalEditAt else { return true }
        return Date().timeIntervalSince(lastLocalEditAt) > 0.8
    }

    private func telemetryWarning(for state: MouseState, device: MouseDevice) -> String? {
        guard device.transport == .usb else { return nil }
        var missing: [String] = []
        if state.dpi_stages.values == nil { missing.append("DPI stages") }
        if state.poll_rate == nil { missing.append("poll rate") }
        if state.led_value == nil { missing.append("lighting") }
        guard !missing.isEmpty else { return nil }
        return "USB telemetry is incomplete (missing \(missing.joined(separator: ", "))). " +
            "Controls stay visible, but values may be stale until readback succeeds."
    }

    private func hydrateEditable(from state: MouseState) {
        isHydrating = true
        defer { isHydrating = false }

        if let values = state.dpi_stages.values, !values.isEmpty {
            editableStageCount = max(1, min(5, values.count))
            for i in 0..<editableStageValues.count {
                if i < values.count {
                    editableStageValues[i] = max(100, min(30000, values[i]))
                }
            }
        } else if let dpi = state.dpi?.x {
            editableStageCount = 1
            editableStageValues[0] = max(100, min(30000, dpi))
        }

        if let active = state.dpi_stages.active_stage {
            let maxStage = max(1, editableStageCount)
            editableActiveStage = max(1, min(maxStage, active + 1))
        } else {
            editableActiveStage = 1
        }

        if let poll = state.poll_rate {
            editablePollRate = poll
        }

        if let timeout = state.sleep_timeout {
            editableSleepTimeout = max(60, min(900, timeout))
        }

        if let mode = state.device_mode?.mode {
            editableDeviceMode = mode == 0x03 ? 0x03 : 0x00
        }

        if let lowBatteryRaw = state.low_battery_threshold_raw {
            editableLowBatteryThresholdRaw = max(0x0C, min(0x3F, lowBatteryRaw))
        }

        if let scrollMode = state.scroll_mode {
            editableScrollMode = max(0, min(1, scrollMode))
        }

        if let scrollAcceleration = state.scroll_acceleration {
            editableScrollAcceleration = scrollAcceleration
        }

        if let scrollSmartReel = state.scroll_smart_reel {
            editableScrollSmartReel = scrollSmartReel
        }

        if let led = state.led_value {
            editableLedBrightness = led
        }
    }

    private func hydrateLightingStateIfNeeded(device: MouseDevice) async {
        guard !hydratedLightingStateByDeviceID.contains(device.id) else { return }
        var loadedPersistedColor = false

        if device.transport == .bluetooth,
           let persisted = loadPersistedLightingColor(device: device) {
            editableColor = persisted
            loadedPersistedColor = true
            AppLog.debug(
                "AppState",
                "hydrated Bluetooth lighting color from persisted cache id=\(device.id) rgb=(\(persisted.r),\(persisted.g),\(persisted.b))"
            )
        } else if device.transport == .bluetooth,
                  let rgb = try? await client.readLightingColor(device: device) {
            editableColor = RGBColor(r: rgb.r, g: rgb.g, b: rgb.b)
            persistLightingColor(editableColor, device: device)
            AppLog.debug("AppState", "hydrated Bluetooth lighting color from device id=\(device.id) rgb=(\(rgb.r),\(rgb.g),\(rgb.b))")
        } else if let persisted = loadPersistedLightingColor(device: device) {
            editableColor = persisted
            loadedPersistedColor = true
            AppLog.debug(
                "AppState",
                "hydrated lighting color from persisted cache id=\(device.id) rgb=(\(persisted.r),\(persisted.g),\(persisted.b))"
            )
        } else {
            AppLog.debug("AppState", "lighting color read unavailable for device id=\(device.id)")
        }

        if device.supports_advanced_lighting_effects, let persistedEffect = loadPersistedLightingEffect(device: device) {
            editableLightingEffect = persistedEffect.kind
            editableLightingWaveDirection = persistedEffect.waveDirection
            editableLightingReactiveSpeed = persistedEffect.reactiveSpeed
            editableSecondaryColor = persistedEffect.secondaryColor
            AppLog.debug(
                "AppState",
                "hydrated lighting effect from persisted cache id=\(device.id) kind=\(persistedEffect.kind.rawValue)"
            )
        } else if !device.supports_advanced_lighting_effects {
            editableLightingEffect = .staticColor
        }

        if loadedPersistedColor, device.transport == .bluetooth {
            enqueueApply(DevicePatch(ledRGB: RGBPatch(r: editableColor.r, g: editableColor.g, b: editableColor.b)))
            AppLog.debug("AppState", "queued persisted lighting color reapply id=\(device.id)")
        }

        hydratedLightingStateByDeviceID.insert(device.id)
    }

    private func persistLightingColor(_ color: RGBColor, device: MouseDevice) {
        preferenceStore.persistLightingColor(color, device: device)
    }

    private func loadPersistedLightingColor(device: MouseDevice) -> RGBColor? {
        preferenceStore.loadPersistedLightingColor(device: device)
    }

    private func persistLightingEffect(_ effect: LightingEffectPatch, device: MouseDevice) {
        preferenceStore.persistLightingEffect(effect, device: device)
    }

    private func loadPersistedLightingEffect(device: MouseDevice) -> (
        kind: LightingEffectKind,
        waveDirection: LightingWaveDirection,
        reactiveSpeed: Int,
        secondaryColor: RGBColor
    )? {
        preferenceStore.loadPersistedLightingEffect(device: device)
    }

    private func hydrateButtonBindingsIfNeeded(device: MouseDevice) async {
        guard hydratedButtonBindingsDeviceID != device.id else { return }

        var hydrated = loadPersistedButtonBindings(device: device)
        if device.transport == .usb, let fromDevice = await loadUSBButtonBindingsFromDevice(device: device) {
            hydrated.merge(fromDevice) { _, fromDevice in fromDevice }
            savePersistedButtonBindings(device: device, bindings: hydrated)
            AppLog.debug(
                "AppState",
                "hydrated button bindings from USB readback id=\(device.id) slots=\(fromDevice.keys.sorted())"
            )
        } else {
            AppLog.debug(
                "AppState",
                "hydrated button bindings from persisted cache id=\(device.id) slots=\(hydrated.keys.sorted())"
            )
        }

        editableButtonBindings = hydrated
        keyboardTextDraftBySlot = hydrated.reduce(into: [:]) { partialResult, pair in
            let slot = pair.key
            let draft = pair.value
            if draft.kind == .keyboardSimple {
                partialResult[slot] = AppState.keyboardText(forHidKey: draft.hidKey) ?? ""
            }
        }
        hydratedButtonBindingsDeviceID = device.id
    }

    private func loadUSBButtonBindingsFromDevice(device: MouseDevice) async -> [Int: ButtonBindingDraft]? {
        let slots = buttonSlots
            .map(\.slot)
            .filter { $0 != 6 }
        var bindings: [Int: ButtonBindingDraft] = [:]
        var readAnyBlock = false

        for slot in slots {
            do {
                let persistentBlock = try await client.debugUSBReadButtonBinding(device: device, slot: slot, profile: 0x01)
                let directBlock: [UInt8]?
                if persistentBlock == nil {
                    directBlock = try await client.debugUSBReadButtonBinding(device: device, slot: slot, profile: 0x00)
                } else {
                    directBlock = nil
                }
                let block = persistentBlock ?? directBlock
                if let block {
                    readAnyBlock = true
                    if let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(slot: slot, functionBlock: block) {
                        bindings[slot] = draft
                    }
                }
            } catch {
                AppLog.debug(
                    "AppState",
                    "usb button hydration read failed id=\(device.id) slot=\(slot): \(error.localizedDescription)"
                )
            }
        }

        guard readAnyBlock else { return nil }
        return bindings
    }

    private func persistButtonBinding(_ binding: ButtonBindingPatch, device: MouseDevice) {
        preferenceStore.persistButtonBinding(binding, device: device)
    }

    private func savePersistedButtonBindings(device: MouseDevice, bindings: [Int: ButtonBindingDraft]) {
        preferenceStore.savePersistedButtonBindings(device: device, bindings: bindings)
    }

    private func loadPersistedButtonBindings(device: MouseDevice) -> [Int: ButtonBindingDraft] {
        preferenceStore.loadPersistedButtonBindings(device: device)
    }

    private func defaultButtonBinding(for slot: Int) -> ButtonBindingDraft {
        ButtonBindingSupport.defaultButtonBinding(for: slot)
    }

    private func currentLightingEffectPatch() -> LightingEffectPatch {
        LightingEffectPatch(
            kind: editableLightingEffect,
            primary: RGBPatch(r: editableColor.r, g: editableColor.g, b: editableColor.b),
            secondary: RGBPatch(r: editableSecondaryColor.r, g: editableSecondaryColor.g, b: editableSecondaryColor.b),
            waveDirection: editableLightingWaveDirection,
            reactiveSpeed: editableLightingReactiveSpeed
        )
    }

    private func applyKeyboardTextDraft(slot: Int) {
        guard let text = keyboardTextDraftBySlot[slot] else { return }
        guard let hidKey = AppState.hidKey(fromKeyboardText: text) else { return }
        updateButtonBindingHidKey(slot: slot, hidKey: hidKey)
    }

    private static func hidKey(fromKeyboardText text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        if text == " " { return 44 }
        let normalized = text.trimmingCharacters(in: .newlines).lowercased()
        switch normalized {
        case "enter", "return":
            return 40
        case "esc", "escape":
            return 41
        case "tab":
            return 43
        case "space":
            return 44
        default:
            break
        }

        guard let scalar = normalized.unicodeScalars.first else { return nil }
        let value = scalar.value

        if value >= 97 && value <= 122 { // a-z
            return 4 + Int(value - 97)
        }
        if value >= 49 && value <= 57 { // 1-9
            return 30 + Int(value - 49)
        }
        if value == 48 { // 0
            return 39
        }

        switch Character(scalar) {
        case "-": return 45
        case "=": return 46
        case "[": return 47
        case "]": return 48
        case "\\": return 49
        case ";": return 51
        case "'": return 52
        case "`": return 53
        case ",": return 54
        case ".": return 55
        case "/": return 56
        default: return nil
        }
    }

    private static func keyboardText(forHidKey hidKey: Int) -> String? {
        if hidKey >= 4 && hidKey <= 29 {
            return String(UnicodeScalar(hidKey - 4 + 97)!)
        }
        if hidKey >= 30 && hidKey <= 38 {
            return String(hidKey - 30 + 1)
        }
        if hidKey == 39 { return "0" }

        switch hidKey {
        case 40: return "enter"
        case 41: return "esc"
        case 43: return "tab"
        case 44: return "space"
        case 45: return "-"
        case 46: return "="
        case 47: return "["
        case 48: return "]"
        case 49: return "\\"
        case 51: return ";"
        case 52: return "'"
        case 53: return "`"
        case 54: return ","
        case 55: return "."
        case 56: return "/"
        default: return nil
        }
    }

    static func turboRawToPressesPerSecond(_ rawRate: Int) -> Int {
        ButtonBindingSupport.turboRawToPressesPerSecond(rawRate)
    }

    static func turboPressesPerSecondToRaw(_ pressesPerSecond: Int) -> Int {
        ButtonBindingSupport.turboPressesPerSecondToRaw(pressesPerSecond)
    }
}

private extension DevicePatch {
    var describe: String {
        var parts: [String] = []
        if let deviceMode { parts.append("mode=(\(deviceMode.mode),\(deviceMode.param))") }
        if let lowBatteryThresholdRaw { parts.append("lowBatt=0x\(String(lowBatteryThresholdRaw, radix: 16))") }
        if let scrollMode { parts.append("scrollMode=\(scrollMode)") }
        if let scrollAcceleration { parts.append("scrollAccel=\(scrollAcceleration)") }
        if let scrollSmartReel { parts.append("smartReel=\(scrollSmartReel)") }
        if let pollRate { parts.append("poll=\(pollRate)") }
        if let sleepTimeout { parts.append("sleep=\(sleepTimeout)") }
        if let dpiStages { parts.append("stages=\(dpiStages)") }
        if let activeStage { parts.append("active=\(activeStage)") }
        if let ledBrightness { parts.append("led=\(ledBrightness)") }
        if let ledRGB { parts.append("rgb=(\(ledRGB.r),\(ledRGB.g),\(ledRGB.b))") }
        if let lightingEffect {
            var detail = "fx=\(lightingEffect.kind.rawValue)"
            if lightingEffect.kind.usesWaveDirection {
                detail += ",dir=\(lightingEffect.waveDirection.rawValue)"
            }
            if lightingEffect.kind.usesReactiveSpeed {
                detail += ",speed=\(lightingEffect.reactiveSpeed)"
            }
            if lightingEffect.kind.usesPrimaryColor {
                detail += ",p=(\(lightingEffect.primary.r),\(lightingEffect.primary.g),\(lightingEffect.primary.b))"
            }
            if lightingEffect.kind.usesSecondaryColor {
                detail += ",s=(\(lightingEffect.secondary.r),\(lightingEffect.secondary.g),\(lightingEffect.secondary.b))"
            }
            parts.append(detail)
        }
        if let buttonBinding {
            var detail = "button(slot=\(buttonBinding.slot),kind=\(buttonBinding.kind.rawValue)"
            if buttonBinding.turboEnabled {
                detail += ",turbo=on,rate=\(buttonBinding.turboRate ?? 0x8E)"
            }
            detail += ")"
            parts.append(detail)
        }
        return parts.isEmpty ? "empty" : parts.joined(separator: " ")
    }
}
