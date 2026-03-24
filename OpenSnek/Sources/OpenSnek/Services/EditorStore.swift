import Foundation
import Observation
import OpenSnekAppSupport
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
    var isEditingDpiControl = false
    var usbButtonProfilesRevision = 0

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

    var liveUSBButtonProfile: Int {
        editorController.liveUSBButtonProfile()
    }

    var supportsMultipleOnboardProfiles: Bool {
        deviceStore.selectedDevice?.transport == .usb && visibleOnboardProfileCount > 1
    }

    var visibleUSBButtonProfiles: [USBButtonProfileSummary] {
        _ = usbButtonProfilesRevision
        return editorController.usbButtonProfileSummaries()
    }

    var savedButtonProfiles: [OpenSnekButtonProfile] {
        _ = usbButtonProfilesRevision
        return editorController.savedButtonProfiles()
    }

    var currentButtonProfileSource: ButtonProfileSource? {
        _ = usbButtonProfilesRevision
        return editorController.currentButtonProfileSource()
    }

    var currentButtonProfileDisplayName: String {
        _ = usbButtonProfilesRevision
        return editorController.currentButtonProfileDisplayName()
    }

    var liveButtonProfileDisplayName: String {
        _ = usbButtonProfilesRevision
        return editorController.liveButtonProfileDisplayName()
    }

    var deviceDefaultButtonProfileDisplayName: String {
        _ = usbButtonProfilesRevision
        return editorController.deviceDefaultButtonProfileDisplayName()
    }

    var currentButtonProfileHasUnsupportedBindings: Bool {
        _ = usbButtonProfilesRevision
        return editorController.currentButtonProfileHasUnsupportedBindings()
    }

    var buttonWorkspaceHasUnsavedSourceChanges: Bool {
        _ = usbButtonProfilesRevision
        guard let selectedDevice = deviceStore.selectedDevice else { return false }
        return editorController.buttonWorkspaceHasUnsavedSourceChanges(device: selectedDevice)
    }

    var buttonWorkspaceHasUnappliedLiveChanges: Bool {
        _ = usbButtonProfilesRevision
        guard let selectedDevice = deviceStore.selectedDevice else { return false }
        return editorController.buttonWorkspaceHasUnappliedLiveChanges(device: selectedDevice)
    }

    var canApplyCurrentButtonWorkspace: Bool {
        buttonWorkspaceHasUnappliedLiveChanges
    }

    var canUpdateCurrentSavedButtonProfile: Bool {
        _ = usbButtonProfilesRevision
        return editorController.canUpdateCurrentSavedButtonProfile()
    }

    var canReplaceCurrentMouseSlot: Bool {
        _ = usbButtonProfilesRevision
        return editorController.canReplaceCurrentMouseSlot()
    }

    var onThisMouseButtonSources: [ButtonProfileSource] {
        _ = usbButtonProfilesRevision
        return editorController.onThisMouseButtonSources()
    }

    var loadableMouseButtonSources: [ButtonProfileSource] {
        _ = usbButtonProfilesRevision
        return editorController.loadableMouseButtonSources()
    }

    var storedMouseButtonSources: [ButtonProfileSource] {
        _ = usbButtonProfilesRevision
        return editorController.storedMouseButtonSources()
    }

    var isEditingMouseBaseButtonProfile: Bool {
        _ = usbButtonProfilesRevision
        return editorController.isEditingMouseBaseButtonProfile()
    }

    func buttonProfileSourceDisplayName(_ source: ButtonProfileSource) -> String {
        editorController.buttonProfileSourceDisplayName(source)
    }

    func buttonProfileSourceMatchDescription(_ source: ButtonProfileSource) -> String? {
        _ = usbButtonProfilesRevision
        return editorController.buttonProfileSourceMatchDescription(source)
    }

    var canDuplicateSelectedUSBButtonProfile: Bool {
        visibleUSBButtonProfiles.contains { $0.profile != editableUSBButtonProfile }
    }

    var canResetSelectedUSBButtonProfile: Bool {
        supportsMultipleOnboardProfiles && (
            selectedUSBButtonProfileHasUnsavedChanges ||
            visibleUSBButtonProfiles.contains { $0.profile == editableUSBButtonProfile && $0.isCustomized != false }
        )
    }

    var selectedUSBButtonProfileHasUnsavedChanges: Bool {
        _ = usbButtonProfilesRevision
        return editorController.selectedUSBButtonProfileHasUnsavedChanges()
    }

    var canSaveSelectedUSBButtonProfile: Bool {
        supportsMultipleOnboardProfiles && selectedUSBButtonProfileHasUnsavedChanges
    }

    var canActivateSelectedUSBButtonProfile: Bool {
        supportsMultipleOnboardProfiles && editableUSBButtonProfile != liveUSBButtonProfile
    }

    var duplicateTargetProfiles: [USBButtonProfileSummary] {
        visibleUSBButtonProfiles.filter { $0.profile != editableUSBButtonProfile }
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
        editableStageValues[index] = DeviceProfiles.clampDPI(value, profileID: selectedDeviceProfileID)
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

    func selectButtonProfileSource(_ source: ButtonProfileSource) {
        editorController.selectButtonProfileSource(source)
    }

    func loadButtonProfileSourceIntoLive(_ source: ButtonProfileSource) async {
        await editorController.loadButtonProfileSourceIntoLive(source)
    }

    func selectNextOnboardButtonProfile() {
        editorController.selectNextOnboardButtonProfile()
    }

    func duplicateSelectedUSBButtonProfile() async {
        await applyController.duplicateSelectedUSBButtonProfile()
    }

    func duplicateSelectedUSBButtonProfile(to targetProfile: Int) async {
        await applyController.duplicateSelectedUSBButtonProfile(to: targetProfile)
    }

    func resetSelectedUSBButtonProfile() async {
        await applyController.resetSelectedUSBButtonProfile()
    }

    func projectSelectedUSBButtonProfileToDirectLayer() async {
        await applyController.projectSelectedUSBButtonProfileToDirectLayer()
    }

    func saveSelectedUSBButtonProfile(activateAfterSave: Bool = false) async {
        await applyController.saveSelectedUSBButtonProfile(activateAfterSave: activateAfterSave)
    }

    func applyCurrentButtonWorkspaceToLive() async {
        await applyController.applyCurrentButtonWorkspaceToLive()
    }

    func writeCurrentButtonWorkspaceToMouseSlot(_ slot: Int) async {
        await applyController.writeCurrentButtonWorkspaceToMouseSlot(slot)
    }

    func resetLiveButtonsToDeviceDefaultSlot() async {
        await applyController.resetLiveButtonsToDeviceDefaultSlot()
    }

    func revertButtonWorkspaceToSource() {
        editorController.revertButtonWorkspaceToSource()
    }

    @discardableResult
    func saveCurrentButtonWorkspaceAsNewProfile(name: String) -> OpenSnekButtonProfile {
        editorController.saveCurrentButtonWorkspaceAsNewProfile(name: name)
    }

    @discardableResult
    func updateCurrentOpenSnekButtonProfile() -> OpenSnekButtonProfile? {
        editorController.updateCurrentOpenSnekButtonProfile()
    }

    @discardableResult
    func renameOpenSnekButtonProfile(id: UUID, name: String) -> OpenSnekButtonProfile? {
        editorController.renameOpenSnekButtonProfile(id: id, name: name)
    }

    func deleteOpenSnekButtonProfile(id: UUID) {
        editorController.deleteOpenSnekButtonProfile(id: id)
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

    func buttonBindingHidKey(for slot: Int) -> Int {
        editorController.buttonBindingHidKey(for: slot)
    }

    func buttonBindingClutchDPI(for slot: Int) -> Int {
        editorController.buttonBindingClutchDPI(for: slot)
    }

    func updateButtonBindingKind(slot: Int, kind: ButtonBindingKind) {
        editorController.updateButtonBindingKind(slot: slot, kind: kind)
    }

    func updateButtonBindingHidKey(slot: Int, hidKey: Int) {
        editorController.updateButtonBindingHidKey(slot: slot, hidKey: hidKey)
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
}
