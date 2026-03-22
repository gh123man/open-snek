import Foundation
import OpenSnekAppSupport
import OpenSnekCore

@MainActor
final class AppStateEditorController {
    private let environment: AppEnvironment
    private let deviceStore: DeviceStore
    private let editorStore: EditorStore
    private let buttonSlots: [ButtonSlotDescriptor]
    private weak var applyControllerStorage: AppStateApplyController?

    private let preferenceStore = DevicePreferenceStore()
    private(set) var isHydrating = false
    private var hydratedLightingStateByDeviceID: Set<String> = []
    private var hydratedButtonBindingsKey: String?
    private var manualUSBButtonProfileSelectionByDeviceID: Set<String> = []
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
        self.applyControllerStorage = applyController
    }

    private var applyController: AppStateApplyController {
        guard let applyControllerStorage else {
            preconditionFailure("AppStateEditorController accessed before applyController was bound")
        }
        return applyControllerStorage
    }

    struct PersistedLightingRestorePlan {
        let patch: DevicePatch
        let primaryColor: RGBColor?
        let lightingEffect: LightingEffectPatch?
        let usbLightingZoneID: String
    }

    func removeHydratedState(for removedDeviceIDs: Set<String>) {
        guard !removedDeviceIDs.isEmpty else { return }
        hydratedLightingStateByDeviceID.subtract(removedDeviceIDs)
        manualUSBButtonProfileSelectionByDeviceID.subtract(removedDeviceIDs)
        if let hydratedButtonBindingsKey,
           let hydratedDeviceID = hydratedButtonBindingsKey.split(separator: "#").first,
           removedDeviceIDs.contains(String(hydratedDeviceID)) {
            self.hydratedButtonBindingsKey = nil
        }
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

    func hydrateEditable(from state: MouseState) {
        guard !isTearingDown else { return }
        isHydrating = true
        defer { isHydrating = false }

        if let values = state.dpi_stages.values, !values.isEmpty {
            editorStore.editableStageCount = max(1, min(5, values.count))
            let profileID = deviceStore.selectedDevice?.profile_id
            for index in 0..<editorStore.editableStageValues.count {
                if index < values.count {
                    editorStore.editableStageValues[index] = DeviceProfiles.clampDPI(values[index], profileID: profileID)
                }
            }
        } else if let dpi = state.dpi?.x {
            editorStore.editableStageCount = 1
            editorStore.editableStageValues[0] = DeviceProfiles.clampDPI(dpi, profileID: deviceStore.selectedDevice?.profile_id)
        }

        if let active = state.dpi_stages.active_stage {
            let maxStage = max(1, editorStore.editableStageCount)
            editorStore.editableActiveStage = max(1, min(maxStage, active + 1))
        } else {
            editorStore.editableActiveStage = 1
        }

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
            AppLog.debug("AppState", "hydrated Bluetooth lighting color from device id=\(device.id) rgb=(\(rgb.r),\(rgb.g),\(rgb.b))")
        } else {
            editorStore.editableUSBLightingZoneID = "all"
            if !device.supports_advanced_lighting_effects {
                editorStore.editableLightingEffect = .staticColor
            }
            AppLog.debug("AppState", "lighting color read unavailable for device id=\(device.id)")
        }

        hydratedLightingStateByDeviceID.insert(device.id)
    }

    @discardableResult
    func hydratePersistedLightingStateIfNeeded(device: MouseDevice) -> Bool {
        guard !isTearingDown else { return false }
        guard !hydratedLightingStateByDeviceID.contains(device.id) else { return false }
        guard let plan = persistedLightingRestorePlan(device: device) else { return false }

        applyPersistedLightingRestorePlanToEditor(plan)
        AppLog.debug(
            "AppState",
            "hydrated lighting restore plan from persisted cache id=\(device.id) " +
                "kind=\(plan.lightingEffect?.kind.rawValue ?? "static") zone=\(plan.usbLightingZoneID)"
        )
        hydratedLightingStateByDeviceID.insert(device.id)
        return true
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
        let hydrationKey = buttonBindingsHydrationKey(device: device)
        guard hydratedButtonBindingsKey != hydrationKey else { return }

        var hydrated = loadPersistedButtonBindings(device: device, profile: editorStore.editableUSBButtonProfile)
        if device.transport == .usb, let fromDevice = await loadUSBButtonBindingsFromDevice(device: device) {
            hydrated.merge(fromDevice) { _, readback in readback }
            savePersistedButtonBindings(device: device, bindings: hydrated, profile: editorStore.editableUSBButtonProfile)
            AppLog.debug(
                "AppState",
                "hydrated button bindings from USB readback id=\(device.id) profile=\(editorStore.editableUSBButtonProfile) slots=\(fromDevice.keys.sorted())"
            )
        } else {
            AppLog.debug(
                "AppState",
                "hydrated button bindings from persisted cache id=\(device.id) profile=\(editorStore.editableUSBButtonProfile) slots=\(hydrated.keys.sorted())"
            )
        }

        editorStore.editableButtonBindings = hydrated
        hydratedButtonBindingsKey = hydrationKey
    }

    func markButtonBindingsHydrated(device: MouseDevice) {
        hydratedButtonBindingsKey = buttonBindingsHydrationKey(device: device)
    }

    func loadUSBButtonBindingsFromDevice(device: MouseDevice) async -> [Int: ButtonBindingDraft]? {
        guard !isTearingDown else { return nil }
        let slots = (device.button_layout?.visibleSlots ?? buttonSlots)
            .map(\.slot)
            .filter { $0 != 6 }
        var bindings: [Int: ButtonBindingDraft] = [:]
        var readAnyBlock = false
        let persistentProfile = max(1, min(editorStore.visibleOnboardProfileCount, editorStore.editableUSBButtonProfile))
        let shouldReadDirect = !editorStore.supportsMultipleOnboardProfiles || persistentProfile == editorStore.activeOnboardProfile

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
        preferenceStore.persistButtonBinding(binding, device: device, profile: profile)
    }

    func savePersistedButtonBindings(device: MouseDevice, bindings: [Int: ButtonBindingDraft], profile: Int) {
        preferenceStore.savePersistedButtonBindings(device: device, bindings: bindings, profile: profile)
    }

    func loadPersistedButtonBindings(device: MouseDevice, profile: Int) -> [Int: ButtonBindingDraft] {
        preferenceStore.loadPersistedButtonBindings(device: device, profile: profile)
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

    func persistedLightingRestorePlan(device: MouseDevice) -> PersistedLightingRestorePlan? {
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
    }

    func currentUSBLightingZoneLEDIDs() -> [UInt8]? {
        guard editorStore.editableLightingEffect == .staticColor else { return nil }
        guard editorStore.editableUSBLightingZoneID != "all" else { return nil }
        return editorStore.visibleUSBLightingZones.first(where: { $0.id == editorStore.editableUSBLightingZoneID })?.ledIDs
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
        let selected: Int
        if manualUSBButtonProfileSelectionByDeviceID.contains(selectedDevice.id) {
            selected = max(1, min(count, editorStore.editableUSBButtonProfile))
        } else {
            selected = active
        }
        if editorStore.editableUSBButtonProfile != selected {
            editorStore.editableUSBButtonProfile = selected
            hydratedButtonBindingsKey = nil
        }
    }

    func buttonBindingsHydrationKey(device: MouseDevice) -> String {
        "\(device.id)#\(editorStore.editableUSBButtonProfile)"
    }

    func updateLightingEffect(_ kind: LightingEffectKind) {
        guard deviceStore.selectedDevice?.supports_advanced_lighting_effects == true else {
            editorStore.editableLightingEffect = .staticColor
            editorStore.editableUSBLightingZoneID = "all"
            return
        }
        let supportedEffects = editorStore.visibleLightingEffects
        editorStore.editableLightingEffect = supportedEffects.contains(kind) ? kind : (supportedEffects.first ?? .staticColor)
        if kind != .staticColor {
            editorStore.editableUSBLightingZoneID = "all"
        }
    }

    func updateUSBLightingZoneID(_ zoneID: String) {
        let resolvedZoneID: String
        if let selectedDevice = deviceStore.selectedDevice {
            resolvedZoneID = normalizedLightingZoneID(for: selectedDevice, preferredZoneID: zoneID)
            if editorStore.editableLightingEffect == .staticColor,
               let persistedColor = loadPersistedLightingColor(device: selectedDevice, zoneID: resolvedZoneID) {
                editorStore.editableColor = persistedColor
            }
        } else {
            resolvedZoneID = zoneID
        }
        editorStore.editableUSBLightingZoneID = resolvedZoneID
    }

    func updateUSBButtonProfile(_ profile: Int) {
        guard let selectedDevice = deviceStore.selectedDevice, editorStore.supportsMultipleOnboardProfiles else { return }
        let clamped = max(1, min(editorStore.visibleOnboardProfileCount, profile))
        editorStore.editableUSBButtonProfile = clamped
        manualUSBButtonProfileSelectionByDeviceID.insert(selectedDevice.id)
        hydratedButtonBindingsKey = nil
        Task { [weak self] in
            await self?.hydrateButtonBindingsIfNeeded(device: selectedDevice)
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
        applyController.scheduleAutoApplyButton(slot: slot)
    }

    func updateButtonBindingHidKey(slot: Int, hidKey: Int) {
        guard deviceStore.visibleButtonSlots.contains(where: { $0.slot == slot }) else { return }
        var next = editorStore.editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        next.kind = .keyboardSimple
        next.hidKey = max(4, min(231, hidKey))
        editorStore.editableButtonBindings[slot] = next
        applyController.scheduleAutoApplyButton(slot: slot)
    }

    func updateButtonBindingTurboEnabled(slot: Int, enabled: Bool) {
        guard deviceStore.visibleButtonSlots.contains(where: { $0.slot == slot }) else { return }
        var next = editorStore.editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        guard next.kind.supportsTurbo else { return }
        next.turboEnabled = enabled
        editorStore.editableButtonBindings[slot] = next
        applyController.scheduleAutoApplyButton(slot: slot)
    }

    func updateButtonBindingTurboRate(slot: Int, rate: Int) {
        guard deviceStore.visibleButtonSlots.contains(where: { $0.slot == slot }) else { return }
        var next = editorStore.editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        guard next.kind.supportsTurbo else { return }
        next.turboRate = max(1, min(255, rate))
        editorStore.editableButtonBindings[slot] = next
        applyController.scheduleAutoApplyButton(slot: slot)
    }

    func updateButtonBindingClutchDPI(slot: Int, dpi: Int) {
        guard deviceStore.visibleButtonSlots.contains(where: { $0.slot == slot }) else { return }
        var next = editorStore.editableButtonBindings[slot] ?? defaultButtonBinding(for: slot)
        guard next.kind == .dpiClutch else { return }
        next.clutchDPI = DeviceProfiles.clampDPI(dpi, profileID: deviceStore.selectedDevice?.profile_id)
        editorStore.editableButtonBindings[slot] = next
        applyController.scheduleAutoApplyButton(slot: slot)
    }
}
