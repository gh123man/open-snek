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
        case button(Int)
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
        shouldHydrateEditable(for: deviceStore.selectedDevice)
    }

    func shouldHydrateEditable(for device: MouseDevice?) -> Bool {
        guard !deviceStore.isApplying, !editorStore.isEditingDpiControl else { return false }
        guard let device else { return !hasPendingLocalEdits }
        guard !hasPendingLocalEditsAffecting(device) else { return false }
        guard let lastLocalEditAt else { return true }
        guard let localEditDeviceIdentityKey else { return true }
        guard localEditDeviceIdentityKey == deviceController.deviceIdentityKey(device) else { return true }
        return Date().timeIntervalSince(lastLocalEditAt) > 0.8
    }

    func applyDpiStages() async {
        let count = max(1, min(5, editorStore.editableStageCount))
        let profileID = deviceStore.selectedDevice?.profile_id
        let values = Array(editorStore.editableStageValues.prefix(count)).map { DeviceProfiles.clampDPI($0, profileID: profileID) }
        let pairs = Array(editorStore.editableStagePairs.prefix(count)).map { pair in
            DpiPair(
                x: DeviceProfiles.clampDPI(pair.x, profileID: profileID),
                y: DeviceProfiles.clampDPI(pair.y, profileID: profileID)
            )
        }
        let active = max(0, min(count - 1, editorStore.editableActiveStage - 1))
        enqueueApply(DevicePatch(dpiStages: values, dpiStagePairs: pairs, activeStage: active))
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

    func applyCurrentStaticColorToAllZones() async {
        guard editorStore.editableLightingEffect == .staticColor else { return }
        guard deviceStore.selectedDevice != nil else {
            deviceStore.errorMessage = "No device selected"
            return
        }

        cancelScheduledApply(for: .ledColor)
        cancelScheduledApply(for: .lightingEffect)

        if deviceStore.selectedDevice?.supports_advanced_lighting_effects == true {
            enqueueApply(DevicePatch(lightingEffect: editorController.currentLightingEffectPatch()))
        } else {
            enqueueApply(
                DevicePatch(
                    ledRGB: RGBPatch(
                        r: editorStore.editableColor.r,
                        g: editorStore.editableColor.g,
                        b: editorStore.editableColor.b
                    )
                )
            )
        }
    }

    private func makeButtonBindingPatch(
        slot: Int,
        persistentProfile: Int,
        writePersistentLayer: Bool = true,
        writeDirectLayer: Bool
    ) -> ButtonBindingPatch {
        let resolved = editorStore.editableButtonBindings[slot] ?? editorController.defaultButtonBinding(for: slot)
        let applied: ButtonBindingDraft
        if resolved.kind == .default {
            applied = ButtonBindingSupport.semanticDefaultButtonBinding(
                for: slot,
                profileID: deviceStore.selectedDevice?.profile_id
            ) ?? resolved
        } else {
            applied = resolved
        }
        return ButtonBindingPatch(
            slot: slot,
            kind: applied.kind,
            hidKey: applied.kind == .keyboardSimple ? applied.hidKey : nil,
            turboEnabled: applied.kind.supportsTurbo ? applied.turboEnabled : false,
            turboRate: applied.kind.supportsTurbo && applied.turboEnabled ? applied.turboRate : nil,
            clutchDPI: applied.kind == .dpiClutch ? applied.clutchDPI ?? ButtonBindingSupport.defaultDPIClutchDPI(for: deviceStore.selectedDevice?.profile_id) : nil,
            persistentProfile: persistentProfile,
            writePersistentLayer: writePersistentLayer,
            writeDirectLayer: writeDirectLayer
        )
    }

    func applyButtonBinding(slot: Int) async {
        guard let selectedDevice = deviceStore.selectedDevice else { return }
        let binding = makeButtonBindingPatch(
            slot: slot,
            persistentProfile: persistentProfileForSingleButtonApply(device: selectedDevice),
            writeDirectLayer: true
        )
        enqueueApply(DevicePatch(buttonBinding: binding))
    }

    func scheduleAutoApplyButton(slot: Int) {
        scheduleAutoApply(key: .button(slot), delay: 120_000_000) { [weak self] in
            guard let self else { return }
            await self.applyButtonBinding(slot: slot)
        }
    }

    func scheduleAutoApplyCurrentButtonWorkspaceToLive() {
        scheduleAutoApply(key: .button(-1), delay: 260_000_000) { [weak self] in
            guard let self else { return }
            await self.applyCurrentButtonWorkspaceToLive()
        }
    }

    private func writableButtonSlots(for device: MouseDevice) -> [Int] {
        device.button_layout?.writableSlots ?? deviceStore.visibleButtonSlots.map(\.slot)
    }

    private func shouldTreatCurrentSourceAsExactMouseSlot(device: MouseDevice) -> Int? {
        guard case .mouseSlot(let slot)? = editorController.currentButtonProfileSource(),
              !editorController.buttonWorkspaceHasUnsavedSourceChanges(device: device) else {
            return nil
        }
        return slot
    }

    private func persistentProfileForSingleButtonApply(device: MouseDevice) -> Int {
        guard device.transport == .usb, editorStore.supportsMultipleOnboardProfiles else {
            return editorStore.editableUSBButtonProfile
        }
        return 1
    }

    func applyCurrentButtonWorkspaceToLive() async {
        guard let selectedDevice = deviceStore.selectedDevice else { return }
        let slots = writableButtonSlots(for: selectedDevice)
        let persistentProfile = selectedDevice.transport == .usb && editorStore.supportsMultipleOnboardProfiles
            ? 1
            : (shouldTreatCurrentSourceAsExactMouseSlot(device: selectedDevice) ?? editorStore.activeOnboardProfile)

        for slot in slots {
            let patch = DevicePatch(
                buttonBinding: makeButtonBindingPatch(
                    slot: slot,
                    persistentProfile: persistentProfile,
                    writePersistentLayer: true,
                    writeDirectLayer: true
                )
            )
            let succeeded = await apply(
                device: selectedDevice,
                patch: patch,
                markApplyingState: true,
                shouldFocusOnActivity: true,
                shouldSurfaceApplyFailure: true,
                persistLightingZoneID: editorStore.editableUSBLightingZoneID,
                clearLocalEditsOnSuccess: false
            )
            guard succeeded else { return }
        }

        if selectedDevice.transport == .usb && editorStore.supportsMultipleOnboardProfiles {
            editorController.setLiveUSBButtonProfileOverride(1, for: selectedDevice)
        } else {
            if let exactSlot = shouldTreatCurrentSourceAsExactMouseSlot(device: selectedDevice) {
                editorController.setLiveUSBButtonProfileOverride(exactSlot, for: selectedDevice)
            } else {
                editorController.setLiveUSBButtonProfileOverride(editorStore.activeOnboardProfile, for: selectedDevice)
            }
        }
        editorController.markButtonWorkspaceAppliedToLive(
            bindings: editorStore.editableButtonBindings,
            exactSource: editorController.currentButtonProfileSource()
        )
    }

    func writeCurrentButtonWorkspaceToMouseSlot(_ targetProfile: Int) async {
        guard let selectedDevice = deviceStore.selectedDevice else { return }
        let clampedTarget = max(1, min(editorStore.visibleOnboardProfileCount, targetProfile))

        for slot in writableButtonSlots(for: selectedDevice) {
            let patch = DevicePatch(
                buttonBinding: makeButtonBindingPatch(
                    slot: slot,
                    persistentProfile: clampedTarget,
                    writePersistentLayer: true,
                    writeDirectLayer: false
                )
            )
            let succeeded = await apply(
                device: selectedDevice,
                patch: patch,
                markApplyingState: true,
                shouldFocusOnActivity: false,
                shouldSurfaceApplyFailure: true,
                persistLightingZoneID: editorStore.editableUSBLightingZoneID,
                clearLocalEditsOnSuccess: false
            )
            guard succeeded else { return }
        }

        editorController.saveCachedButtonBindings(device: selectedDevice, bindings: editorStore.editableButtonBindings, profile: clampedTarget)
    }

    func resetLiveButtonsToDeviceDefaultSlot() async {
        guard editorStore.supportsMultipleOnboardProfiles else { return }
        let defaultSlot = max(1, editorStore.activeOnboardProfile)
        editorController.selectButtonProfileSource(.mouseSlot(defaultSlot))
        await projectSelectedUSBButtonProfileToDirectLayer()
        if let selectedDevice = deviceStore.selectedDevice {
            let bindings = editorController.cachedButtonBindings(device: selectedDevice, profile: defaultSlot)
            editorController.markButtonWorkspaceAppliedToLive(bindings: bindings, exactSource: .mouseSlot(defaultSlot))
        }
    }

    func projectSelectedUSBButtonProfileToDirectLayer() async {
        guard let selectedDevice = deviceStore.selectedDevice, editorStore.supportsMultipleOnboardProfiles else { return }
        let patch = DevicePatch(
            usbButtonProfileAction: USBButtonProfileActionPatch(
                kind: .projectToDirectLayer,
                targetProfile: editorStore.editableUSBButtonProfile
            )
        )
        let succeeded = await apply(
            device: selectedDevice,
            patch: patch,
            markApplyingState: true,
            shouldFocusOnActivity: true,
            shouldSurfaceApplyFailure: true,
            persistLightingZoneID: editorStore.editableUSBLightingZoneID,
            clearLocalEditsOnSuccess: false
        )
        guard succeeded else { return }
        editorController.setLiveUSBButtonProfileOverride(editorStore.editableUSBButtonProfile, for: selectedDevice)
        let bindings = editorController.cachedButtonBindings(device: selectedDevice, profile: editorStore.editableUSBButtonProfile)
        editorController.markButtonWorkspaceAppliedToLive(bindings: bindings, exactSource: .mouseSlot(editorStore.editableUSBButtonProfile))
    }

    func duplicateSelectedUSBButtonProfile() async {
        guard deviceStore.selectedDevice != nil, editorStore.supportsMultipleOnboardProfiles else { return }
        guard let targetProfile = editorStore.duplicateTargetProfiles.first?.profile else {
            return
        }
        await duplicateSelectedUSBButtonProfile(to: targetProfile)
    }

    func duplicateSelectedUSBButtonProfile(to targetProfile: Int) async {
        guard let selectedDevice = deviceStore.selectedDevice, editorStore.supportsMultipleOnboardProfiles else { return }
        guard targetProfile != editorStore.editableUSBButtonProfile else { return }
        if editorStore.selectedUSBButtonProfileHasUnsavedChanges {
            await saveSelectedUSBButtonProfile()
            guard !editorStore.selectedUSBButtonProfileHasUnsavedChanges else { return }
        }

        let sourceProfile = editorStore.editableUSBButtonProfile
        let patch = DevicePatch(
            usbButtonProfileAction: USBButtonProfileActionPatch(
                kind: .duplicateToPersistentSlot,
                sourceProfile: sourceProfile,
                targetProfile: targetProfile
            )
        )
        let succeeded = await apply(
            device: selectedDevice,
            patch: patch,
            markApplyingState: true,
            shouldFocusOnActivity: true,
            shouldSurfaceApplyFailure: true,
            persistLightingZoneID: editorStore.editableUSBLightingZoneID,
            clearLocalEditsOnSuccess: false
        )
        guard succeeded else { return }

        let copiedBindings = editorController.cachedButtonBindings(device: selectedDevice, profile: sourceProfile)
        editorController.saveCachedButtonBindings(device: selectedDevice, bindings: copiedBindings, profile: targetProfile)
        editorController.updateUSBButtonProfile(targetProfile)
    }

    func resetSelectedUSBButtonProfile() async {
        await resetUSBButtonProfile(editorStore.editableUSBButtonProfile)
    }

    func resetUSBButtonProfile(_ targetProfile: Int) async {
        guard let selectedDevice = deviceStore.selectedDevice, editorStore.supportsMultipleOnboardProfiles else { return }
        let clampedTarget = max(1, min(editorStore.visibleOnboardProfileCount, targetProfile))
        let patch = DevicePatch(
            usbButtonProfileAction: USBButtonProfileActionPatch(
                kind: .resetPersistentSlot,
                targetProfile: clampedTarget
            )
        )
        let succeeded = await apply(
            device: selectedDevice,
            patch: patch,
            markApplyingState: true,
            shouldFocusOnActivity: true,
            shouldSurfaceApplyFailure: true,
            persistLightingZoneID: editorStore.editableUSBLightingZoneID,
            clearLocalEditsOnSuccess: false
        )
        guard succeeded else { return }

        editorController.saveCachedButtonBindings(device: selectedDevice, bindings: [:], profile: clampedTarget)
        if clampedTarget == editorStore.liveUSBButtonProfile {
            await projectSelectedUSBButtonProfileToDirectLayer()
        }
    }

    func saveSelectedUSBButtonProfile(activateAfterSave: Bool = false) async {
        guard let selectedDevice = deviceStore.selectedDevice else { return }
        let profile = editorStore.editableUSBButtonProfile
        let liveProfile = editorStore.liveUSBButtonProfile
        let writableSlots = selectedDevice.button_layout?.writableSlots ?? deviceStore.visibleButtonSlots.map(\.slot)
        let persistedBindings = editorController.cachedButtonBindings(device: selectedDevice, profile: profile)
        let slotsToSave = writableSlots.filter { slot in
            let fallback = editorController.defaultButtonBinding(for: slot, device: selectedDevice)
            let draft = editorStore.editableButtonBindings[slot] ?? fallback
            let persisted = persistedBindings[slot] ?? fallback
            return draft != persisted
        }

        if slotsToSave.isEmpty {
            if activateAfterSave && profile != liveProfile {
                await projectSelectedUSBButtonProfileToDirectLayer()
            }
            return
        }

        let shouldWriteDirectLayer = !editorStore.supportsMultipleOnboardProfiles || profile == liveProfile
        for slot in slotsToSave {
            let patch = DevicePatch(
                buttonBinding: makeButtonBindingPatch(
                    slot: slot,
                    persistentProfile: profile,
                    writeDirectLayer: shouldWriteDirectLayer
                )
            )
            let succeeded = await apply(
                device: selectedDevice,
                patch: patch,
                markApplyingState: true,
                shouldFocusOnActivity: true,
                shouldSurfaceApplyFailure: true,
                persistLightingZoneID: editorStore.editableUSBLightingZoneID,
                clearLocalEditsOnSuccess: false
            )
            guard succeeded else { return }
        }

        if activateAfterSave && profile != liveProfile {
            await projectSelectedUSBButtonProfileToDirectLayer()
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

    private func cancelScheduledApply(for key: ApplyTaskKey) {
        applyTasks[key]?.cancel()
        applyTasks.removeValue(forKey: key)
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

    func cancelPendingLocalEditsForSelectionChange() {
        for task in applyTasks.values {
            task.cancel()
        }
        applyTasks.removeAll()
        applyCoordinator.clearPending()
        hasPendingLocalEdits = false
        lastLocalEditAt = nil
        localEditDeviceIdentityKey = nil
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
            if patch.dpiStages != nil || patch.dpiStagePairs != nil || patch.activeStage != nil {
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
                editorController.cachePersistedButtonBinding(buttonBinding, device: presentationDevice, profile: buttonBinding.persistentProfile)
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
                    if patch.dpiStages != nil || patch.dpiStagePairs != nil || patch.activeStage != nil {
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
            let color = RGBColor(r: rgb.r, g: rgb.g, b: rgb.b)
            if patch.usbLightingZoneLEDIDs == nil && editorStore.visibleUSBLightingZones.count > 1 {
                persistLightingColorForAllZones(color, device: device)
            } else {
                let colorZoneID = usbLightingZoneID == "all" ? nil : usbLightingZoneID
                editorController.persistLightingColor(color, device: device, zoneID: colorZoneID)
            }
            editorController.persistLightingZoneID(usbLightingZoneID, device: device)
            editorStore.noteLightingGradientColorsChanged()
        }
        if let lightingEffect = patch.lightingEffect {
            editorController.persistLightingEffect(lightingEffect, device: device)
            let color = RGBColor(r: lightingEffect.primary.r, g: lightingEffect.primary.g, b: lightingEffect.primary.b)
            if lightingEffect.kind == .staticColor,
               patch.usbLightingZoneLEDIDs == nil,
               editorStore.visibleUSBLightingZones.count > 1 {
                persistLightingColorForAllZones(color, device: device)
            } else {
                let colorZoneID = lightingEffect.kind == .staticColor && usbLightingZoneID != "all"
                    ? usbLightingZoneID
                    : nil
                editorController.persistLightingColor(color, device: device, zoneID: colorZoneID)
            }
            editorController.persistLightingZoneID(
                lightingEffect.kind == .staticColor ? usbLightingZoneID : "all",
                device: device
            )
            if lightingEffect.kind == .staticColor {
                editorStore.noteLightingGradientColorsChanged()
            }
        }
    }

    private func persistLightingColorForAllZones(_ color: RGBColor, device: MouseDevice) {
        editorController.persistLightingColor(color, device: device)
        for zone in editorStore.visibleUSBLightingZones {
            editorController.persistLightingColor(color, device: device, zoneID: zone.id)
        }
    }
}
