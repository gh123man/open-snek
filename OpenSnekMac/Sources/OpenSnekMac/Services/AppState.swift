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
    var singleStageMode = false
    var editableActiveStage = 1
    var editablePollRate = 1000
    var editableLedBrightness = 64
    var editableColor = RGBColor(r: 0, g: 255, b: 0)
    var editableButtonSlot = 2
    var editableButtonKind: ButtonBindingKind = .rightClick
    var editableHidKey = 4

    private let client = BridgeClient()
    private var isHydrating = false
    private var dpiApplyTask: Task<Void, Never>?
    private var pollApplyTask: Task<Void, Never>?
    private var ledApplyTask: Task<Void, Never>?
    private var colorApplyTask: Task<Void, Never>?
    private var buttonApplyTask: Task<Void, Never>?
    private var activeStageApplyTask: Task<Void, Never>?
    private var hasPendingLocalEdits = false
    private var stateCacheByDeviceID: [String: MouseState] = [:]
    private var isRefreshingDpiFast = false

    var selectedDevice: MouseDevice? {
        guard let selectedDeviceID else { return nil }
        return devices.first(where: { $0.id == selectedDeviceID })
    }

    func refreshDevices() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let listed = try await client.listDevices()
            devices = listed
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
            errorMessage = error.localizedDescription
        }

        await refreshState()
    }

    func refreshState() async {
        guard let selectedDevice else {
            state = nil
            return
        }
        guard !isRefreshingState, !isApplying else { return }

        if let cached = stateCacheByDeviceID[selectedDevice.id] {
            state = cached
        }

        isRefreshingState = true
        defer { isRefreshingState = false }

        do {
            let fetched = try await client.readState(device: selectedDevice)
            let merged = fetched.merged(with: stateCacheByDeviceID[selectedDevice.id])
            stateCacheByDeviceID[selectedDevice.id] = merged
            if state != merged {
                state = merged
            }
            lastUpdated = Date()
            if !hasPendingLocalEdits && !isApplying {
                hydrateEditable(from: merged)
            }
            errorMessage = nil
        } catch {
            if stateCacheByDeviceID[selectedDevice.id] == nil {
                errorMessage = error.localizedDescription
            } else {
                // Keep last known-good UI stable on transient polling failures.
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
        let count = singleStageMode ? 1 : max(1, min(5, editableStageCount))
        let values = Array(editableStageValues.prefix(count)).map { max(100, min(30000, $0)) }
        let active = singleStageMode ? 0 : max(0, min(count - 1, editableActiveStage - 1))

        await apply(patch: DevicePatch(dpiStages: values, activeStage: active))
    }

    func scheduleAutoApplyDpi() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        dpiApplyTask?.cancel()
        dpiApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            await self?.applyDpiStages()
        }
    }

    func applyActiveStageOnly() async {
        let count = singleStageMode ? 1 : max(1, min(5, editableStageCount))
        let active = singleStageMode ? 0 : max(0, min(count - 1, editableActiveStage - 1))
        await apply(patch: DevicePatch(activeStage: active))
    }

    func scheduleAutoApplyActiveStage() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        activeStageApplyTask?.cancel()
        activeStageApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            await self?.applyActiveStageOnly()
        }
    }

    func applyPollRate() async {
        await apply(patch: DevicePatch(pollRate: editablePollRate))
    }

    func scheduleAutoApplyPollRate() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        pollApplyTask?.cancel()
        pollApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await self?.applyPollRate()
        }
    }

    func applyLedBrightness() async {
        await apply(patch: DevicePatch(ledBrightness: editableLedBrightness))
    }

    func scheduleAutoApplyLedBrightness() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        ledApplyTask?.cancel()
        ledApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            await self?.applyLedBrightness()
        }
    }

    func applyLedColor() async {
        await apply(patch: DevicePatch(ledRGB: RGBPatch(r: editableColor.r, g: editableColor.g, b: editableColor.b)))
    }

    func scheduleAutoApplyLedColor() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        colorApplyTask?.cancel()
        colorApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self?.applyLedColor()
        }
    }

    func applyButtonBinding() async {
        let binding = ButtonBindingPatch(
            slot: editableButtonSlot,
            kind: editableButtonKind,
            hidKey: editableButtonKind == .keyboardSimple ? editableHidKey : nil
        )
        await apply(patch: DevicePatch(buttonBinding: binding))
    }

    func scheduleAutoApplyButton() {
        guard !isHydrating else { return }
        hasPendingLocalEdits = true
        buttonApplyTask?.cancel()
        buttonApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            await self?.applyButtonBinding()
        }
    }

    func refreshDpiFast() async {
        guard let selectedDevice, selectedDevice.transport == "bluetooth" else { return }
        guard !isRefreshingDpiFast, !isApplying else { return }
        guard !hasPendingLocalEdits else { return }

        isRefreshingDpiFast = true
        defer { isRefreshingDpiFast = false }

        do {
            guard let fast = try await client.readDpiStagesFast(device: selectedDevice) else { return }
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
                device_mode: previous.device_mode,
                led_value: previous.led_value,
                capabilities: previous.capabilities
            )

            stateCacheByDeviceID[selectedDevice.id] = updated
            if state != updated {
                state = updated
            }
            if !isApplying {
                hydrateEditable(from: updated)
            }
        } catch {
            // Ignore fast-poll transient failures to keep UI stable.
        }
    }

    private func apply(patch: DevicePatch) async {
        guard let selectedDevice else {
            errorMessage = "No device selected"
            return
        }

        isApplying = true
        defer { isApplying = false }

        do {
            let next = try await client.apply(device: selectedDevice, patch: patch)
            let merged = next.merged(with: stateCacheByDeviceID[selectedDevice.id])
            stateCacheByDeviceID[selectedDevice.id] = merged
            if state != merged {
                state = merged
            }
            lastUpdated = Date()
            hasPendingLocalEdits = false
            hydrateEditable(from: merged)
            errorMessage = nil
        } catch {
            hasPendingLocalEdits = false
            errorMessage = error.localizedDescription
        }
    }

    private func hydrateEditable(from state: MouseState) {
        isHydrating = true
        defer { isHydrating = false }

        if let values = state.dpi_stages.values, !values.isEmpty {
            editableStageCount = max(1, min(5, values.count))
            singleStageMode = editableStageCount == 1
            for i in 0..<editableStageValues.count {
                if i < values.count {
                    editableStageValues[i] = max(100, min(30000, values[i]))
                }
            }
        }

        if let active = state.dpi_stages.active_stage {
            editableActiveStage = max(1, min(5, active + 1))
        }

        if let poll = state.poll_rate {
            editablePollRate = poll
        }

        if let led = state.led_value {
            editableLedBrightness = led
        }
    }
}

struct RGBColor {
    var r: Int
    var g: Int
    var b: Int
}
