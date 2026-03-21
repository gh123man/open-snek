import Observation
import OpenSnekCore

@MainActor
@Observable
final class EditorStore {
    @ObservationIgnored let deviceStore: DeviceStore
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
    var editableUSBLightingZoneID: String = "all"
    var editableUSBButtonProfile = 1
    var editableLightingWaveDirection: LightingWaveDirection = .left
    var editableLightingReactiveSpeed = 2
    var editableColor = RGBColor(r: 0, g: 255, b: 0)
    var editableSecondaryColor = RGBColor(r: 0, g: 170, b: 255)
    var editableButtonBindings: [Int: ButtonBindingDraft] = [:]
    var keyboardTextDraftBySlot: [Int: String] = [:]
    var isEditingDpiControl = false

    @ObservationIgnored private weak var editorControllerStorage: AppStateEditorController?
    @ObservationIgnored private weak var applyControllerStorage: AppStateApplyController?

    init(deviceStore: DeviceStore) {
        self.deviceStore = deviceStore
    }

    func bind(
        editorController: AppStateEditorController,
        applyController: AppStateApplyController
    ) {
        self.editorControllerStorage = editorController
        self.applyControllerStorage = applyController
    }

    private var editorController: AppStateEditorController {
        guard let editorControllerStorage else {
            preconditionFailure("EditorStore accessed before editorController was bound")
        }
        return editorControllerStorage
    }

    private var applyController: AppStateApplyController {
        guard let applyControllerStorage else {
            preconditionFailure("EditorStore accessed before applyController was bound")
        }
        return applyControllerStorage
    }

    var visibleUSBLightingZones: [USBLightingZoneDescriptor] {
        guard let selectedDevice = deviceStore.selectedDevice else { return [] }
        return DeviceProfiles
            .resolve(
                vendorID: selectedDevice.vendor_id,
                productID: selectedDevice.product_id,
                transport: selectedDevice.transport
            )?
            .usbLightingZones ?? []
    }

    var visibleLightingEffects: [LightingEffectKind] {
        guard let selectedDevice = deviceStore.selectedDevice else { return [.staticColor] }
        guard let profile = DeviceProfiles.resolve(
            vendorID: selectedDevice.vendor_id,
            productID: selectedDevice.product_id,
            transport: selectedDevice.transport
        ) else {
            return selectedDevice.supports_advanced_lighting_effects ? LightingEffectKind.allCases : [.staticColor]
        }
        if selectedDevice.supports_advanced_lighting_effects {
            return profile.supportedLightingEffects
        }
        return [.staticColor]
    }

    var visibleOnboardProfileCount: Int {
        let deviceCount = deviceStore.selectedDevice?.onboard_profile_count ?? 1
        let stateCount = deviceStore.state?.onboard_profile_count ?? 1
        return max(1, max(deviceCount, stateCount))
    }

    var activeOnboardProfile: Int {
        max(1, min(visibleOnboardProfileCount, deviceStore.state?.active_onboard_profile ?? 1))
    }

    var supportsMultipleOnboardProfiles: Bool {
        deviceStore.selectedDevice?.transport == .usb && visibleOnboardProfileCount > 1
    }

    var compactActiveStageIndex: Int {
        max(0, min(max(0, editableStageCount - 1), editableActiveStage - 1))
    }

    var compactActiveStageValue: Int {
        stageValue(compactActiveStageIndex)
    }

    var selectedDeviceProfileID: DeviceProfileID? {
        deviceStore.selectedDevice?.profile_id
    }

    func updateStage(_ index: Int, value: Int) {
        guard index >= 0 && index < editableStageValues.count else { return }
        editableStageValues[index] = max(100, min(30_000, value))
    }

    func stageValue(_ index: Int) -> Int {
        guard index >= 0 && index < editableStageValues.count else { return 800 }
        return editableStageValues[index]
    }

    func scheduleAutoApplyDpi() {
        applyController.scheduleAutoApplyDpi()
    }

    func applyDpiStages() async {
        await applyController.applyDpiStages()
    }

    func scheduleAutoApplyActiveStage() {
        applyController.scheduleAutoApplyActiveStage()
    }

    func scheduleAutoApplyPollRate() {
        applyController.scheduleAutoApplyPollRate()
    }

    func applyPollRate() async {
        await applyController.applyPollRate()
    }

    func scheduleAutoApplySleepTimeout() {
        applyController.scheduleAutoApplySleepTimeout()
    }

    func scheduleAutoApplyLowBatteryThreshold() {
        applyController.scheduleAutoApplyLowBatteryThreshold()
    }

    func scheduleAutoApplyScrollMode() {
        applyController.scheduleAutoApplyScrollMode()
    }

    func scheduleAutoApplyScrollAcceleration() {
        applyController.scheduleAutoApplyScrollAcceleration()
    }

    func scheduleAutoApplyScrollSmartReel() {
        applyController.scheduleAutoApplyScrollSmartReel()
    }

    func scheduleAutoApplyLedBrightness() {
        applyController.scheduleAutoApplyLedBrightness()
    }

    func scheduleAutoApplyLedColor() {
        applyController.scheduleAutoApplyLedColor()
    }

    func scheduleAutoApplyLightingEffect() {
        applyController.scheduleAutoApplyLightingEffect()
    }

    func updateLightingEffect(_ kind: LightingEffectKind) {
        editorController.updateLightingEffect(kind)
    }

    func updateUSBLightingZoneID(_ zoneID: String) {
        editorController.updateUSBLightingZoneID(zoneID)
    }

    func updateUSBButtonProfile(_ profile: Int) {
        editorController.updateUSBButtonProfile(profile)
    }

    func updateLightingWaveDirection(_ direction: LightingWaveDirection) {
        editorController.updateLightingWaveDirection(direction)
    }

    func updateLightingReactiveSpeed(_ speed: Int) {
        editorController.updateLightingReactiveSpeed(speed)
    }

    func buttonBindingKind(for slot: Int) -> ButtonBindingKind {
        editorController.buttonBindingKind(for: slot)
    }

    func buttonBindingTurboEnabled(for slot: Int) -> Bool {
        editorController.buttonBindingTurboEnabled(for: slot)
    }

    func buttonBindingTurboRatePressesPerSecond(for slot: Int) -> Int {
        ButtonBindingSupport.turboRawToPressesPerSecond(editorController.buttonBindingTurboRate(for: slot))
    }

    func buttonBindingClutchDPI(for slot: Int) -> Int {
        editorController.buttonBindingClutchDPI(for: slot)
    }

    func updateButtonBindingKind(slot: Int, kind: ButtonBindingKind) {
        editorController.updateButtonBindingKind(slot: slot, kind: kind)
    }

    func updateButtonBindingTurboEnabled(slot: Int, enabled: Bool) {
        editorController.updateButtonBindingTurboEnabled(slot: slot, enabled: enabled)
    }

    func updateButtonBindingTurboPressesPerSecond(slot: Int, pressesPerSecond: Int) {
        let clamped = max(1, min(20, pressesPerSecond))
        editorController.updateButtonBindingTurboRate(
            slot: slot,
            rate: ButtonBindingSupport.turboPressesPerSecondToRaw(clamped)
        )
    }

    func updateButtonBindingClutchDPI(slot: Int, dpi: Int) {
        editorController.updateButtonBindingClutchDPI(slot: slot, dpi: dpi)
    }

    func keyboardTextDraft(for slot: Int) -> String {
        editorController.keyboardTextDraft(for: slot)
    }

    func updateKeyboardTextDraft(slot: Int, text: String) {
        editorController.updateKeyboardTextDraft(slot: slot, text: text)
    }
}
