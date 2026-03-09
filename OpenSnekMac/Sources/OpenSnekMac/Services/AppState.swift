import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var devices: [MouseDevice] = []
    var selectedDeviceID: String?
    var state: MouseState?

    var isLoading = false
    var isApplying = false
    var isRefreshingState = false
    var errorMessage: String?
    var lastUpdated: Date?

    var editableStageValues: [Int] = [800, 1600, 3200, 6400, 12000]
    var editableStageCount = 3
    var editableActiveStage = 1
    var editablePollRate = 1000
    var editableSleepTimeout = 300
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
    private var isHydrating = false
    private var dpiApplyTask: Task<Void, Never>?
    private var pollApplyTask: Task<Void, Never>?
    private var powerApplyTask: Task<Void, Never>?
    private var ledApplyTask: Task<Void, Never>?
    private var colorApplyTask: Task<Void, Never>?
    private var lightingEffectApplyTask: Task<Void, Never>?
    private var buttonApplyTask: Task<Void, Never>?
    private var activeStageApplyTask: Task<Void, Never>?
    private var hasPendingLocalEdits = false
    private var pendingPatch: DevicePatch?
    private var applyDrainTask: Task<Void, Never>?
    private var stateCacheByDeviceID: [String: MouseState] = [:]
    private var isRefreshingDpiFast = false
    private var suppressFastDpiUntil: Date?
    private var stateRevision: UInt64 = 0
    var isEditingDpiControl = false
    private var lastLocalEditAt: Date?
    private var hydratedLightingStateByDeviceID: Set<String> = []
    private var hydratedButtonBindingsDeviceID: String?
    private var keyboardDraftApplyTaskBySlot: [Int: Task<Void, Never>] = [:]
    private var knownDeviceIDs: Set<String> = []

    var selectedDevice: MouseDevice? {
        guard let selectedDeviceID else { return nil }
        return devices.first(where: { $0.id == selectedDeviceID })
    }

    var visibleButtonSlots: [ButtonSlotDescriptor] {
        guard let selectedDevice else { return buttonSlots }
        if selectedDevice.transport == "bluetooth" {
            // Capture-backed BLE bind slots shown in the UI.
            // Slot 6 (Hypershift/Boss key) returns vendor error status and is hidden.
            let visible: Set<Int> = [1, 2, 3, 4, 5, 9, 10, 96]
            return buttonSlots.filter { visible.contains($0.slot) }
        }
        // Hide slot 6 in the UI pending a validated write path.
        return buttonSlots.filter { $0.slot != 96 && $0.slot != 6 }
    }

    func isButtonSlotEditable(_ slot: Int) -> Bool {
        guard let selectedDevice, selectedDevice.transport == "bluetooth" else { return true }
        let writable: Set<Int> = [1, 2, 3, 4, 5, 9, 10, 96]
        return writable.contains(slot)
    }

    func buttonSlotNotice(_ slot: Int) -> String? {
        guard !isButtonSlotEditable(slot) else { return nil }
        return "Not writable over current Bluetooth vendor protocol"
    }

    func refreshDevices() async {
        let start = Date()
        AppLog.event("AppState", "refreshDevices start")
        isLoading = true
        defer { isLoading = false }

        do {
            let listed = try await client.listDevices()
            devices = listed
            let currentIDs = Set(listed.map(\.id))
            let removedIDs = knownDeviceIDs.subtracting(currentIDs)
            if !removedIDs.isEmpty {
                hydratedLightingStateByDeviceID.subtract(removedIDs)
                if let hydratedButtonBindingsDeviceID, removedIDs.contains(hydratedButtonBindingsDeviceID) {
                    self.hydratedButtonBindingsDeviceID = nil
                }
            }
            knownDeviceIDs = currentIDs
            AppLog.event("AppState", "refreshDevices found=\(listed.count)")
            if selectedDeviceID == nil {
                selectedDeviceID = listed.first?.id
            }
            if let selected = selectedDevice, !listed.contains(selected) {
                selectedDeviceID = listed.first?.id
            }
            if let selectedDeviceID, let cached = stateCacheByDeviceID[selectedDeviceID] {
                state = cached
            }
            errorMessage = nil
        } catch {
            AppLog.error("AppState", "refreshDevices failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        await refreshState()
        AppLog.event("AppState", "refreshDevices end elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
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
        let refreshRevision = stateRevision

        let start = Date()
        do {
            let fetched = try await client.readState(device: selectedDevice)
            guard refreshRevision == stateRevision else {
                AppLog.debug("AppState", "refreshState stale-drop rev=\(refreshRevision) current=\(stateRevision)")
                return
            }
            let merged = fetched.merged(with: stateCacheByDeviceID[selectedDevice.id])
            stateCacheByDeviceID[selectedDevice.id] = merged
            if state != merged {
                state = merged
            }
            lastUpdated = Date()
            if shouldHydrateEditable {
                hydrateEditable(from: merged)
                await hydrateLightingStateIfNeeded(device: selectedDevice)
                hydrateButtonBindingsIfNeeded(device: selectedDevice)
            }
            errorMessage = nil
            AppLog.debug(
                "AppState",
                "refreshState ok device=\(selectedDevice.id) active=\(merged.dpi_stages.active_stage.map(String.init) ?? "nil") " +
                "values=\(merged.dpi_stages.values?.map(String.init).joined(separator: ",") ?? "nil") " +
                "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s"
            )
        } catch {
            if stateCacheByDeviceID[selectedDevice.id] == nil {
                AppLog.error("AppState", "refreshState failed no-cache: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            } else {
                // Keep last known-good UI stable on transient polling failures.
                AppLog.debug("AppState", "refreshState transient-failure masked: \(error.localizedDescription)")
                errorMessage = nil
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
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyDpiStages()
        }
    }

    func applyActiveStageOnly() async {
        let count = max(1, min(5, editableStageCount))
        let active = max(0, min(count - 1, editableActiveStage - 1))
        enqueueApply(DevicePatch(activeStage: active))
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
        editableLightingEffect = .staticColor
        enqueueApply(DevicePatch(ledRGB: RGBPatch(r: editableColor.r, g: editableColor.g, b: editableColor.b)))
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
        editableLightingEffect = .staticColor
        _ = kind
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
        guard let selectedDevice, selectedDevice.transport == "bluetooth" else { return }
        guard !isRefreshingDpiFast, !isRefreshingState, !isApplying else { return }
        guard !hasPendingLocalEdits else { return }
        if let until = suppressFastDpiUntil {
            if Date() < until { return }
            suppressFastDpiUntil = nil
        }

        isRefreshingDpiFast = true
        defer { isRefreshingDpiFast = false }
        let fastRevision = stateRevision

        do {
            guard let fast = try await client.readDpiStagesFast(device: selectedDevice) else { return }
            guard fastRevision == stateRevision else {
                AppLog.debug("AppState", "refreshDpiFast stale-drop rev=\(fastRevision) current=\(stateRevision)")
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
        if let pendingPatch {
            self.pendingPatch = pendingPatch.merged(with: patch)
        } else {
            pendingPatch = patch
        }
        hasPendingLocalEdits = true
        lastLocalEditAt = Date()
        stateRevision &+= 1

        if applyDrainTask == nil {
            applyDrainTask = Task { [weak self] in
                await self?.drainApplyQueue()
            }
        }
    }

    private func drainApplyQueue() async {
        while let patch = pendingPatch {
            pendingPatch = nil
            await applyNow(patch: patch)
            hasPendingLocalEdits = pendingPatch != nil
        }
        hasPendingLocalEdits = false
        applyDrainTask = nil
    }

    private func applyNow(patch: DevicePatch) async {
        guard let selectedDevice else {
            errorMessage = "No device selected"
            return
        }

        stateRevision &+= 1
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
            if patch.dpiStages != nil || patch.activeStage != nil {
                // Avoid showing transient in-flight stage states from fast polling
                // while BLE latching settles after a write.
                suppressFastDpiUntil = Date().addingTimeInterval(0.9)
            }
            lastUpdated = Date()
            lastLocalEditAt = nil
            hydrateEditable(from: merged)
            if patch.ledRGB != nil {
                persistLightingColor(editableColor, device: selectedDevice)
                hydratedLightingStateByDeviceID.insert(selectedDevice.id)
            }
            if let lightingEffect = patch.lightingEffect {
                persistLightingEffect(lightingEffect, device: selectedDevice)
                hydratedLightingStateByDeviceID.insert(selectedDevice.id)
            }
            if let buttonBinding = patch.buttonBinding {
                persistButtonBinding(buttonBinding, device: selectedDevice)
                hydratedButtonBindingsDeviceID = selectedDevice.id
            }
            errorMessage = nil
            AppLog.event(
                "AppState",
                "apply ok device=\(selectedDevice.id) active=\(merged.dpi_stages.active_stage.map(String.init) ?? "nil") " +
                "values=\(merged.dpi_stages.values?.map(String.init).joined(separator: ",") ?? "nil") " +
                "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s"
            )
        } catch {
            AppLog.error("AppState", "apply failed device=\(selectedDevice.id): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private var shouldHydrateEditable: Bool {
        guard !isApplying, !isEditingDpiControl, !hasPendingLocalEdits else { return false }
        guard let lastLocalEditAt else { return true }
        return Date().timeIntervalSince(lastLocalEditAt) > 0.8
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
        }

        if let active = state.dpi_stages.active_stage {
            let maxStage = max(1, editableStageCount)
            editableActiveStage = max(1, min(maxStage, active + 1))
        }

        if let poll = state.poll_rate {
            editablePollRate = poll
        }

        if let timeout = state.sleep_timeout {
            editableSleepTimeout = max(60, min(900, timeout))
        }

        if let led = state.led_value {
            editableLedBrightness = led
        }
    }

    private func hydrateLightingStateIfNeeded(device: MouseDevice) async {
        guard !hydratedLightingStateByDeviceID.contains(device.id) else { return }
        var loadedPersistedColor = false

        if device.transport == "bluetooth",
           let rgb = try? await client.readLightingColor(device: device) {
            editableColor = RGBColor(r: rgb.r, g: rgb.g, b: rgb.b)
            persistLightingColor(editableColor, device: device)
            AppLog.debug("AppState", "hydrated lighting color from device id=\(device.id) rgb=(\(rgb.r),\(rgb.g),\(rgb.b))")
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

        if loadedPersistedColor {
            enqueueApply(DevicePatch(ledRGB: RGBPatch(r: editableColor.r, g: editableColor.g, b: editableColor.b)))
            AppLog.debug("AppState", "queued persisted lighting color reapply id=\(device.id)")
        }

        hydratedLightingStateByDeviceID.insert(device.id)
    }

    private func persistLightingColor(_ color: RGBColor, device: MouseDevice) {
        let key = "lightingColor.\(persistenceKey(for: device))"
        UserDefaults.standard.set([color.r, color.g, color.b], forKey: key)
    }

    private func loadPersistedLightingColor(device: MouseDevice) -> RGBColor? {
        let key = "lightingColor.\(persistenceKey(for: device))"
        let legacyKey = "lightingColor.\(legacyPersistenceKey(for: device))"
        let values = (UserDefaults.standard.array(forKey: key) as? [Int])
            ?? (UserDefaults.standard.array(forKey: legacyKey) as? [Int])
        guard let values, values.count == 3 else { return nil }
        return RGBColor(
            r: max(0, min(255, values[0])),
            g: max(0, min(255, values[1])),
            b: max(0, min(255, values[2]))
        )
    }

    private func persistLightingEffect(_ effect: LightingEffectPatch, device: MouseDevice) {
        let key = "lightingEffect.\(persistenceKey(for: device))"
        let persisted = PersistedLightingEffect(
            kindRaw: effect.kind.rawValue,
            waveDirectionRaw: effect.waveDirection.rawValue,
            reactiveSpeed: max(1, min(4, effect.reactiveSpeed)),
            secondaryRGB: [effect.secondary.r, effect.secondary.g, effect.secondary.b]
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func loadPersistedLightingEffect(device: MouseDevice) -> (
        kind: LightingEffectKind,
        waveDirection: LightingWaveDirection,
        reactiveSpeed: Int,
        secondaryColor: RGBColor
    )? {
        let key = "lightingEffect.\(persistenceKey(for: device))"
        let legacyKey = "lightingEffect.\(legacyPersistenceKey(for: device))"
        let data = UserDefaults.standard.data(forKey: key) ?? UserDefaults.standard.data(forKey: legacyKey)
        guard
            let data,
            let decoded = try? JSONDecoder().decode(PersistedLightingEffect.self, from: data),
            let kind = LightingEffectKind(rawValue: decoded.kindRaw)
        else {
            return nil
        }

        let direction = LightingWaveDirection(rawValue: decoded.waveDirectionRaw) ?? .left
        let speed = max(1, min(4, decoded.reactiveSpeed))
        let fallback = [0, 170, 255]
        let values = (0..<3).map { idx -> Int in
            if idx < decoded.secondaryRGB.count {
                return decoded.secondaryRGB[idx]
            }
            return fallback[idx]
        }
        let color = RGBColor(
            r: max(0, min(255, values[0])),
            g: max(0, min(255, values[1])),
            b: max(0, min(255, values[2]))
        )
        return (kind: kind, waveDirection: direction, reactiveSpeed: speed, secondaryColor: color)
    }

    private func hydrateButtonBindingsIfNeeded(device: MouseDevice) {
        guard hydratedButtonBindingsDeviceID != device.id else { return }

        editableButtonBindings = loadPersistedButtonBindings(device: device)
        keyboardTextDraftBySlot = editableButtonBindings.reduce(into: [:]) { partialResult, pair in
            let slot = pair.key
            let draft = pair.value
            if draft.kind == .keyboardSimple {
                partialResult[slot] = AppState.keyboardText(forHidKey: draft.hidKey) ?? ""
            }
        }
        hydratedButtonBindingsDeviceID = device.id
        AppLog.debug("AppState", "hydrated button bindings from persisted cache id=\(device.id) slots=\(editableButtonBindings.keys.sorted())")
    }

    private func persistButtonBinding(_ binding: ButtonBindingPatch, device: MouseDevice) {
        var persisted = loadPersistedButtonBindings(device: device)
        persisted[binding.slot] = ButtonBindingDraft(
            kind: binding.kind,
            hidKey: binding.kind == .keyboardSimple ? max(4, min(231, binding.hidKey ?? 4)) : 4,
            turboEnabled: binding.kind.supportsTurbo ? binding.turboEnabled : false,
            turboRate: max(1, min(255, binding.turboRate ?? 0x8E))
        )
        savePersistedButtonBindings(device: device, bindings: persisted)
    }

    private func savePersistedButtonBindings(device: MouseDevice, bindings: [Int: ButtonBindingDraft]) {
        let key = "buttonBindings.\(persistenceKey(for: device))"
        let encoded = bindings.reduce(into: [String: PersistedButtonBinding]()) { partialResult, pair in
            partialResult[String(pair.key)] = PersistedButtonBinding(
                kindRaw: pair.value.kind.rawValue,
                hidKey: pair.value.hidKey,
                turboEnabled: pair.value.turboEnabled,
                turboRate: pair.value.turboRate
            )
        }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func loadPersistedButtonBindings(device: MouseDevice) -> [Int: ButtonBindingDraft] {
        let key = "buttonBindings.\(persistenceKey(for: device))"
        let legacyKey = "buttonBindings.\(legacyPersistenceKey(for: device))"
        let data = UserDefaults.standard.data(forKey: key) ?? UserDefaults.standard.data(forKey: legacyKey)
        guard
            let data,
            let decoded = try? JSONDecoder().decode([String: PersistedButtonBinding].self, from: data)
        else {
            return [:]
        }

        return decoded.reduce(into: [Int: ButtonBindingDraft]()) { partialResult, pair in
            guard
                let slot = Int(pair.key),
                let kind = ButtonBindingKind(rawValue: pair.value.kindRaw),
                buttonSlots.contains(where: { $0.slot == slot })
            else {
                return
            }
            partialResult[slot] = ButtonBindingDraft(
                kind: kind,
                hidKey: max(4, min(231, pair.value.hidKey)),
                turboEnabled: kind.supportsTurbo ? pair.value.turboEnabled : false,
                turboRate: max(1, min(255, pair.value.turboRate))
            )
        }
    }

    private func persistenceKey(for device: MouseDevice) -> String {
        if let serial = device.serial?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !serial.isEmpty {
            return "serial:\(serial.lowercased())"
        }
        return String(
            format: "vp:%04x:%04x:%@",
            device.vendor_id,
            device.product_id,
            device.transport.lowercased()
        )
    }

    private func legacyPersistenceKey(for device: MouseDevice) -> String {
        device.id
    }

    private func defaultButtonBinding(for slot: Int) -> ButtonBindingDraft {
        let fallback = ButtonBindingDraft(kind: .default, hidKey: 4, turboEnabled: false, turboRate: 0x8E)
        guard buttonSlots.contains(where: { $0.slot == slot }) else { return fallback }
        // We currently do not have a capture-backed button-binding read path, so startup
        // should present the neutral selection and let users choose/apply explicit mappings.
        return fallback
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
        let raw = max(1, min(255, rawRate))
        // Normalize device raw rate (1..255, inverse speed) to Synapse-style 1..20 presses/sec.
        let scaled = 20.0 - (Double(raw - 1) * 19.0 / 254.0)
        return max(1, min(20, Int(round(scaled))))
    }

    static func turboPressesPerSecondToRaw(_ pressesPerSecond: Int) -> Int {
        let pps = max(1, min(20, pressesPerSecond))
        // Inverse of turboRawToPressesPerSecond.
        let scaled = 1.0 + (Double(20 - pps) * 254.0 / 19.0)
        return max(1, min(255, Int(round(scaled))))
    }
}

private extension DevicePatch {
    var describe: String {
        var parts: [String] = []
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

struct RGBColor: Equatable {
    var r: Int
    var g: Int
    var b: Int
}

struct ButtonSlotDescriptor: Identifiable, Hashable {
    let slot: Int
    let friendlyName: String
    let defaultKind: ButtonBindingKind

    var id: Int { slot }

    static let defaults: [ButtonSlotDescriptor] = [
        ButtonSlotDescriptor(slot: 1, friendlyName: "Left Click", defaultKind: .leftClick),
        ButtonSlotDescriptor(slot: 2, friendlyName: "Right Click", defaultKind: .rightClick),
        ButtonSlotDescriptor(slot: 3, friendlyName: "Middle Click", defaultKind: .middleClick),
        ButtonSlotDescriptor(slot: 4, friendlyName: "Back Button", defaultKind: .mouseBack),
        ButtonSlotDescriptor(slot: 5, friendlyName: "Forward Button", defaultKind: .mouseForward),
        ButtonSlotDescriptor(slot: 9, friendlyName: "Scroll Up", defaultKind: .scrollUp),
        ButtonSlotDescriptor(slot: 10, friendlyName: "Scroll Down", defaultKind: .scrollDown),
        ButtonSlotDescriptor(slot: 96, friendlyName: "DPI Cycle", defaultKind: .default),
    ]
}

struct ButtonBindingDraft: Hashable {
    var kind: ButtonBindingKind
    var hidKey: Int
    var turboEnabled: Bool
    var turboRate: Int
}

private struct PersistedButtonBinding: Codable {
    let kindRaw: String
    let hidKey: Int
    let turboEnabled: Bool
    let turboRate: Int
}

private struct PersistedLightingEffect: Codable {
    let kindRaw: String
    let waveDirectionRaw: Int
    let reactiveSpeed: Int
    let secondaryRGB: [Int]
}
