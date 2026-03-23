import Foundation
import OpenSnekAppSupport
import OpenSnekCore

@MainActor
final class AppStateApplyController {
    private let environment: AppEnvironment
    private let deviceStore: DeviceStore
    private let editorStore: EditorStore
    private let runtimeStore: RuntimeStore
    @WeakBound("AppStateApplyController", dependency: "deviceController")
    private var deviceController: AppStateDeviceController
    @WeakBound("AppStateApplyController", dependency: "editorController")
    private var editorController: AppStateEditorController
    @WeakBound("AppStateApplyController", dependency: "runtimeController")
    private var runtimeController: AppStateRuntimeController

    private let applyCoordinator = ApplyCoordinator()
    private enum ApplyTaskKey: Hashable {
        case dpi
        case pollRate
        case power
        case lowBattery
        case scrollMode
        case scrollAcceleration
        case scrollSmartReel
        case ledBrightness
        case ledColor
        case lightingEffect
        case button
        case activeStage
    }

    private var applyTasks: [ApplyTaskKey: Task<Void, Never>] = [:]
    private(set) var hasPendingLocalEdits = false
    private var applyDrainTask: Task<Void, Never>?
    private var lastLocalEditAt: Date?
    private var localEditDeviceIdentityKey: String?

    init(
        environment: AppEnvironment,
        deviceStore: DeviceStore,
        editorStore: EditorStore,
        runtimeStore: RuntimeStore
    ) {
        self.environment = environment
        self.deviceStore = deviceStore
        self.editorStore = editorStore
        self.runtimeStore = runtimeStore
    }

    func tearDown() {
        for task in applyTasks.values {
            task.cancel()
        }
        applyTasks.removeAll()
        applyDrainTask?.cancel()
    }

    func bind(
        deviceController: AppStateDeviceController,
        editorController: AppStateEditorController,
        runtimeController: AppStateRuntimeController
    ) {
        _deviceController.bind(deviceController)
        _editorController.bind(editorController)
        _runtimeController.bind(runtimeController)
    }

    var stateRevision: UInt64 {
        applyCoordinator.stateRevision
    }

    var shouldHydrateEditable: Bool {
        guard !deviceStore.isApplying, !editorStore.isEditingDpiControl, !hasPendingLocalEdits else { return false }
        guard let lastLocalEditAt else { return true }
        return Date().timeIntervalSince(lastLocalEditAt) > 0.8
    }

    func applyDpiStages() async {
        let count = max(1, min(5, editorStore.editableStageCount))
        let profileID = deviceStore.selectedDevice?.profile_id
        let values = Array(editorStore.editableStageValues.prefix(count)).map { DeviceProfiles.clampDPI($0, profileID: profileID) }
        let active = max(0, min(count - 1, editorStore.editableActiveStage - 1))
        enqueueApply(DevicePatch(dpiStages: values, activeStage: active))
    }

    func scheduleAutoApplyDpi() {
        scheduleAutoApply(key: .dpi, delay: 320_000_000) { [weak self] in
            guard let self else { return }
            await self.applyDpiStages()
        }
    }

    func applyActiveStageOnly() async {
        await applyDpiStages()
    }

    func scheduleAutoApplyActiveStage() {
        scheduleAutoApply(key: .activeStage, delay: 80_000_000) { [weak self] in
            guard let self else { return }
            await self.applyActiveStageOnly()
        }
    }

    func applyPollRate() async {
        enqueueApply(DevicePatch(pollRate: editorStore.editablePollRate))
    }

    func scheduleAutoApplyPollRate() {
        scheduleAutoApply(key: .pollRate, delay: 250_000_000) { [weak self] in
            guard let self else { return }
            await self.applyPollRate()
        }
    }

    func applySleepTimeout() async {
        enqueueApply(DevicePatch(sleepTimeout: editorStore.editableSleepTimeout))
    }

    func scheduleAutoApplySleepTimeout() {
        scheduleAutoApply(key: .power, delay: 260_000_000) { [weak self] in
            guard let self else { return }
            await self.applySleepTimeout()
        }
    }

    func applyLowBatteryThreshold() async {
        let raw = max(0x0C, min(0x3F, editorStore.editableLowBatteryThresholdRaw))
        enqueueApply(DevicePatch(lowBatteryThresholdRaw: raw))
    }

    func scheduleAutoApplyLowBatteryThreshold() {
        scheduleAutoApply(key: .lowBattery, delay: 220_000_000) { [weak self] in
            guard let self else { return }
            await self.applyLowBatteryThreshold()
        }
    }

    func applyScrollMode() async {
        enqueueApply(DevicePatch(scrollMode: max(0, min(1, editorStore.editableScrollMode))))
    }

    func scheduleAutoApplyScrollMode() {
        scheduleAutoApply(key: .scrollMode, delay: 220_000_000) { [weak self] in
            guard let self else { return }
            await self.applyScrollMode()
        }
    }

    func applyScrollAcceleration() async {
        enqueueApply(DevicePatch(scrollAcceleration: editorStore.editableScrollAcceleration))
    }

    func scheduleAutoApplyScrollAcceleration() {
        scheduleAutoApply(key: .scrollAcceleration, delay: 220_000_000) { [weak self] in
            guard let self else { return }
            await self.applyScrollAcceleration()
        }
    }

    func applyScrollSmartReel() async {
        enqueueApply(DevicePatch(scrollSmartReel: editorStore.editableScrollSmartReel))
    }

    func scheduleAutoApplyScrollSmartReel() {
        scheduleAutoApply(key: .scrollSmartReel, delay: 220_000_000) { [weak self] in
            guard let self else { return }
            await self.applyScrollSmartReel()
        }
    }

    func applyLedBrightness() async {
        enqueueApply(DevicePatch(ledBrightness: editorStore.editableLedBrightness))
    }

    func scheduleAutoApplyLedBrightness() {
        scheduleAutoApply(key: .ledBrightness, delay: 180_000_000) { [weak self] in
            guard let self else { return }
            await self.applyLedBrightness()
        }
    }

    func applyLedColor() async {
        enqueueApply(
            DevicePatch(
                ledRGB: RGBPatch(r: editorStore.editableColor.r, g: editorStore.editableColor.g, b: editorStore.editableColor.b),
                usbLightingZoneLEDIDs: editorController.currentUSBLightingZoneLEDIDs()
            )
        )
    }

    func scheduleAutoApplyLedColor() {
        scheduleAutoApply(key: .ledColor, delay: 200_000_000) { [weak self] in
            guard let self else { return }
            await self.applyLedColor()
        }
    }

    func applyLightingEffect() async {
        guard let selectedDevice = deviceStore.selectedDevice else { return }
        if !selectedDevice.supports_advanced_lighting_effects {
            editorStore.editableLightingEffect = .staticColor
            enqueueApply(DevicePatch(ledRGB: RGBPatch(r: editorStore.editableColor.r, g: editorStore.editableColor.g, b: editorStore.editableColor.b)))
            return
        }
        enqueueApply(
            DevicePatch(
                lightingEffect: editorController.currentLightingEffectPatch(),
                usbLightingZoneLEDIDs: editorController.currentUSBLightingZoneLEDIDs()
            )
        )
    }

    func scheduleAutoApplyLightingEffect() {
        scheduleAutoApply(key: .lightingEffect, delay: 200_000_000) { [weak self] in
            guard let self else { return }
            await self.applyLightingEffect()
        }
    }

    func applyButtonBinding(slot: Int) async {
        let resolved = editorStore.editableButtonBindings[slot] ?? editorController.defaultButtonBinding(for: slot)
        let binding = ButtonBindingPatch(
            slot: slot,
            kind: resolved.kind,
            hidKey: resolved.kind == .keyboardSimple ? resolved.hidKey : nil,
            turboEnabled: resolved.kind.supportsTurbo ? resolved.turboEnabled : false,
            turboRate: resolved.kind.supportsTurbo && resolved.turboEnabled ? resolved.turboRate : nil,
            clutchDPI: resolved.kind == .dpiClutch ? resolved.clutchDPI ?? ButtonBindingSupport.defaultDPIClutchDPI(for: deviceStore.selectedDevice?.profile_id) : nil,
            persistentProfile: editorStore.editableUSBButtonProfile,
            writeDirectLayer: !editorStore.supportsMultipleOnboardProfiles || editorStore.editableUSBButtonProfile == editorStore.activeOnboardProfile
        )
        enqueueApply(DevicePatch(buttonBinding: binding))
    }

    func scheduleAutoApplyButton(slot: Int) {
        scheduleAutoApply(key: .button, delay: 260_000_000) { [weak self] in
            guard let self else { return }
            await self.applyButtonBinding(slot: slot)
        }
    }

    private func scheduleAutoApply(
        key: ApplyTaskKey,
        delay: UInt64 = 220_000_000,
        action: @escaping @MainActor () async -> Void
    ) {
        guard !editorController.isHydrating else { return }
        markLocalEditsPending()
        applyTasks[key]?.cancel()
        applyTasks[key] = Task {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    func markLocalEditsPending() {
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        localEditDeviceIdentityKey = deviceStore.selectedDevice.map(deviceController.deviceIdentityKey)
    }

    func hasPendingLocalEditsAffecting(_ device: MouseDevice) -> Bool {
        guard hasPendingLocalEdits else { return false }
        guard let localEditDeviceIdentityKey else { return false }
        return localEditDeviceIdentityKey == deviceController.deviceIdentityKey(device)
    }

    func enqueueApply(_ patch: DevicePatch) {
        _ = applyCoordinator.enqueue(patch)
        markLocalEditsPending()

        if applyDrainTask == nil {
            applyDrainTask = Task { [weak self] in
                await self?.drainApplyQueue()
            }
        }
    }

    @discardableResult
    func applyPersistedLightingRestore(
        _ patch: DevicePatch,
        to device: MouseDevice,
        usbLightingZoneID: String
    ) async -> Bool {
        let selectedIdentity = deviceStore.selectedDevice.map(deviceController.deviceIdentityKey)
        let targetIdentity = deviceController.deviceIdentityKey(device)
        let targetsSelectedDevice = selectedIdentity == targetIdentity
        return await apply(
            device: device,
            patch: patch,
            markApplyingState: targetsSelectedDevice,
            shouldFocusOnActivity: false,
            shouldSurfaceApplyFailure: targetsSelectedDevice,
            persistLightingZoneID: usbLightingZoneID,
            clearLocalEditsOnSuccess: false
        )
    }

    private func drainApplyQueue() async {
        while let patch = applyCoordinator.dequeue() {
            await applySelectedPatch(patch)
            hasPendingLocalEdits = applyCoordinator.hasPending
        }
        hasPendingLocalEdits = false
        localEditDeviceIdentityKey = nil
        applyDrainTask = nil
    }

    private func applySelectedPatch(_ patch: DevicePatch) async {
        guard let selectedDevice = deviceStore.selectedDevice else {
            AppLog.warning("AppState", "apply skipped with no selected device patch=\(patch.describe)")
            deviceStore.errorMessage = "No device selected"
            return
        }
        _ = await apply(
            device: selectedDevice,
            patch: patch,
            markApplyingState: true,
            shouldFocusOnActivity: true,
            shouldSurfaceApplyFailure: true,
            persistLightingZoneID: editorStore.editableUSBLightingZoneID,
            clearLocalEditsOnSuccess: true
        )
    }

    @discardableResult
    private func apply(
        device targetDevice: MouseDevice,
        patch: DevicePatch,
        markApplyingState: Bool,
        shouldFocusOnActivity: Bool,
        shouldSurfaceApplyFailure: Bool,
        persistLightingZoneID: String,
        clearLocalEditsOnSuccess: Bool
    ) async -> Bool {
        applyCoordinator.bumpRevision()
        AppLog.event("AppState", "apply start device=\(targetDevice.id) patch=\(patch.describe)")
        if markApplyingState {
            deviceStore.isApplying = true
        }
        defer {
            if markApplyingState {
                deviceStore.isApplying = false
            }
        }

        let start = Date()
        let applyDeviceID = targetDevice.id

        do {
            let next = try await environment.backend.apply(device: targetDevice, patch: patch)
            guard let presentationDevice = deviceController.presentationDevice(for: targetDevice) else {
                let merged = next.merged(with: deviceController.cachedState(for: applyDeviceID))
                deviceController.storeState(merged, for: applyDeviceID, updatedAt: Date())
                AppLog.debug("AppState", "apply result cached for missing-presentation device=\(applyDeviceID)")
                return true
            }

            let presentationDeviceID = presentationDevice.id
            let merged = next.merged(
                with: deviceController.cachedState(for: presentationDeviceID) ?? deviceController.cachedState(for: applyDeviceID)
            )
            deviceController.cacheState(merged, sourceDeviceID: applyDeviceID, presentationDeviceID: presentationDeviceID)
            if shouldFocusOnActivity {
                deviceController.focusServiceSelectionOnActivity(deviceID: presentationDeviceID)
            }

            if deviceStore.selectedDeviceID == presentationDeviceID, deviceStore.state != merged {
                deviceStore.state = merged
            }

            let localEditsChangedDuringApply = clearLocalEditsOnSuccess && (lastLocalEditAt ?? .distantPast) > start
            let shouldHydrateEditableState = clearLocalEditsOnSuccess && !localEditsChangedDuringApply && !applyCoordinator.hasPending
            if patch.dpiStages != nil || patch.activeStage != nil {
                let suppressedUntil = Date().addingTimeInterval(0.9)
                deviceController.setFastDpiSuppressed(until: suppressedUntil, for: applyDeviceID)
                deviceController.setFastDpiSuppressed(until: suppressedUntil, for: presentationDeviceID)
                runtimeController.setCompactInteraction(until: Date().addingTimeInterval(3.0))
            }

            if shouldHydrateEditableState, deviceStore.selectedDeviceID == presentationDeviceID {
                lastLocalEditAt = nil
                editorController.hydrateEditable(from: merged)
            } else if deviceStore.selectedDeviceID == presentationDeviceID {
                AppLog.debug(
                    "AppState",
                    "apply hydrate skipped pending=\(applyCoordinator.hasPending) localEditsDuringApply=\(localEditsChangedDuringApply)"
                )
            }

            persistSuccessfulLightingPatch(
                patch,
                device: presentationDevice,
                usbLightingZoneID: persistLightingZoneID
            )
            if let buttonBinding = patch.buttonBinding {
                editorController.persistButtonBinding(buttonBinding, device: presentationDevice, profile: buttonBinding.persistentProfile)
                editorController.markButtonBindingsHydrated(device: presentationDevice)
            }

            if deviceStore.selectedDeviceID == presentationDeviceID {
                deviceStore.errorMessage = nil
                deviceController.setTelemetryWarning(
                    editorController.telemetryWarning(for: merged, device: presentationDevice),
                    device: presentationDevice
                )
            }

            AppLog.event(
                "AppState",
                "apply ok device=\(presentationDevice.id) active=\(merged.dpi_stages.active_stage.map(String.init) ?? "nil") " +
                "values=\(merged.dpi_stages.values?.map(String.init).joined(separator: ",") ?? "nil") " +
                "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s"
            )
            return true
        } catch {
            AppLog.error("AppState", "apply failed device=\(targetDevice.id): \(error.localizedDescription)")
            if shouldSurfaceApplyFailure {
                let shouldShowApplyFailure: Bool
                if let currentSelectedDevice = deviceStore.selectedDevice {
                    shouldShowApplyFailure = deviceController.deviceIdentityKey(currentSelectedDevice) ==
                        deviceController.deviceIdentityKey(targetDevice)
                } else {
                    shouldShowApplyFailure = false
                }
                if shouldShowApplyFailure {
                    deviceStore.errorMessage = error.localizedDescription
                    deviceStore.warningMessage = nil
                    if patch.dpiStages != nil || patch.activeStage != nil {
                        runtimeStore.serviceStatusMessage = "DPI update failed"
                        runtimeController.setTransientStatus(until: Date().addingTimeInterval(4.0))
                    }
                } else {
                    AppLog.debug("AppState", "apply failure masked for no-longer-selected device=\(targetDevice.id)")
                }
            } else {
                AppLog.debug("AppState", "apply failure masked for non-selected restore device=\(targetDevice.id)")
            }
            return false
        }
    }

    private func persistSuccessfulLightingPatch(
        _ patch: DevicePatch,
        device: MouseDevice,
        usbLightingZoneID: String
    ) {
        if let rgb = patch.ledRGB {
            let colorZoneID = usbLightingZoneID == "all" ? nil : usbLightingZoneID
            editorController.persistLightingColor(
                RGBColor(r: rgb.r, g: rgb.g, b: rgb.b),
                device: device,
                zoneID: colorZoneID
            )
            editorController.persistLightingZoneID(usbLightingZoneID, device: device)
        }
        if let lightingEffect = patch.lightingEffect {
            let colorZoneID = lightingEffect.kind == .staticColor && usbLightingZoneID != "all"
                ? usbLightingZoneID
                : nil
            editorController.persistLightingEffect(lightingEffect, device: device)
            editorController.persistLightingColor(
                RGBColor(r: lightingEffect.primary.r, g: lightingEffect.primary.g, b: lightingEffect.primary.b),
                device: device,
                zoneID: colorZoneID
            )
            editorController.persistLightingZoneID(
                lightingEffect.kind == .staticColor ? usbLightingZoneID : "all",
                device: device
            )
        }
    }
}
