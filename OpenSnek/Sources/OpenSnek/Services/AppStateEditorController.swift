import Foundation
import OpenSnekAppSupport
import OpenSnekCore

@MainActor
final class AppStateEditorController {
    private let environment: AppEnvironment
    private let deviceStore: DeviceStore
    private let editorStore: EditorStore
    private let buttonSlots: [ButtonSlotDescriptor]
    @WeakBound("AppStateEditorController", dependency: "applyController")
    private var applyController: AppStateApplyController

    private let preferenceStore = DevicePreferenceStore()
    private(set) var isHydrating = false
    private var hydratedLightingStateByDeviceID: Set<String> = []
    private var hydratedButtonBindingsKey: String?
    private var buttonBindingsCacheByHydrationKey: [String: [Int: ButtonBindingDraft]] = [:]
    private var buttonBindingsReadbackAttemptedKeys: Set<String> = []
    private var buttonBindingsReadbackInFlightKeys: Set<String> = []
    private var buttonProfileSummaryHydrationInFlightDeviceIDs: Set<String> = []
    private var buttonProfileWorkspaceSourceByDeviceID: [String: ButtonProfileSource] = [:]
    private var buttonProfileLiveSourceByDeviceID: [String: ButtonProfileSource] = [:]
    private var buttonProfileLiveBindingsByDeviceID: [String: [Int: ButtonBindingDraft]] = [:]
    private var softwareActiveUSBButtonProfileOverrideByDeviceID: [String: Int] = [:]
    private var buttonWorkspaceEditRevision: UInt64 = 0
    private var isTearingDown = false

    init(
        environment: AppEnvironment,
        deviceStore: DeviceStore,
        editorStore: EditorStore,
        buttonSlots: [ButtonSlotDescriptor]
    ) {
        self.environment = environment
        self.deviceStore = deviceStore
        self.editorStore = editorStore
        self.buttonSlots = buttonSlots
    }

    func tearDown() {
        isTearingDown = true
    }

    func bind(applyController: AppStateApplyController) {
        _applyController.bind(applyController)
    }

    private func bumpUSBButtonProfilesRevision() {
        editorStore.usbButtonProfilesRevision &+= 1
    }

    private func bumpConnectBehaviorRevision() {
        editorStore.connectBehaviorRevision &+= 1
    }

    private func normalizedButtonProfileName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Profile" : trimmed
    }

    private func forcesRestoreOpenSnekSettingsOnConnect(for device: MouseDevice) -> Bool {
        device.transport == .bluetooth && device.profile_id == .basiliskV3XHyperspeed
    }

    private func buttonProfileSource(for device: MouseDevice) -> ButtonProfileSource {
        if let source = buttonProfileWorkspaceSourceByDeviceID[device.id] {
            switch source {
            case .mouseSlot(let slot):
                return .mouseSlot(max(1, min(editorStore.visibleOnboardProfileCount, slot)))
            case .openSnekProfile(let id):
                if preferenceStore.loadOpenSnekButtonProfiles().contains(where: { $0.id == id }) {
                    return source
                }
            }
        }
        return .mouseSlot(defaultMouseButtonProfileSource(for: device))
    }

    private func defaultMouseButtonProfileSource(for device: MouseDevice) -> Int {
        if editorStore.supportsMultipleOnboardProfiles {
            return liveUSBButtonProfile(for: device)
        }
        return 1
    }

    private func setButtonProfileSource(_ source: ButtonProfileSource, for device: MouseDevice) {
        buttonProfileWorkspaceSourceByDeviceID[device.id] = source
        if case .mouseSlot(let slot) = source {
            editorStore.editableUSBButtonProfile = max(1, min(editorStore.visibleOnboardProfileCount, slot))
        }
        bumpUSBButtonProfilesRevision()
    }

    private func setLiveButtonProfileSource(
        _ source: ButtonProfileSource,
        bindings: [Int: ButtonBindingDraft],
        for device: MouseDevice
    ) {
        buttonProfileLiveSourceByDeviceID[device.id] = source
        buttonProfileLiveBindingsByDeviceID[device.id] = bindings
        bumpUSBButtonProfilesRevision()
    }

    private func currentSourceBindings(for device: MouseDevice) -> [Int: ButtonBindingDraft] {
        switch buttonProfileSource(for: device) {
        case .mouseSlot(let slot):
            return cachedButtonBindings(device: device, profile: slot)
        case .openSnekProfile(let id):
            return preferenceStore.loadOpenSnekButtonProfiles().first(where: { $0.id == id })?.bindings ?? [:]
        }
    }

    private func sourceBindings(for source: ButtonProfileSource, device: MouseDevice) -> [Int: ButtonBindingDraft] {
        switch source {
        case .mouseSlot(let slot):
            return cachedButtonBindings(device: device, profile: slot)
        case .openSnekProfile(let id):
            return preferenceStore.loadOpenSnekButtonProfiles().first(where: { $0.id == id })?.bindings ?? [:]
        }
    }

    private func liveBindings(for device: MouseDevice) -> [Int: ButtonBindingDraft] {
        buttonProfileLiveBindingsByDeviceID[device.id]
            ?? sourceBindings(for: liveButtonProfileSource(for: device), device: device)
    }

    private func bindingComparisonSlots(
        for device: MouseDevice,
        lhs: [Int: ButtonBindingDraft],
        rhs: [Int: ButtonBindingDraft]
    ) -> [Int] {
        let visibleSlots = Set((device.button_layout?.visibleSlots ?? buttonSlots).map(\.slot))
        let extraSlots = Set(lhs.keys).union(rhs.keys)
        return Array(visibleSlots.union(extraSlots)).sorted()
    }

    private func bindingsEqual(
        _ lhs: [Int: ButtonBindingDraft],
        _ rhs: [Int: ButtonBindingDraft],
        device: MouseDevice
    ) -> Bool {
        bindingComparisonSlots(for: device, lhs: lhs, rhs: rhs).allSatisfy { slot in
            let fallback = defaultButtonBinding(for: slot, device: device)
            return (lhs[slot] ?? fallback) == (rhs[slot] ?? fallback)
        }
    }

    private func shouldPreserveLocalButtonWorkspace(device: MouseDevice) -> Bool {
        let hasInitializedWorkspace = hydratedButtonBindingsKey != nil || !editorStore.editableButtonBindings.isEmpty
        guard hasInitializedWorkspace else { return false }
        guard buttonWorkspaceBelongsToDevice(device) else { return false }
        return buttonWorkspaceHasUnsavedSourceChanges(device: device)
    }

    private func buttonWorkspaceBelongsToDevice(_ device: MouseDevice) -> Bool {
        if let hydratedButtonBindingsKey,
           let hydratedDeviceID = hydratedButtonBindingsKey.split(separator: "#").first {
            return String(hydratedDeviceID) == device.id
        }
        return buttonProfileWorkspaceSourceByDeviceID[device.id] != nil
    }

    private func workspaceSourceDisplayName(_ source: ButtonProfileSource, device: MouseDevice) -> String {
        switch source {
        case .openSnekProfile(let id):
            return preferenceStore.loadOpenSnekButtonProfiles().first(where: { $0.id == id })?.name ?? "Deleted Profile"
        case .mouseSlot(let slot):
            if editorStore.supportsMultipleOnboardProfiles {
                return slot == 1 ? "Current Buttons" : "Stored Slot \(slot)"
            }
            return "This Mouse"
        }
    }

    private func matchingSavedButtonProfiles(
        for bindings: [Int: ButtonBindingDraft],
        device: MouseDevice
    ) -> [OpenSnekButtonProfile] {
        savedButtonProfiles().filter { bindingsEqual($0.bindings, bindings, device: device) }
    }

    private func savedButtonProfileMatchDescription(
        for bindings: [Int: ButtonBindingDraft],
        device: MouseDevice
    ) -> String? {
        let matches = matchingSavedButtonProfiles(for: bindings, device: device)
        guard let first = matches.first else { return nil }
        if matches.count == 1 {
            return first.name
        }
        return "\(first.name) +\(matches.count - 1)"
    }

    struct PersistedLightingRestorePlan {
        let patch: DevicePatch
        let primaryColor: RGBColor?
        let lightingEffect: LightingEffectPatch?
        let usbLightingZoneID: String
    }

    struct PersistedSettingsRestorePlan {
        let snapshot: PersistedDeviceSettingsSnapshot
        let patch: DevicePatch
        let buttonBindings: [Int: ButtonBindingDraft]
    }

    func removeHydratedState(for removedDeviceIDs: Set<String>) {
        guard !removedDeviceIDs.isEmpty else { return }
        hydratedLightingStateByDeviceID.subtract(removedDeviceIDs)
        softwareActiveUSBButtonProfileOverrideByDeviceID = softwareActiveUSBButtonProfileOverrideByDeviceID.filter { key, _ in
            !removedDeviceIDs.contains(key)
        }
        buttonProfileWorkspaceSourceByDeviceID = buttonProfileWorkspaceSourceByDeviceID.filter { key, _ in
            !removedDeviceIDs.contains(key)
        }
        buttonProfileLiveSourceByDeviceID = buttonProfileLiveSourceByDeviceID.filter { key, _ in
            !removedDeviceIDs.contains(key)
        }
        buttonProfileLiveBindingsByDeviceID = buttonProfileLiveBindingsByDeviceID.filter { key, _ in
            !removedDeviceIDs.contains(key)
        }
        buttonBindingsCacheByHydrationKey = buttonBindingsCacheByHydrationKey.filter { key, _ in
            guard let hydratedDeviceID = key.split(separator: "#").first else { return true }
            return !removedDeviceIDs.contains(String(hydratedDeviceID))
        }
        buttonBindingsReadbackAttemptedKeys = buttonBindingsReadbackAttemptedKeys.filter { key in
            guard let hydratedDeviceID = key.split(separator: "#").first else { return true }
            return !removedDeviceIDs.contains(String(hydratedDeviceID))
        }
        buttonBindingsReadbackInFlightKeys = buttonBindingsReadbackInFlightKeys.filter { key in
            guard let hydratedDeviceID = key.split(separator: "#").first else { return true }
            return !removedDeviceIDs.contains(String(hydratedDeviceID))
        }
        buttonProfileSummaryHydrationInFlightDeviceIDs.subtract(removedDeviceIDs)
        if let hydratedButtonBindingsKey,
           let hydratedDeviceID = hydratedButtonBindingsKey.split(separator: "#").first,
           removedDeviceIDs.contains(String(hydratedDeviceID)) {
            self.hydratedButtonBindingsKey = nil
        }
        bumpUSBButtonProfilesRevision()
    }

    func telemetryWarning(for state: MouseState, device: MouseDevice) -> String? {
        guard device.transport == .usb else { return nil }
        var missing: [String] = []
        if state.dpi_stages.values == nil { missing.append("DPI stages") }
        if state.poll_rate == nil { missing.append("poll rate") }
        if state.led_value == nil { missing.append("lighting") }
        guard !missing.isEmpty else { return nil }
        return "USB telemetry is incomplete (missing \(missing.joined(separator: ", "))). " +
            "Controls stay visible, but values may be stale until readback succeeds."
    }

    func connectBehavior(for device: MouseDevice) -> DeviceConnectBehavior {
        if forcesRestoreOpenSnekSettingsOnConnect(for: device) {
            return .restoreOpenSnekSettings
        }
        return preferenceStore.loadConnectBehavior(device: device) ?? .useMouseSettings
    }

    func showsConnectBehaviorCard(for device: MouseDevice) -> Bool {
        !forcesRestoreOpenSnekSettingsOnConnect(for: device)
    }

    func updateConnectBehavior(_ behavior: DeviceConnectBehavior) {
        guard let selectedDevice = deviceStore.selectedDevice else { return }
        guard !forcesRestoreOpenSnekSettingsOnConnect(for: selectedDevice) else { return }
        preferenceStore.persistConnectBehavior(behavior, device: selectedDevice)
        bumpConnectBehaviorRevision()
    }

    func shouldRestorePersistedSettingsOnConnect(for device: MouseDevice) -> Bool {
        connectBehavior(for: device) == .restoreOpenSnekSettings
    }

    func buildCurrentSettingsSnapshot(
        for device: MouseDevice,
        preservingStoredLighting: Bool = false,
        lightingZoneOverride: String? = nil
    ) -> PersistedDeviceSettingsSnapshot? {
        guard deviceStore.selectedDevice?.id == device.id else { return nil }
        let count = max(1, min(5, editorStore.editableStageCount))
        let stageValues = Array(editorStore.editableStageValues.prefix(count)).map {
            DeviceProfiles.clampDPI($0, profileID: device.profile_id)
        }
        let stagePairs = Array(editorStore.editableStagePairs.prefix(count)).map { pair in
            DpiPair(
                x: DeviceProfiles.clampDPI(pair.x, profileID: device.profile_id),
                y: DeviceProfiles.clampDPI(pair.y, profileID: device.profile_id)
            )
        }
        let storedSnapshot = preservingStoredLighting ? loadPersistedSettingsSnapshot(device: device) : nil
        let primaryLightingColor: RGBColor
        let lightingEffect: LightingEffectPatch?
        let lightingZoneID: String
        if let storedSnapshot {
            primaryLightingColor = storedSnapshot.primaryLightingColor ?? editorStore.editableColor
            lightingEffect = storedSnapshot.lightingEffect
            lightingZoneID = lightingZoneOverride ?? storedSnapshot.usbLightingZoneID
        } else {
            primaryLightingColor = editorStore.editableColor
            lightingEffect = device.supports_advanced_lighting_effects ? currentLightingEffectPatch() : nil
            lightingZoneID = lightingZoneOverride ??
                (lightingEffect?.kind == .staticColor ? editorStore.editableUSBLightingZoneID : "all")
        }
        return PersistedDeviceSettingsSnapshot(
            stageCount: count,
            stageValues: stageValues,
            stagePairs: stagePairs,
            activeStage: max(1, min(count, editorStore.editableActiveStage)),
            pollRate: editorStore.editablePollRate,
            sleepTimeout: editorStore.editableSleepTimeout,
            lowBatteryThresholdRaw: editorStore.editableLowBatteryThresholdRaw,
            scrollMode: editorStore.editableScrollMode,
            scrollAcceleration: editorStore.editableScrollAcceleration,
            scrollSmartReel: editorStore.editableScrollSmartReel,
            ledBrightness: editorStore.editableLedBrightness,
            primaryLightingColor: primaryLightingColor,
            lightingEffect: lightingEffect,
            usbLightingZoneID: lightingZoneID,
            buttonBindings: editorStore.editableButtonBindings
        )
    }

    func persistCurrentSettingsSnapshot(
        for device: MouseDevice,
        preservingStoredLighting: Bool = false,
        lightingZoneOverride: String? = nil
    ) {
        guard let snapshot = buildCurrentSettingsSnapshot(
            for: device,
            preservingStoredLighting: preservingStoredLighting,
            lightingZoneOverride: lightingZoneOverride
        ) else { return }
        persistSettingsSnapshot(snapshot, device: device)
    }

    func persistSettingsSnapshot(_ snapshot: PersistedDeviceSettingsSnapshot, device: MouseDevice) {
        preferenceStore.persistDeviceSettingsSnapshot(snapshot, device: device)
    }

    func loadPersistedSettingsSnapshot(device: MouseDevice) -> PersistedDeviceSettingsSnapshot? {
        preferenceStore.loadPersistedDeviceSettingsSnapshot(device: device)
    }

    func hydrateEditable(from state: MouseState) {
        guard !isTearingDown else { return }
        isHydrating = true
        defer { isHydrating = false }

        if let pairs = state.dpi_stages.pairs, !pairs.isEmpty {
            editorStore.editableStageCount = max(1, min(5, pairs.count))
            let profileID = deviceStore.selectedDevice?.profile_id
            for index in 0..<editorStore.editableStagePairs.count {
                if index < pairs.count {
                    editorStore.editableStagePairs[index] = DpiPair(
                        x: DeviceProfiles.clampDPI(pairs[index].x, profileID: profileID),
                        y: DeviceProfiles.clampDPI(pairs[index].y, profileID: profileID)
                    )
                }
            }
        } else if let values = state.dpi_stages.values, !values.isEmpty {
            editorStore.editableStageCount = max(1, min(5, values.count))
            let profileID = deviceStore.selectedDevice?.profile_id
            for index in 0..<editorStore.editableStageValues.count {
                if index < values.count {
                    editorStore.editableStageValues[index] = DeviceProfiles.clampDPI(values[index], profileID: profileID)
                }
            }
        } else if let dpi = state.dpi?.x {
            editorStore.editableStageCount = 1
            let clampedX = DeviceProfiles.clampDPI(dpi, profileID: deviceStore.selectedDevice?.profile_id)
            let clampedY = DeviceProfiles.clampDPI(state.dpi?.y ?? dpi, profileID: deviceStore.selectedDevice?.profile_id)
            editorStore.editableStagePairs[0] = DpiPair(x: clampedX, y: clampedY)
        }

        if let active = state.dpi_stages.active_stage {
            let maxStage = max(1, editorStore.editableStageCount)
            editorStore.editableActiveStage = max(1, min(maxStage, active + 1))
        } else {
            editorStore.editableActiveStage = 1
        }
        editorStore.normalizeExpandedXYStages()

        if let poll = state.poll_rate {
            editorStore.editablePollRate = poll
        }

        if let timeout = state.sleep_timeout {
            editorStore.editableSleepTimeout = max(60, min(900, timeout))
        }

        if let mode = state.device_mode?.mode {
            editorStore.editableDeviceMode = mode == 0x03 ? 0x03 : 0x00
        }

        if let lowBatteryRaw = state.low_battery_threshold_raw {
            editorStore.editableLowBatteryThresholdRaw = max(0x0C, min(0x3F, lowBatteryRaw))
        }

        if let scrollMode = state.scroll_mode {
            editorStore.editableScrollMode = max(0, min(1, scrollMode))
        }

        if let scrollAcceleration = state.scroll_acceleration {
            editorStore.editableScrollAcceleration = scrollAcceleration
        }

        if let scrollSmartReel = state.scroll_smart_reel {
            editorStore.editableScrollSmartReel = scrollSmartReel
        }

        if let led = state.led_value {
            editorStore.editableLedBrightness = led
        }

        syncUSBButtonProfileSelection(from: state)
    }

    func hydrateLiveDpiPresentation(from state: MouseState) {
        guard !isTearingDown else { return }
        isHydrating = true
        defer { isHydrating = false }

        if let active = state.dpi_stages.active_stage {
            let maxStage = max(1, editorStore.editableStageCount)
            editorStore.editableActiveStage = max(1, min(maxStage, active + 1))
        } else {
            editorStore.editableActiveStage = 1
        }

        if editorStore.editableStageCount == 1, let dpi = state.dpi?.x {
            let clampedX = DeviceProfiles.clampDPI(dpi, profileID: deviceStore.selectedDevice?.profile_id)
            let clampedY = DeviceProfiles.clampDPI(state.dpi?.y ?? dpi, profileID: deviceStore.selectedDevice?.profile_id)
            editorStore.editableStagePairs[0] = DpiPair(x: clampedX, y: clampedY)
        }

        editorStore.normalizeExpandedXYStages()
    }

    func hydrateLightingStateIfNeeded(device: MouseDevice) async {
        guard !isTearingDown else { return }
        guard device.showsLightingControls else {
            editorStore.editableUSBLightingZoneID = "all"
            editorStore.editableLightingEffect = .staticColor
            hydratedLightingStateByDeviceID.insert(device.id)
            return
        }

        if hydratePersistedLightingStateIfNeeded(device: device) {
            return
        }

        guard !hydratedLightingStateByDeviceID.contains(device.id) else { return }
        if device.transport == .bluetooth,
                  let rgb = try? await environment.backend.readLightingColor(device: device) {
            guard !isTearingDown else { return }
            editorStore.editableColor = RGBColor(r: rgb.r, g: rgb.g, b: rgb.b)
            persistLightingColor(editorStore.editableColor, device: device)
            editorStore.editableUSBLightingZoneID = "all"
            if !device.supports_advanced_lighting_effects {
                editorStore.editableLightingEffect = .staticColor
            }
            ensureEditableStaticLightingZoneSelection()
            AppLog.debug("AppState", "hydrated Bluetooth lighting color from device id=\(device.id) rgb=(\(rgb.r),\(rgb.g),\(rgb.b))")
        } else {
            editorStore.editableUSBLightingZoneID = "all"
            if !device.supports_advanced_lighting_effects {
                editorStore.editableLightingEffect = .staticColor
            }
            ensureEditableStaticLightingZoneSelection()
            AppLog.debug("AppState", "lighting color read unavailable for device id=\(device.id)")
        }

        hydratedLightingStateByDeviceID.insert(device.id)
    }

    @discardableResult
    func hydratePersistedLightingStateIfNeeded(device: MouseDevice) -> Bool {
        guard !isTearingDown else { return false }
        guard !hydratedLightingStateByDeviceID.contains(device.id) else { return false }
        let plan = persistedLightingPresentationPlan(device: device)
        guard let plan else { return false }

        applyPersistedLightingRestorePlanToEditor(plan)
        AppLog.debug(
            "AppState",
            "hydrated lighting restore plan from persisted cache id=\(device.id) " +
                "kind=\(plan.lightingEffect?.kind.rawValue ?? "static") zone=\(plan.usbLightingZoneID)"
        )
        hydratedLightingStateByDeviceID.insert(device.id)
        return true
    }

    @discardableResult
    func hydrateConnectPresentationIfNeeded(device: MouseDevice) -> Bool {
        guard !isTearingDown else { return false }
        guard shouldRestorePersistedSettingsOnConnect(for: device),
              let snapshot = loadPersistedSettingsSnapshot(device: device) else {
            _ = hydratePersistedLightingStateIfNeeded(device: device)
            return false
        }
        applyPersistedSettingsSnapshotToEditor(snapshot, device: device)
        return true
    }

    func applyPersistedSettingsSnapshotToEditor(_ snapshot: PersistedDeviceSettingsSnapshot, device: MouseDevice) {
        let count = max(1, min(5, snapshot.stageCount))
        editorStore.editableStageCount = count
        for index in 0..<editorStore.editableStagePairs.count {
            if index < snapshot.stagePairs.count {
                let pair = snapshot.stagePairs[index]
                editorStore.editableStagePairs[index] = DpiPair(
                    x: DeviceProfiles.clampDPI(pair.x, profileID: device.profile_id),
                    y: DeviceProfiles.clampDPI(pair.y, profileID: device.profile_id)
                )
            } else if index < snapshot.stageValues.count {
                let value = DeviceProfiles.clampDPI(snapshot.stageValues[index], profileID: device.profile_id)
                editorStore.editableStagePairs[index] = DpiPair(x: value, y: value)
            }
        }
        editorStore.editableActiveStage = max(1, min(count, snapshot.activeStage))
        editorStore.normalizeExpandedXYStages()

        if let pollRate = snapshot.pollRate {
            editorStore.editablePollRate = pollRate
        }
        if let sleepTimeout = snapshot.sleepTimeout {
            editorStore.editableSleepTimeout = max(60, min(900, sleepTimeout))
        }
        if let lowBatteryThresholdRaw = snapshot.lowBatteryThresholdRaw {
            editorStore.editableLowBatteryThresholdRaw = max(0x0C, min(0x3F, lowBatteryThresholdRaw))
        }
        if let scrollMode = snapshot.scrollMode {
            editorStore.editableScrollMode = max(0, min(1, scrollMode))
        }
        if let scrollAcceleration = snapshot.scrollAcceleration {
            editorStore.editableScrollAcceleration = scrollAcceleration
        }
        if let scrollSmartReel = snapshot.scrollSmartReel {
            editorStore.editableScrollSmartReel = scrollSmartReel
        }
        if let ledBrightness = snapshot.ledBrightness {
            editorStore.editableLedBrightness = ledBrightness
        }
        if let primaryColor = snapshot.primaryLightingColor {
            editorStore.editableColor = primaryColor
        }
        editorStore.editableUSBLightingZoneID = snapshot.usbLightingZoneID
        if let lightingEffect = snapshot.lightingEffect {
            editorStore.editableLightingEffect = lightingEffect.kind
            editorStore.editableLightingWaveDirection = lightingEffect.waveDirection
            editorStore.editableLightingReactiveSpeed = lightingEffect.reactiveSpeed
            editorStore.editableSecondaryColor = RGBColor(
                r: lightingEffect.secondary.r,
                g: lightingEffect.secondary.g,
                b: lightingEffect.secondary.b
            )
        } else {
            editorStore.editableLightingEffect = .staticColor
        }
        ensureEditableStaticLightingZoneSelection()

        editorStore.editableButtonBindings = snapshot.buttonBindings
        hydratedButtonBindingsKey = nil
        hydratedLightingStateByDeviceID.insert(device.id)
    }

    func persistLightingColor(_ color: RGBColor, device: MouseDevice, zoneID: String? = nil) {
        preferenceStore.persistLightingColor(color, device: device, zoneID: zoneID)
    }

    func loadPersistedLightingColor(device: MouseDevice, zoneID: String? = nil) -> RGBColor? {
        preferenceStore.loadPersistedLightingColor(device: device, zoneID: zoneID)
    }

    func persistLightingZoneID(_ zoneID: String, device: MouseDevice) {
        preferenceStore.persistLightingZoneID(zoneID, device: device)
    }

    func loadPersistedLightingZoneID(device: MouseDevice) -> String? {
        preferenceStore.loadPersistedLightingZoneID(device: device)
    }

    func persistLightingEffect(_ effect: LightingEffectPatch, device: MouseDevice) {
        preferenceStore.persistLightingEffect(effect, device: device)
    }

    func loadPersistedLightingEffect(device: MouseDevice) -> (
        kind: LightingEffectKind,
        waveDirection: LightingWaveDirection,
        reactiveSpeed: Int,
        secondaryColor: RGBColor
    )? {
        preferenceStore.loadPersistedLightingEffect(device: device)
    }

    func hydrateButtonBindingsIfNeeded(device: MouseDevice) async {
        guard !isTearingDown else { return }
        let source = buttonProfileSource(for: device)
        if case .openSnekProfile = source {
            let bindings = currentSourceBindings(for: device)
            if !shouldPreserveLocalButtonWorkspace(device: device),
               hydratedButtonBindingsKey == nil || !bindingsEqual(editorStore.editableButtonBindings, bindings, device: device) {
                editorStore.editableButtonBindings = bindings
            }
            if buttonProfileLiveBindingsByDeviceID[device.id] == nil {
                let defaultSlot = defaultMouseButtonProfileSource(for: device)
                setLiveButtonProfileSource(
                    .mouseSlot(defaultSlot),
                    bindings: cachedButtonBindings(device: device, profile: defaultSlot),
                    for: device
                )
            }
            return
        }

        let profile = editorStore.editableUSBButtonProfile
        let hydrationKey = buttonBindingsHydrationKey(device: device, profile: profile)
        if device.transport == .usb,
           buttonBindingsCacheByHydrationKey[hydrationKey] == nil,
           !buttonBindingsReadbackAttemptedKeys.contains(hydrationKey),
           !buttonBindingsReadbackInFlightKeys.contains(hydrationKey) {
            buttonBindingsReadbackAttemptedKeys.insert(hydrationKey)
            buttonBindingsReadbackInFlightKeys.insert(hydrationKey)
            bumpUSBButtonProfilesRevision()
            await refreshUSBButtonBindingsFromDevice(device: device, hydrationKey: hydrationKey, profile: profile)
        }
        let cached = cachedButtonBindings(device: device, profile: profile)
        if device.transport != .usb || buttonBindingsCacheByHydrationKey[hydrationKey] != nil {
            buttonBindingsCacheByHydrationKey[hydrationKey] = cached
        }
        bumpUSBButtonProfilesRevision()

        if (!shouldPreserveLocalButtonWorkspace(device: device) && hydratedButtonBindingsKey != hydrationKey) ||
            (!bindingsEqual(editorStore.editableButtonBindings, cached, device: device) && !shouldPreserveLocalButtonWorkspace(device: device)) {
            editorStore.editableButtonBindings = cached
            hydratedButtonBindingsKey = hydrationKey
        }

        if buttonProfileLiveBindingsByDeviceID[device.id] == nil,
           liveButtonProfileSource(for: device) == .mouseSlot(profile) {
            setLiveButtonProfileSource(.mouseSlot(profile), bindings: cached, for: device)
        }

        if device.transport != .usb {
            AppLog.debug(
                "AppState",
                "hydrated button bindings from persisted cache id=\(device.id) profile=\(profile) slots=\(cached.keys.sorted())"
            )
            return
        }

        guard buttonBindingsCacheByHydrationKey[hydrationKey] != nil else {
            AppLog.debug(
                "AppState",
                "usb button hydration has no device snapshot id=\(device.id) profile=\(profile)"
            )
            return
        }
    }

    func markButtonBindingsHydrated(device: MouseDevice, profile: Int) {
        let hydrationKey = buttonBindingsHydrationKey(device: device, profile: profile)
        if editorStore.editableUSBButtonProfile == profile {
            hydratedButtonBindingsKey = hydrationKey
            buttonBindingsCacheByHydrationKey[hydrationKey] = editorStore.editableButtonBindings
        }
        buttonBindingsReadbackAttemptedKeys.insert(hydrationKey)
        bumpUSBButtonProfilesRevision()
    }

    private func refreshUSBButtonBindingsFromDevice(device: MouseDevice, hydrationKey: String, profile: Int) async {
        defer {
            buttonBindingsReadbackInFlightKeys.remove(hydrationKey)
            bumpUSBButtonProfilesRevision()
        }
        guard !isTearingDown else { return }
        let workspaceEditRevisionAtStart = buttonWorkspaceEditRevision

        guard let fromDevice = await loadUSBButtonBindingsFromDevice(device: device, profile: profile) else {
            let cached = buttonBindingsCacheByHydrationKey[hydrationKey] ?? [:]
            AppLog.debug(
                "AppState",
                "usb button hydration read unavailable id=\(device.id) profile=\(profile) cachedSlots=\(cached.keys.sorted())"
            )
            return
        }

        let selectedDeviceMatches = deviceStore.selectedDevice?.id == device.id
        let isCurrentEditableProfile = selectedDeviceMatches && hydratedButtonBindingsKey == hydrationKey
        let workspaceChangedDuringReadback = buttonWorkspaceEditRevision != workspaceEditRevisionAtStart
        if isCurrentEditableProfile && workspaceChangedDuringReadback {
            AppLog.debug(
                "AppState",
                "skipped stale USB button readback id=\(device.id) profile=\(profile) dueToLocalEdits=true"
            )
            return
        }

        var hydrated = buttonBindingsCacheByHydrationKey[hydrationKey]
            ?? [:]
        hydrated.merge(fromDevice) { _, readback in readback }
        buttonBindingsCacheByHydrationKey[hydrationKey] = hydrated
        savePersistedButtonBindings(device: device, bindings: hydrated, profile: profile)

        if hydratedButtonBindingsKey == hydrationKey {
            editorStore.editableButtonBindings = hydrated
        }
        if liveButtonProfileSource(for: device) == .mouseSlot(profile) {
            setLiveButtonProfileSource(.mouseSlot(profile), bindings: hydrated, for: device)
        }

        AppLog.debug(
            "AppState",
            "hydrated button bindings from USB readback id=\(device.id) profile=\(profile) slots=\(fromDevice.keys.sorted())"
        )
    }

    private func primeUSBButtonProfileSummariesIfNeeded(device: MouseDevice) {
        guard device.transport == .usb, editorStore.supportsMultipleOnboardProfiles else { return }
        guard !buttonProfileSummaryHydrationInFlightDeviceIDs.contains(device.id) else { return }

        buttonProfileSummaryHydrationInFlightDeviceIDs.insert(device.id)
        Task { @MainActor [weak self] in
            await self?.primeUSBButtonProfileSummaries(device: device)
        }
    }

    private func primeUSBButtonProfileSummaries(device: MouseDevice) async {
        defer {
            buttonProfileSummaryHydrationInFlightDeviceIDs.remove(device.id)
            bumpUSBButtonProfilesRevision()
        }
        guard !isTearingDown else { return }

        let count = max(1, editorStore.visibleOnboardProfileCount)
        for profile in 1...count where profile != editorStore.editableUSBButtonProfile {
            let hydrationKey = buttonBindingsHydrationKey(device: device, profile: profile)
            guard !buttonBindingsReadbackAttemptedKeys.contains(hydrationKey),
                  !buttonBindingsReadbackInFlightKeys.contains(hydrationKey) else {
                continue
            }

            buttonBindingsReadbackAttemptedKeys.insert(hydrationKey)
            buttonBindingsReadbackInFlightKeys.insert(hydrationKey)
            bumpUSBButtonProfilesRevision()
            await refreshUSBButtonBindingsFromDevice(
                device: device,
                hydrationKey: hydrationKey,
                profile: profile
            )
        }
    }

    func loadUSBButtonBindingsFromDevice(device: MouseDevice, profile: Int) async -> [Int: ButtonBindingDraft]? {
        guard !isTearingDown else { return nil }
        let slots = (device.button_layout?.visibleSlots ?? buttonSlots)
            .map(\.slot)
            .filter { $0 != 6 }
        var bindings: [Int: ButtonBindingDraft] = [:]
        var readAnyBlock = false
        let persistentProfile = max(1, min(editorStore.visibleOnboardProfileCount, profile))
        let shouldReadDirect = !editorStore.supportsMultipleOnboardProfiles || persistentProfile == liveUSBButtonProfile(for: device)

        for slot in slots {
            do {
                let persistentBlock = try await environment.backend.debugUSBReadButtonBinding(
                    device: device,
                    slot: slot,
                    profile: persistentProfile
                )
                guard !isTearingDown else { return nil }
                let directBlock = shouldReadDirect
                    ? try await environment.backend.debugUSBReadButtonBinding(device: device, slot: slot, profile: 0x00)
                    : nil
                guard !isTearingDown else { return nil }
                let block = directBlock ?? persistentBlock
                if let block {
                    readAnyBlock = true
                    if let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(
                        slot: slot,
                        functionBlock: block,
                        profileID: device.profile_id
                    ) {
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

    func persistButtonBinding(_ binding: ButtonBindingPatch, device: MouseDevice, profile: Int) {
        guard device.transport != .usb else { return }
        preferenceStore.persistButtonBinding(binding, device: device, profile: profile)
    }

    func cachePersistedButtonBinding(_ binding: ButtonBindingPatch, device: MouseDevice, profile: Int) {
        let hydrationKey = buttonBindingsHydrationKey(device: device, profile: profile)
        let updatedDraft = ButtonBindingSupport.normalizedDefaultRepresentation(
            for: binding.slot,
            draft: ButtonBindingDraft(
                kind: binding.kind,
                hidKey: binding.kind == .keyboardSimple ? max(4, min(231, binding.hidKey ?? 4)) : 4,
                turboEnabled: binding.kind.supportsTurbo ? binding.turboEnabled : false,
                turboRate: max(1, min(255, binding.turboRate ?? 0x8E)),
                clutchDPI: binding.kind == .dpiClutch
                    ? DeviceProfiles.clampDPI(
                        binding.clutchDPI ?? ButtonBindingSupport.defaultBasiliskDPIClutchDPI,
                        device: device
                    )
                    : nil
            ),
            profileID: device.profile_id
        )
        var merged = buttonBindingsCacheByHydrationKey[hydrationKey]
            ?? [:]
        merged[binding.slot] = updatedDraft
        buttonBindingsCacheByHydrationKey[hydrationKey] = merged
        if editorStore.editableUSBButtonProfile == profile,
           hydratedButtonBindingsKey == hydrationKey,
           deviceStore.selectedDevice?.id == device.id {
            editorStore.editableButtonBindings[binding.slot] = updatedDraft
        }
        if liveButtonProfileSource(for: device) == .mouseSlot(profile), binding.writeDirectLayer {
            setLiveButtonProfileSource(.mouseSlot(profile), bindings: merged, for: device)
        }
        buttonBindingsReadbackAttemptedKeys.insert(hydrationKey)
        bumpUSBButtonProfilesRevision()
    }

    func savePersistedButtonBindings(device: MouseDevice, bindings: [Int: ButtonBindingDraft], profile: Int) {
        guard device.transport != .usb else { return }
        preferenceStore.savePersistedButtonBindings(device: device, bindings: bindings, profile: profile)
    }

    func saveCachedButtonBindings(device: MouseDevice, bindings: [Int: ButtonBindingDraft], profile: Int) {
        let hydrationKey = buttonBindingsHydrationKey(device: device, profile: profile)
        buttonBindingsCacheByHydrationKey[hydrationKey] = bindings
        savePersistedButtonBindings(device: device, bindings: bindings, profile: profile)
        buttonBindingsReadbackAttemptedKeys.insert(hydrationKey)
        if editorStore.editableUSBButtonProfile == profile {
            hydratedButtonBindingsKey = hydrationKey
            editorStore.editableButtonBindings = bindings
        }
        if liveButtonProfileSource(for: device) == .mouseSlot(profile) {
            setLiveButtonProfileSource(.mouseSlot(profile), bindings: bindings, for: device)
        }
        bumpUSBButtonProfilesRevision()
    }

    func loadPersistedButtonBindings(device: MouseDevice, profile: Int) -> [Int: ButtonBindingDraft] {
        guard device.transport != .usb else { return [:] }
        return preferenceStore.loadPersistedButtonBindings(device: device, profile: profile)
    }

    func cachedButtonBindings(device: MouseDevice, profile: Int) -> [Int: ButtonBindingDraft] {
        let hydrationKey = buttonBindingsHydrationKey(device: device, profile: profile)
        return buttonBindingsCacheByHydrationKey[hydrationKey]
            ?? loadPersistedButtonBindings(device: device, profile: profile)
    }

    func defaultButtonBinding(for slot: Int, device: MouseDevice) -> ButtonBindingDraft {
        ButtonBindingSupport.defaultButtonBinding(for: slot, profileID: device.profile_id)
    }

    func profileHasCustomBindings(device: MouseDevice, profile: Int) -> Bool? {
        let hydrationKey = buttonBindingsHydrationKey(device: device, profile: profile)
        let persisted = loadPersistedButtonBindings(device: device, profile: profile)
        guard let bindings = buttonBindingsCacheByHydrationKey[hydrationKey] ?? (!persisted.isEmpty ? persisted : nil) else {
            return nil
        }

        let writableSlots = device.button_layout?.writableSlots ?? buttonSlots.map(\.slot)
        return writableSlots.contains { slot in
            (bindings[slot] ?? defaultButtonBinding(for: slot, device: device)) != defaultButtonBinding(for: slot, device: device)
        }
    }

    func savedButtonProfiles() -> [OpenSnekButtonProfile] {
        preferenceStore.loadOpenSnekButtonProfiles().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func currentButtonProfileSource() -> ButtonProfileSource? {
        guard let device = deviceStore.selectedDevice else { return nil }
        return buttonProfileSource(for: device)
    }

    func liveButtonProfileSource(for device: MouseDevice) -> ButtonProfileSource {
        buttonProfileLiveSourceByDeviceID[device.id] ?? .mouseSlot(defaultMouseButtonProfileSource(for: device))
    }

    func currentButtonProfileDisplayName() -> String {
        guard let device = deviceStore.selectedDevice else { return "Current Buttons" }
        let source = buttonProfileSource(for: device)
        let sourceName = workspaceSourceDisplayName(source, device: device)
        return buttonWorkspaceHasUnsavedSourceChanges(device: device) ? "Modified from \(sourceName)" : sourceName
    }

    func liveButtonProfileDisplayName() -> String {
        guard let device = deviceStore.selectedDevice else { return "Current Buttons" }
        let source = liveButtonProfileSource(for: device)
        let sourceName = workspaceSourceDisplayName(source, device: device)
        return bindingsEqual(liveBindings(for: device), sourceBindings(for: source, device: device), device: device) ? sourceName : "Modified from \(sourceName)"
    }

    func deviceDefaultButtonProfileDisplayName() -> String {
        guard let device = deviceStore.selectedDevice else { return "Slot 1" }
        return workspaceSourceDisplayName(.mouseSlot(max(1, editorStore.activeOnboardProfile)), device: device)
    }

    func currentButtonProfileHasUnsupportedBindings() -> Bool {
        guard let device = deviceStore.selectedDevice else { return false }
        let visible = Set((device.button_layout?.visibleSlots ?? buttonSlots).map(\.slot))
        return editorStore.editableButtonBindings.keys.contains(where: { !visible.contains($0) })
    }

    func buttonWorkspaceHasUnsavedSourceChanges(device: MouseDevice) -> Bool {
        !bindingsEqual(editorStore.editableButtonBindings, currentSourceBindings(for: device), device: device)
    }

    func buttonWorkspaceHasUnappliedLiveChanges(device: MouseDevice) -> Bool {
        !bindingsEqual(editorStore.editableButtonBindings, liveBindings(for: device), device: device)
    }

    func canUpdateCurrentSavedButtonProfile() -> Bool {
        guard let device = deviceStore.selectedDevice,
              case .openSnekProfile = buttonProfileSource(for: device) else {
            return false
        }
        return buttonWorkspaceHasUnsavedSourceChanges(device: device)
    }

    func canReplaceCurrentMouseSlot() -> Bool {
        guard let device = deviceStore.selectedDevice,
              case .mouseSlot(let slot) = buttonProfileSource(for: device),
              slot > 1 else {
            return false
        }
        return buttonWorkspaceHasUnsavedSourceChanges(device: device)
    }

    func onThisMouseButtonSources() -> [ButtonProfileSource] {
        guard deviceStore.selectedDevice != nil else { return [] }
        let count = editorStore.supportsMultipleOnboardProfiles ? editorStore.visibleOnboardProfileCount : 1
        return (1...max(1, count)).map { .mouseSlot($0) }
    }

    func loadableMouseButtonSources() -> [ButtonProfileSource] {
        guard let device = deviceStore.selectedDevice else { return [] }
        return onThisMouseButtonSources().filter { source in
            guard case .mouseSlot(let slot) = source else { return false }
            if slot == 1 {
                return true
            }
            return profileHasCustomBindings(device: device, profile: slot) == true
        }
    }

    func storedMouseButtonSources() -> [ButtonProfileSource] {
        onThisMouseButtonSources().filter {
            guard case .mouseSlot(let slot) = $0 else { return false }
            return slot > 1
        }
    }

    func writableMouseButtonSources() -> [ButtonProfileSource] {
        storedMouseButtonSources()
    }

    func isEditingMouseBaseButtonProfile() -> Bool {
        guard let device = deviceStore.selectedDevice else { return false }
        return buttonProfileSource(for: device) == .mouseSlot(1)
    }

    func buttonProfileSourceDisplayName(_ source: ButtonProfileSource) -> String {
        guard let device = deviceStore.selectedDevice else {
            switch source {
            case .openSnekProfile:
                return "Saved Profile"
            case .mouseSlot(let slot):
                return slot == 1 ? "This Mouse" : "Slot \(slot)"
            }
        }
        return workspaceSourceDisplayName(source, device: device)
    }

    func buttonProfileSourceMatchDescription(_ source: ButtonProfileSource) -> String? {
        guard let device = deviceStore.selectedDevice else { return nil }
        switch source {
        case .openSnekProfile:
            return nil
        case .mouseSlot(let slot):
            return savedButtonProfileMatchDescription(
                for: cachedButtonBindings(device: device, profile: slot),
                device: device
            )
        }
    }

    func refreshButtonProfilePresentation() {
        if let device = deviceStore.selectedDevice {
            primeUSBButtonProfileSummariesIfNeeded(device: device)
        }
        bumpUSBButtonProfilesRevision()
    }

    func liveUSBButtonProfile(for device: MouseDevice) -> Int {
        let count = max(1, device.onboard_profile_count)
        let hardwareActiveProfile = max(1, min(count, editorStore.activeOnboardProfile))
        let overrideProfile = softwareActiveUSBButtonProfileOverrideByDeviceID[device.id].map { max(1, min(count, $0)) }
        if overrideProfile == hardwareActiveProfile {
            softwareActiveUSBButtonProfileOverrideByDeviceID.removeValue(forKey: device.id)
            return hardwareActiveProfile
        }
        return overrideProfile ?? hardwareActiveProfile
    }

    func liveUSBButtonProfile() -> Int {
        guard let device = deviceStore.selectedDevice else { return editorStore.activeOnboardProfile }
        return liveUSBButtonProfile(for: device)
    }

    func selectedUSBButtonProfileHasUnsavedChanges() -> Bool {
        guard let device = deviceStore.selectedDevice else { return false }
        guard editorStore.supportsMultipleOnboardProfiles else { return false }
        return usbButtonProfileHasUnsavedChanges(device: device, profile: editorStore.editableUSBButtonProfile)
    }

    func usbButtonProfileHasUnsavedChanges(device: MouseDevice, profile: Int) -> Bool {
        let writableSlots = device.button_layout?.writableSlots ?? buttonSlots.map(\.slot)
        let draftBindings: [Int: ButtonBindingDraft]
        if editorStore.editableUSBButtonProfile == profile {
            draftBindings = editorStore.editableButtonBindings
        } else {
            draftBindings = cachedButtonBindings(device: device, profile: profile)
        }
        let persistedBindings = cachedButtonBindings(device: device, profile: profile)
        return writableSlots.contains { slot in
            let fallback = defaultButtonBinding(for: slot, device: device)
            return (draftBindings[slot] ?? fallback) != (persistedBindings[slot] ?? fallback)
        }
    }

    func setLiveUSBButtonProfileOverride(_ profile: Int, for device: MouseDevice) {
        let clamped = max(1, min(editorStore.visibleOnboardProfileCount, profile))
        let hardwareActiveProfile = max(1, min(editorStore.visibleOnboardProfileCount, editorStore.activeOnboardProfile))
        if clamped == hardwareActiveProfile {
            softwareActiveUSBButtonProfileOverrideByDeviceID.removeValue(forKey: device.id)
        } else {
            softwareActiveUSBButtonProfileOverrideByDeviceID[device.id] = clamped
        }
        bumpUSBButtonProfilesRevision()
    }

    func usbButtonProfileSummaries() -> [USBButtonProfileSummary] {
        guard let device = deviceStore.selectedDevice, editorStore.supportsMultipleOnboardProfiles else { return [] }
        let count = max(1, editorStore.visibleOnboardProfileCount)
        let selectedProfile: Int? = {
            guard case .mouseSlot(let slot) = buttonProfileSource(for: device) else { return nil }
            return max(1, min(count, slot))
        }()
        let hardwareActiveProfile = max(1, min(count, editorStore.activeOnboardProfile))
        let liveActiveProfile = max(1, min(count, liveUSBButtonProfile(for: device)))

        return (1...count).map { profile in
            USBButtonProfileSummary(
                profile: profile,
                isSelected: profile == selectedProfile,
                isHardwareActive: profile == hardwareActiveProfile,
                isLiveActive: profile == liveActiveProfile,
                isCustomized: profileHasCustomBindings(device: device, profile: profile),
                hasPendingChanges: profile == selectedProfile && buttonWorkspaceHasUnsavedSourceChanges(device: device)
            )
        }
    }

    func defaultButtonBinding(for slot: Int) -> ButtonBindingDraft {
        ButtonBindingSupport.defaultButtonBinding(for: slot, profileID: deviceStore.selectedDevice?.profile_id)
    }

    func currentLightingEffectPatch() -> LightingEffectPatch {
        LightingEffectPatch(
            kind: editorStore.editableLightingEffect,
            primary: RGBPatch(r: editorStore.editableColor.r, g: editorStore.editableColor.g, b: editorStore.editableColor.b),
            secondary: RGBPatch(r: editorStore.editableSecondaryColor.r, g: editorStore.editableSecondaryColor.g, b: editorStore.editableSecondaryColor.b),
            waveDirection: editorStore.editableLightingWaveDirection,
            reactiveSpeed: editorStore.editableLightingReactiveSpeed
        )
    }

    func persistedSettingsRestorePlan(device: MouseDevice) -> PersistedSettingsRestorePlan? {
        guard shouldRestorePersistedSettingsOnConnect(for: device),
              let snapshot = loadPersistedSettingsSnapshot(device: device) else {
            return nil
        }

        let normalizedZoneID = normalizedLightingZoneID(
            for: device,
            preferredZoneID: snapshot.usbLightingZoneID
        )
        let lightingEffect: LightingEffectPatch?
        if let persistedLightingEffect = snapshot.lightingEffect {
            let supportedEffects = DeviceProfiles
                .resolve(vendorID: device.vendor_id, productID: device.product_id, transport: device.transport)?
                .supportedLightingEffects ?? LightingEffectKind.allCases
            lightingEffect = supportedEffects.contains(persistedLightingEffect.kind) ? persistedLightingEffect : nil
        } else {
            lightingEffect = nil
        }

        let patch = DevicePatch(
            pollRate: snapshot.pollRate,
            sleepTimeout: snapshot.sleepTimeout,
            lowBatteryThresholdRaw: snapshot.lowBatteryThresholdRaw,
            scrollMode: snapshot.scrollMode,
            scrollAcceleration: snapshot.scrollAcceleration,
            scrollSmartReel: snapshot.scrollSmartReel,
            dpiStages: Array(snapshot.stageValues.prefix(snapshot.stageCount)),
            dpiStagePairs: Array(snapshot.stagePairs.prefix(snapshot.stageCount)),
            activeStage: max(0, min(snapshot.stageCount - 1, snapshot.activeStage - 1)),
            ledBrightness: snapshot.ledBrightness,
            ledRGB: lightingEffect == nil
                ? snapshot.primaryLightingColor.map { RGBPatch(r: $0.r, g: $0.g, b: $0.b) }
                : nil,
            lightingEffect: lightingEffect,
            usbLightingZoneLEDIDs: {
                if let lightingEffect, lightingEffect.kind == .staticColor {
                    return usbLightingZoneLEDIDs(for: device, zoneID: normalizedZoneID)
                }
                if lightingEffect == nil {
                    return usbLightingZoneLEDIDs(for: device, zoneID: normalizedZoneID)
                }
                return nil
            }()
        )
        return PersistedSettingsRestorePlan(
            snapshot: snapshot,
            patch: patch,
            buttonBindings: snapshot.buttonBindings
        )
    }

    private func persistedLightingPresentationPlan(device: MouseDevice) -> PersistedLightingRestorePlan? {
        guard device.showsLightingControls else { return nil }

        let normalizedZoneID = normalizedLightingZoneID(
            for: device,
            preferredZoneID: loadPersistedLightingZoneID(device: device)
        )
        let persistedColor = loadPersistedLightingColor(device: device, zoneID: normalizedZoneID)

        if device.supports_advanced_lighting_effects,
           let persistedEffect = loadPersistedLightingEffect(device: device) {
            let supportedEffects = DeviceProfiles
                .resolve(vendorID: device.vendor_id, productID: device.product_id, transport: device.transport)?
                .supportedLightingEffects ?? LightingEffectKind.allCases
            let resolvedKind = supportedEffects.contains(persistedEffect.kind)
                ? persistedEffect.kind
                : (supportedEffects.first ?? .staticColor)

            let primaryPatch: RGBPatch
            if resolvedKind.usesPrimaryColor {
                guard let persistedColor else {
                    AppLog.debug(
                        "AppState",
                        "skipping persisted lighting restore missing-primary-color id=\(device.id) kind=\(resolvedKind.rawValue)"
                    )
                    return nil
                }
                primaryPatch = RGBPatch(r: persistedColor.r, g: persistedColor.g, b: persistedColor.b)
            } else if let persistedColor {
                primaryPatch = RGBPatch(r: persistedColor.r, g: persistedColor.g, b: persistedColor.b)
            } else {
                primaryPatch = RGBPatch(r: 0, g: 0, b: 0)
            }

            let effect = LightingEffectPatch(
                kind: resolvedKind,
                primary: primaryPatch,
                secondary: RGBPatch(
                    r: persistedEffect.secondaryColor.r,
                    g: persistedEffect.secondaryColor.g,
                    b: persistedEffect.secondaryColor.b
                ),
                waveDirection: persistedEffect.waveDirection,
                reactiveSpeed: persistedEffect.reactiveSpeed
            )
            return PersistedLightingRestorePlan(
                patch: DevicePatch(
                    lightingEffect: effect,
                    usbLightingZoneLEDIDs: resolvedKind == .staticColor
                        ? usbLightingZoneLEDIDs(for: device, zoneID: normalizedZoneID)
                        : nil
                ),
                primaryColor: persistedColor,
                lightingEffect: effect,
                usbLightingZoneID: resolvedKind == .staticColor ? normalizedZoneID : "all"
            )
        }

        guard let persistedColor else { return nil }
        return PersistedLightingRestorePlan(
            patch: DevicePatch(
                ledRGB: RGBPatch(r: persistedColor.r, g: persistedColor.g, b: persistedColor.b),
                usbLightingZoneLEDIDs: usbLightingZoneLEDIDs(for: device, zoneID: normalizedZoneID)
            ),
            primaryColor: persistedColor,
            lightingEffect: nil,
            usbLightingZoneID: normalizedZoneID
        )
    }

    func applyPersistedLightingRestorePlanToEditor(_ plan: PersistedLightingRestorePlan) {
        if let primaryColor = plan.primaryColor {
            editorStore.editableColor = primaryColor
        }
        editorStore.editableUSBLightingZoneID = plan.usbLightingZoneID
        if let lightingEffect = plan.lightingEffect {
            editorStore.editableLightingEffect = lightingEffect.kind
            editorStore.editableLightingWaveDirection = lightingEffect.waveDirection
            editorStore.editableLightingReactiveSpeed = lightingEffect.reactiveSpeed
            editorStore.editableSecondaryColor = RGBColor(
                r: lightingEffect.secondary.r,
                g: lightingEffect.secondary.g,
                b: lightingEffect.secondary.b
            )
        } else {
            editorStore.editableLightingEffect = .staticColor
        }
        ensureEditableStaticLightingZoneSelection()
    }

    func currentUSBLightingZoneLEDIDs() -> [UInt8]? {
        guard editorStore.editableLightingEffect == .staticColor else { return nil }
        guard editorStore.editableUSBLightingZoneID != "all" else { return nil }
        return editorStore.visibleUSBLightingZones.first(where: { $0.id == editorStore.editableUSBLightingZoneID })?.ledIDs
    }

    func lightingGradientDisplayColors() -> [RGBColor] {
        guard let selectedDevice = deviceStore.selectedDevice else {
            return [editorStore.editableColor]
        }
        guard editorStore.editableLightingEffect == .staticColor,
              editorStore.visibleUSBLightingZones.count > 1 else {
            return [editorStore.editableColor]
        }

        let selectedZoneID = normalizedLightingZoneID(
            for: selectedDevice,
            preferredZoneID: editorStore.editableUSBLightingZoneID
        )
        let globalColor = loadPersistedLightingColor(device: selectedDevice)
        return editorStore.visibleUSBLightingZones.map { zone in
            if selectedZoneID != "all", zone.id == selectedZoneID {
                return editorStore.editableColor
            }
            return loadPersistedLightingColor(device: selectedDevice, zoneID: zone.id)
                ?? globalColor
                ?? editorStore.editableColor
        }
    }

    func ensureEditableStaticLightingZoneSelection() {
        guard editorStore.editableLightingEffect == .staticColor,
              editorStore.visibleUSBLightingZones.count > 1 else { return }

        let visibleZoneIDs = Set(editorStore.visibleUSBLightingZones.map(\.id))
        let currentZoneID = editorStore.editableUSBLightingZoneID
        guard currentZoneID == "all" || !visibleZoneIDs.contains(currentZoneID) else { return }

        if let selectedDevice = deviceStore.selectedDevice {
            updateUSBLightingZoneID(defaultEditableStaticLightingZoneID(for: selectedDevice))
            return
        }

        if let firstZoneID = editorStore.visibleUSBLightingZones.first?.id {
            editorStore.editableUSBLightingZoneID = firstZoneID
        }
    }

    private func normalizedLightingZoneID(for device: MouseDevice, preferredZoneID: String?) -> String {
        guard let preferredZoneID, preferredZoneID != "all" else { return "all" }
        let profile = DeviceProfiles.resolve(vendorID: device.vendor_id, productID: device.product_id, transport: device.transport)
        return profile?.lightingZone(id: preferredZoneID) != nil ? preferredZoneID : "all"
    }

    private func usbLightingZoneLEDIDs(for device: MouseDevice, zoneID: String) -> [UInt8]? {
        guard zoneID != "all" else { return nil }
        return DeviceProfiles
            .resolve(vendorID: device.vendor_id, productID: device.product_id, transport: device.transport)?
            .lightingLEDIDs(for: zoneID)
    }

    func syncUSBButtonProfileSelection(from state: MouseState) {
        guard let selectedDevice = deviceStore.selectedDevice else { return }
        let count = max(1, max(selectedDevice.onboard_profile_count, state.onboard_profile_count ?? 1))
        let active = max(1, min(count, state.active_onboard_profile ?? 1))
        if let override = softwareActiveUSBButtonProfileOverrideByDeviceID[selectedDevice.id] {
            let clampedOverride = max(1, min(count, override))
            if clampedOverride == active {
                softwareActiveUSBButtonProfileOverrideByDeviceID.removeValue(forKey: selectedDevice.id)
            } else {
                softwareActiveUSBButtonProfileOverrideByDeviceID[selectedDevice.id] = clampedOverride
            }
        }
        let liveSlot = softwareActiveUSBButtonProfileOverrideByDeviceID[selectedDevice.id] ?? active

        if buttonProfileLiveSourceByDeviceID[selectedDevice.id] == nil {
            buttonProfileLiveSourceByDeviceID[selectedDevice.id] = .mouseSlot(liveSlot)
        } else if case .mouseSlot = buttonProfileLiveSourceByDeviceID[selectedDevice.id] {
            buttonProfileLiveSourceByDeviceID[selectedDevice.id] = .mouseSlot(liveSlot)
        }

        let source = buttonProfileSource(for: selectedDevice)
        switch source {
        case .mouseSlot(let slot):
            let clampedSlot = max(1, min(count, slot))
            buttonProfileWorkspaceSourceByDeviceID[selectedDevice.id] = .mouseSlot(clampedSlot)
            if editorStore.editableUSBButtonProfile != clampedSlot {
                editorStore.editableUSBButtonProfile = clampedSlot
                hydratedButtonBindingsKey = nil
            }
        case .openSnekProfile:
            break
        }
        bumpUSBButtonProfilesRevision()
    }

    func buttonBindingsHydrationKey(device: MouseDevice) -> String {
        buttonBindingsHydrationKey(device: device, profile: editorStore.editableUSBButtonProfile)
    }

    func buttonBindingsHydrationKey(device: MouseDevice, profile: Int) -> String {
        "\(device.id)#\(max(1, profile))"
    }

    func updateLightingEffect(_ kind: LightingEffectKind) {
        guard deviceStore.selectedDevice?.supports_advanced_lighting_effects == true else {
            editorStore.editableLightingEffect = .staticColor
            editorStore.editableUSBLightingZoneID = "all"
            ensureEditableStaticLightingZoneSelection()
            return
        }
        let supportedEffects = editorStore.visibleLightingEffects
        editorStore.editableLightingEffect = supportedEffects.contains(kind) ? kind : (supportedEffects.first ?? .staticColor)
        if kind != .staticColor {
            editorStore.editableUSBLightingZoneID = "all"
        } else {
            ensureEditableStaticLightingZoneSelection()
        }
    }

    func updateUSBLightingZoneID(_ zoneID: String) {
        let resolvedZoneID: String
        if let selectedDevice = deviceStore.selectedDevice {
            let normalizedZoneID = normalizedLightingZoneID(for: selectedDevice, preferredZoneID: zoneID)
            if editorStore.editableLightingEffect == .staticColor,
               editorStore.visibleUSBLightingZones.count > 1,
               normalizedZoneID == "all" {
                resolvedZoneID = defaultEditableStaticLightingZoneID(for: selectedDevice)
            } else {
                resolvedZoneID = normalizedLightingZoneID(for: selectedDevice, preferredZoneID: zoneID)
            }
            if editorStore.editableLightingEffect == .staticColor,
               let persistedColor = loadPersistedLightingColor(device: selectedDevice, zoneID: resolvedZoneID) {
                editorStore.editableColor = persistedColor
            }
        } else {
            resolvedZoneID = zoneID
        }
        editorStore.editableUSBLightingZoneID = resolvedZoneID
    }

    private func defaultEditableStaticLightingZoneID(for device: MouseDevice) -> String {
        let visibleZones = DeviceProfiles
            .resolve(vendorID: device.vendor_id, productID: device.product_id, transport: device.transport)?
            .usbLightingZones ?? []

        let persistedZoneID = normalizedLightingZoneID(
            for: device,
            preferredZoneID: loadPersistedLightingZoneID(device: device)
        )
        if persistedZoneID != "all", visibleZones.contains(where: { $0.id == persistedZoneID }) {
            return persistedZoneID
        }
        return visibleZones.first?.id ?? "all"
    }

    func updateUSBButtonProfile(_ profile: Int) {
        selectButtonProfileSource(.mouseSlot(profile))
    }

    func selectButtonProfileSource(_ source: ButtonProfileSource) {
        guard let selectedDevice = deviceStore.selectedDevice else { return }
        switch source {
        case .mouseSlot(let profile):
            let clamped = max(1, min(editorStore.visibleOnboardProfileCount, profile))
            setButtonProfileSource(.mouseSlot(clamped), for: selectedDevice)
            editorStore.editableUSBButtonProfile = clamped
            let hydrationKey = buttonBindingsHydrationKey(device: selectedDevice, profile: clamped)
            editorStore.editableButtonBindings = cachedButtonBindings(device: selectedDevice, profile: clamped)
            hydratedButtonBindingsKey = hydrationKey
            Task { [weak self] in
                await self?.hydrateButtonBindingsIfNeeded(device: selectedDevice)
            }
        case .openSnekProfile(let id):
            guard let profile = preferenceStore.loadOpenSnekButtonProfiles().first(where: { $0.id == id }) else { return }
            setButtonProfileSource(.openSnekProfile(id), for: selectedDevice)
            hydratedButtonBindingsKey = nil
            editorStore.editableButtonBindings = profile.bindings
        }
        bumpUSBButtonProfilesRevision()
    }

    func loadButtonProfileSourceIntoLive(_ source: ButtonProfileSource) async {
        guard let selectedDevice = deviceStore.selectedDevice else { return }

        switch source {
        case .mouseSlot(let profile):
            let clamped = max(1, min(editorStore.visibleOnboardProfileCount, profile))
            var bindings = cachedButtonBindings(device: selectedDevice, profile: clamped)
            if !hasKnownButtonBindingsSnapshot(device: selectedDevice, profile: clamped) {
                guard let fromDevice = await loadUSBButtonBindingsFromDevice(device: selectedDevice, profile: clamped) else {
                    deviceStore.errorMessage = "Could not read button profile \(clamped) from the mouse."
                    return
                }
                bindings = fromDevice
                saveCachedButtonBindings(device: selectedDevice, bindings: fromDevice, profile: clamped)
            }
            deviceStore.errorMessage = nil
            setButtonProfileSource(.mouseSlot(clamped), for: selectedDevice)
            editorStore.editableUSBButtonProfile = 1
            let hydrationKey = buttonBindingsHydrationKey(device: selectedDevice, profile: clamped)
            editorStore.editableButtonBindings = bindings
            hydratedButtonBindingsKey = hydrationKey
            bumpUSBButtonProfilesRevision()
        case .openSnekProfile(let id):
            guard let profile = preferenceStore.loadOpenSnekButtonProfiles().first(where: { $0.id == id }) else { return }
            setButtonProfileSource(.openSnekProfile(id), for: selectedDevice)
            hydratedButtonBindingsKey = nil
            editorStore.editableButtonBindings = profile.bindings
        }

        bumpUSBButtonProfilesRevision()
        await applyController.applyCurrentButtonWorkspaceToLive()
    }

    private func hasKnownButtonBindingsSnapshot(device: MouseDevice, profile: Int) -> Bool {
        let hydrationKey = buttonBindingsHydrationKey(device: device, profile: profile)
        if buttonBindingsCacheByHydrationKey[hydrationKey] != nil {
            return true
        }
        if device.transport != .usb, !loadPersistedButtonBindings(device: device, profile: profile).isEmpty {
            return true
        }
        return false
    }

    private func refreshSelectedMouseSlotFromDeviceIfNeeded(
        device: MouseDevice,
        profile: Int,
        hydrationKey: String
    ) async {
        guard buttonProfileSource(for: device) == .mouseSlot(profile) else { return }
        guard let fromDevice = await loadUSBButtonBindingsFromDevice(device: device, profile: profile) else { return }

        saveCachedButtonBindings(device: device, bindings: fromDevice, profile: profile)
        guard buttonProfileSource(for: device) == .mouseSlot(profile),
              !shouldPreserveLocalButtonWorkspace(device: device) else {
            return
        }

        editorStore.editableButtonBindings = fromDevice
        hydratedButtonBindingsKey = hydrationKey
        bumpUSBButtonProfilesRevision()
    }

    func selectNextOnboardButtonProfile() {
        guard let selectedDevice = deviceStore.selectedDevice else { return }
        let sources = onThisMouseButtonSources()
        guard sources.count > 1 else { return }

        let currentSource = buttonProfileSource(for: selectedDevice)
        let cycleSource = sources.contains(currentSource) ? currentSource : .mouseSlot(liveUSBButtonProfile(for: selectedDevice))
        let currentIndex = sources.firstIndex(of: cycleSource) ?? 0
        let nextIndex = (currentIndex + 1) % sources.count
        selectButtonProfileSource(sources[nextIndex])
    }

    func revertButtonWorkspaceToSource() {
        guard let selectedDevice = deviceStore.selectedDevice else { return }
        editorStore.editableButtonBindings = currentSourceBindings(for: selectedDevice)
        if case .mouseSlot(let profile) = buttonProfileSource(for: selectedDevice) {
            hydratedButtonBindingsKey = buttonBindingsHydrationKey(device: selectedDevice, profile: profile)
        } else {
            hydratedButtonBindingsKey = nil
        }
        bumpUSBButtonProfilesRevision()
    }

    @discardableResult
    func saveCurrentButtonWorkspaceAsNewProfile(name: String) -> OpenSnekButtonProfile {
        let saved = preferenceStore.saveOpenSnekButtonProfile(
            name: normalizedButtonProfileName(name),
            bindings: editorStore.editableButtonBindings
        )
        bumpUSBButtonProfilesRevision()
        return saved
    }

    @discardableResult
    func updateCurrentOpenSnekButtonProfile() -> OpenSnekButtonProfile? {
        guard let selectedDevice = deviceStore.selectedDevice,
              case .openSnekProfile(let id) = buttonProfileSource(for: selectedDevice) else {
            return nil
        }
        let updated = preferenceStore.updateOpenSnekButtonProfile(id: id, bindings: editorStore.editableButtonBindings)
        bumpUSBButtonProfilesRevision()
        return updated
    }

    @discardableResult
    func updateOpenSnekButtonProfile(id: UUID, bindings: [Int: ButtonBindingDraft]) -> OpenSnekButtonProfile? {
        let updated = preferenceStore.updateOpenSnekButtonProfile(id: id, bindings: bindings)
        bumpUSBButtonProfilesRevision()
        return updated
    }

    @discardableResult
    func renameOpenSnekButtonProfile(id: UUID, name: String) -> OpenSnekButtonProfile? {
        let updated = preferenceStore.updateOpenSnekButtonProfile(id: id, name: normalizedButtonProfileName(name))
        bumpUSBButtonProfilesRevision()
        return updated
    }

    func deleteOpenSnekButtonProfile(id: UUID) {
        preferenceStore.deleteOpenSnekButtonProfile(id: id)
        if let selectedDevice = deviceStore.selectedDevice,
           buttonProfileSource(for: selectedDevice) == .openSnekProfile(id) {
            buttonProfileWorkspaceSourceByDeviceID[selectedDevice.id] = .mouseSlot(liveUSBButtonProfile(for: selectedDevice))
        }
        bumpUSBButtonProfilesRevision()
    }

    func markButtonWorkspaceAppliedToLive(bindings: [Int: ButtonBindingDraft], exactSource: ButtonProfileSource?) {
        guard let selectedDevice = deviceStore.selectedDevice else { return }
        if let exactSource {
            setLiveButtonProfileSource(exactSource, bindings: bindings, for: selectedDevice)
        } else if let currentSource = currentButtonProfileSource() {
            setLiveButtonProfileSource(currentSource, bindings: bindings, for: selectedDevice)
        } else {
            setLiveButtonProfileSource(.mouseSlot(defaultMouseButtonProfileSource(for: selectedDevice)), bindings: bindings, for: selectedDevice)
        }
    }

    func updateLightingWaveDirection(_ direction: LightingWaveDirection) {
        editorStore.editableLightingWaveDirection = direction
    }

    func updateLightingReactiveSpeed(_ speed: Int) {
        editorStore.editableLightingReactiveSpeed = max(1, min(4, speed))
    }

    func buttonBindingKind(for slot: Int) -> ButtonBindingKind {
        editorStore.editableButtonBindings[slot]?.kind ?? defaultButtonBinding(for: slot).kind
    }

    func buttonBindingHidKey(for slot: Int) -> Int {
        editorStore.editableButtonBindings[slot]?.hidKey ?? defaultButtonBinding(for: slot).hidKey
    }

    func buttonBindingTurboEnabled(for slot: Int) -> Bool {
        editorStore.editableButtonBindings[slot]?.turboEnabled ?? defaultButtonBinding(for: slot).turboEnabled
    }

    func buttonBindingTurboRate(for slot: Int) -> Int {
        editorStore.editableButtonBindings[slot]?.turboRate ?? defaultButtonBinding(for: slot).turboRate
    }

    func buttonBindingClutchDPI(for slot: Int) -> Int {
        editorStore.editableButtonBindings[slot]?.clutchDPI
            ?? ButtonBindingSupport.defaultDPIClutchDPI(for: deviceStore.selectedDevice?.profile_id)
            ?? 400
    }

    private func shouldAutoApplyCurrentButtonWorkspaceAfterEdit() -> Bool {
        deviceStore.selectedDevice != nil
    }

    private func handleButtonWorkspaceDidChange(slot: Int) {
        buttonWorkspaceEditRevision &+= 1
        bumpUSBButtonProfilesRevision()
        guard shouldAutoApplyCurrentButtonWorkspaceAfterEdit() else { return }
        applyController.scheduleAutoApplyButton(slot: slot)
    }

    func updateButtonBindingKind(slot: Int, kind: ButtonBindingKind) {
        guard deviceStore.visibleButtonSlots.contains(where: { $0.slot == slot }) else { return }
        var next = editorStore.editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        next.kind = kind
        if kind != .keyboardSimple {
            next.hidKey = 4
        }
        if kind == .dpiClutch {
            next.clutchDPI = next.clutchDPI ?? ButtonBindingSupport.defaultDPIClutchDPI(for: deviceStore.selectedDevice?.profile_id)
        }
        if !kind.supportsTurbo {
            next.turboEnabled = false
        }
        editorStore.editableButtonBindings[slot] = next
        handleButtonWorkspaceDidChange(slot: slot)
    }

    func updateButtonBindingHidKey(slot: Int, hidKey: Int) {
        guard deviceStore.visibleButtonSlots.contains(where: { $0.slot == slot }) else { return }
        var next = editorStore.editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        next.kind = .keyboardSimple
        next.hidKey = max(4, min(231, hidKey))
        editorStore.editableButtonBindings[slot] = next
        handleButtonWorkspaceDidChange(slot: slot)
    }

    func updateButtonBindingTurboEnabled(slot: Int, enabled: Bool) {
        guard deviceStore.visibleButtonSlots.contains(where: { $0.slot == slot }) else { return }
        var next = editorStore.editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        guard next.kind.supportsTurbo else { return }
        next.turboEnabled = enabled
        editorStore.editableButtonBindings[slot] = next
        handleButtonWorkspaceDidChange(slot: slot)
    }

    func updateButtonBindingTurboRate(slot: Int, rate: Int) {
        guard deviceStore.visibleButtonSlots.contains(where: { $0.slot == slot }) else { return }
        var next = editorStore.editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        guard next.kind.supportsTurbo else { return }
        next.turboRate = max(1, min(255, rate))
        editorStore.editableButtonBindings[slot] = next
        handleButtonWorkspaceDidChange(slot: slot)
    }

    func updateButtonBindingClutchDPI(slot: Int, dpi: Int) {
        guard deviceStore.visibleButtonSlots.contains(where: { $0.slot == slot }) else { return }
        var next = editorStore.editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        guard next.kind == .dpiClutch else { return }
        next.clutchDPI = DeviceProfiles.clampDPI(dpi, profileID: deviceStore.selectedDevice?.profile_id)
        editorStore.editableButtonBindings[slot] = next
        handleButtonWorkspaceDidChange(slot: slot)
    }
}
