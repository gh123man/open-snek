import Foundation
import XCTest
import OpenSnekAppSupport
import OpenSnekCore
@testable import OpenSnek

final class AppStateRefactorCharacterizationTests: XCTestCase {
    func testApplyWithoutSelectedDeviceShowsNoDeviceSelectedError() async throws {
        let backend = AppStateRefactorStubBackend(devices: [], stateByDeviceID: [:])
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.editorStore.applyPollRate()

        try await waitForRefactorCondition {
            await MainActor.run { appState.deviceStore.errorMessage == "No device selected" }
        }

        let applyCount = await backend.applyCount()
        XCTAssertEqual(applyCount, 0)
    }

    func testQueuedAppliesStaySerializedAndDoNotHydrateOverNewerDrafts() async throws {
        let device = makeRefactorTestDevice(
            id: "queued-apply-device",
            transport: .usb,
            serial: "QUEUE-\(UUID().uuidString)",
            onboardProfileCount: 1
        )
        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 81,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300
                )
            ],
            holdFirstApply: true
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.editablePollRate = 500
        }
        await appState.editorStore.applyPollRate()
        await backend.waitForFirstApplyToStart()

        await MainActor.run {
            appState.editorStore.editablePollRate = 250
        }
        await appState.editorStore.applyPollRate()
        await backend.releaseFirstApply()

        try await waitForRefactorCondition(timeout: 2.0) {
            await backend.applyCount() == 2
        }

        let patches = await backend.recordedPatches()
        let maxConcurrentApplies = await backend.maxConcurrentApplies()
        let editablePollRate = await MainActor.run { appState.editorStore.editablePollRate }
        let livePollRate = await MainActor.run { appState.deviceStore.state?.poll_rate }

        XCTAssertEqual(maxConcurrentApplies, 1)
        XCTAssertEqual(patches.map(\.pollRate), [500, 250])
        XCTAssertEqual(editablePollRate, 250)
        XCTAssertEqual(livePollRate, 250)
    }

    func testStageApplySuppressesFastPollingTemporarily() async throws {
        let device = makeRefactorTestDevice(
            id: "dpi-stage-device",
            transport: .usb,
            serial: "DPI-\(UUID().uuidString)",
            onboardProfileCount: 1
        )
        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 74,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300
                )
            ],
            shouldUseFastPolling: true
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.editableStageCount = 3
            appState.editorStore.editableStageValues = [1000, 2000, 3000, 6400, 12000]
            appState.editorStore.editableActiveStage = 3
        }
        await appState.editorStore.applyDpiStages()

        try await waitForRefactorCondition {
            await backend.applyCount() == 1
        }

        await appState.deviceStore.refreshDpiFast()
        let initialFastReadCount = await backend.fastReadCount()
        XCTAssertEqual(initialFastReadCount, 0)

        try await Task.sleep(nanoseconds: 1_000_000_000)

        await appState.deviceStore.refreshDpiFast()
        let finalFastReadCount = await backend.fastReadCount()
        XCTAssertEqual(finalFastReadCount, 1)
    }

    func testBluetoothPersistedLightingColorReappliesOnFirstHydration() async throws {
        let device = makeRefactorTestDevice(
            id: "bt-lighting-device",
            transport: .bluetooth,
            serial: "BT-LIGHT-\(UUID().uuidString)",
            onboardProfileCount: 1
        )
        let persistedColor = RGBColor(r: 10, g: 20, b: 30)
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistLightingColor(persistedColor, device: device)
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "bluetooth",
                    batteryPercent: 68,
                    dpiValues: [1200, 2400, 3600],
                    activeStage: 1,
                    dpiValue: 2400,
                    pollRate: 1000,
                    sleepTimeout: 300
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        try await waitForRefactorCondition {
            await backend.applyCount() == 1
        }

        let patches = await backend.recordedPatches()
        let patch = try XCTUnwrap(patches.first)
        let editableColor = await MainActor.run { appState.editorStore.editableColor }

        XCTAssertEqual(patch.ledRGB?.r, persistedColor.r)
        XCTAssertEqual(patch.ledRGB?.g, persistedColor.g)
        XCTAssertEqual(patch.ledRGB?.b, persistedColor.b)
        XCTAssertEqual(editableColor, persistedColor)
    }

    func testUSBButtonHydrationPrefersDeviceReadbackOverPersistedCache() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-button-device",
            transport: .usb,
            serial: "USB-BTN-\(UUID().uuidString)",
            onboardProfileCount: 1
        )
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.savePersistedButtonBindings(
            device: device,
            bindings: [
                4: ButtonBindingDraft(
                    kind: .leftClick,
                    hidKey: 4,
                    turboEnabled: false,
                    turboRate: 0x8E,
                    clutchDPI: nil
                )
            ],
            profile: 1
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 88,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600,
                    pollRate: 1000,
                    sleepTimeout: 300
                )
            ]
        )
        await backend.setButtonBindingBlock(
            [0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00],
            forDeviceID: device.id,
            slot: 4,
            profile: 1
        )
        await backend.setButtonBindingBlock(
            [0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00],
            forDeviceID: device.id,
            slot: 4,
            profile: 0
        )

        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        try await waitForRefactorCondition {
            await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) == .rightClick }
        }

        let binding = await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) }
        XCTAssertEqual(binding, .rightClick)
    }

    func testSwitchingUSBButtonProfileInvalidatesHydrationCache() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-device",
            transport: .usb,
            serial: "USB-PROFILE-\(UUID().uuidString)",
            onboardProfileCount: 2
        )
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.savePersistedButtonBindings(
            device: device,
            bindings: [
                4: ButtonBindingDraft(
                    kind: .leftClick,
                    hidKey: 4,
                    turboEnabled: false,
                    turboRate: 0x8E,
                    clutchDPI: nil
                )
            ],
            profile: 1
        )
        preferenceStore.savePersistedButtonBindings(
            device: device,
            bindings: [
                4: ButtonBindingDraft(
                    kind: .rightClick,
                    hidKey: 4,
                    turboEnabled: false,
                    turboRate: 0x8E,
                    clutchDPI: nil
                )
            ],
            profile: 2
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 77,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 2
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        let initialBinding = await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) }
        XCTAssertEqual(initialBinding, .leftClick)

        await MainActor.run {
            appState.editorStore.updateUSBButtonProfile(2)
        }

        try await waitForRefactorCondition {
            await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) == .rightClick }
        }

        let selectedProfile = await MainActor.run { appState.editorStore.editableUSBButtonProfile }
        let updatedBinding = await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) }
        XCTAssertEqual(selectedProfile, 2)
        XCTAssertEqual(updatedBinding, .rightClick)
    }
}

private actor AppStateRefactorStubBackend: DeviceBackend {
    nonisolated var usesRemoteServiceTransport: Bool { false }

    private let devices: [MouseDevice]
    private var stateByDeviceID: [String: MouseState]
    private var fastByDeviceID: [String: DpiFastSnapshot]
    private let shouldUseFastPolling: Bool
    private let holdFirstApply: Bool
    private var applyPatches: [DevicePatch] = []
    private var applyInvocationCount = 0
    private var activeApplyCount = 0
    private var maxObservedConcurrentApplies = 0
    private var firstApplyStartedContinuation: CheckedContinuation<Void, Never>?
    private var firstApplyReleaseContinuation: CheckedContinuation<Void, Never>?
    private var buttonBindingBlocks: [String: [UInt8]] = [:]
    private var fastReadInvocationCount = 0

    init(
        devices: [MouseDevice],
        stateByDeviceID: [String: MouseState],
        shouldUseFastPolling: Bool = false,
        holdFirstApply: Bool = false
    ) {
        self.devices = devices
        self.stateByDeviceID = stateByDeviceID
        self.fastByDeviceID = stateByDeviceID.reduce(into: [:]) { partialResult, entry in
            if let active = entry.value.dpi_stages.active_stage,
               let values = entry.value.dpi_stages.values {
                partialResult[entry.key] = DpiFastSnapshot(active: active, values: values)
            }
        }
        self.shouldUseFastPolling = shouldUseFastPolling
        self.holdFirstApply = holdFirstApply
    }

    func listDevices() async throws -> [MouseDevice] {
        devices
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        guard let state = stateByDeviceID[device.id] else {
            throw NSError(domain: "AppStateRefactorCharacterizationTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing state for \(device.id)"
            ])
        }
        return state
    }

    func readDpiStagesFast(device: MouseDevice) async throws -> DpiFastSnapshot? {
        fastReadInvocationCount += 1
        return fastByDeviceID[device.id]
    }

    func shouldUseFastDPIPolling(device _: MouseDevice) async -> Bool {
        shouldUseFastPolling
    }

    func hidAccessStatus() async -> HIDAccessStatus {
        HIDAccessStatus(
            authorization: .granted,
            hostLabel: "Test Host (io.opensnek.OpenSnek)",
            bundleIdentifier: "io.opensnek.OpenSnek",
            detail: nil
        )
    }

    func stateUpdates() async -> AsyncStream<BackendStateUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func apply(device: MouseDevice, patch: DevicePatch) async throws -> MouseState {
        applyInvocationCount += 1
        activeApplyCount += 1
        maxObservedConcurrentApplies = max(maxObservedConcurrentApplies, activeApplyCount)

        defer {
            activeApplyCount -= 1
        }

        if holdFirstApply, applyInvocationCount == 1 {
            firstApplyStartedContinuation?.resume()
            firstApplyStartedContinuation = nil
            await withCheckedContinuation { continuation in
                firstApplyReleaseContinuation = continuation
            }
        }

        applyPatches.append(patch)

        guard let current = stateByDeviceID[device.id] else {
            throw NSError(domain: "AppStateRefactorCharacterizationTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Missing apply state for \(device.id)"
            ])
        }

        let next = stateApplying(patch, to: current)
        stateByDeviceID[device.id] = next
        if let active = next.dpi_stages.active_stage,
           let values = next.dpi_stages.values {
            fastByDeviceID[device.id] = DpiFastSnapshot(active: active, values: values)
        }
        return next
    }

    func readLightingColor(device _: MouseDevice) async throws -> RGBPatch? {
        nil
    }

    func debugUSBReadButtonBinding(device: MouseDevice, slot: Int, profile: Int) async throws -> [UInt8]? {
        buttonBindingBlocks[buttonKey(deviceID: device.id, slot: slot, profile: profile)]
    }

    func waitForFirstApplyToStart() async {
        if applyInvocationCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            firstApplyStartedContinuation = continuation
        }
    }

    func releaseFirstApply() {
        firstApplyReleaseContinuation?.resume()
        firstApplyReleaseContinuation = nil
    }

    func recordedPatches() -> [DevicePatch] {
        applyPatches
    }

    func applyCount() -> Int {
        applyInvocationCount
    }

    func maxConcurrentApplies() -> Int {
        maxObservedConcurrentApplies
    }

    func fastReadCount() -> Int {
        fastReadInvocationCount
    }

    func setButtonBindingBlock(_ block: [UInt8], forDeviceID deviceID: String, slot: Int, profile: Int) {
        buttonBindingBlocks[buttonKey(deviceID: deviceID, slot: slot, profile: profile)] = block
    }

    private func buttonKey(deviceID: String, slot: Int, profile: Int) -> String {
        "\(deviceID)#\(slot)#\(profile)"
    }

    private func stateApplying(_ patch: DevicePatch, to current: MouseState) -> MouseState {
        let nextStages: [Int]? = patch.dpiStages ?? current.dpi_stages.values
        let nextActive = patch.activeStage ?? current.dpi_stages.active_stage
        let resolvedStages = DpiStages(active_stage: nextActive, values: nextStages)
        let nextDpi: DpiPair? = {
            guard let values = nextStages, !values.isEmpty else {
                return current.dpi
            }
            let activeIndex = max(0, min(values.count - 1, nextActive ?? 0))
            return DpiPair(x: values[activeIndex], y: values[activeIndex])
        }()

        return MouseState(
            device: current.device,
            connection: current.connection,
            battery_percent: current.battery_percent,
            charging: current.charging,
            dpi: nextDpi,
            dpi_stages: resolvedStages,
            poll_rate: patch.pollRate ?? current.poll_rate,
            sleep_timeout: patch.sleepTimeout ?? current.sleep_timeout,
            device_mode: patch.deviceMode ?? current.device_mode,
            low_battery_threshold_raw: patch.lowBatteryThresholdRaw ?? current.low_battery_threshold_raw,
            scroll_mode: patch.scrollMode ?? current.scroll_mode,
            scroll_acceleration: patch.scrollAcceleration ?? current.scroll_acceleration,
            scroll_smart_reel: patch.scrollSmartReel ?? current.scroll_smart_reel,
            active_onboard_profile: current.active_onboard_profile,
            onboard_profile_count: current.onboard_profile_count,
            led_value: patch.ledBrightness ?? current.led_value,
            capabilities: current.capabilities
        )
    }
}

private func makeRefactorTestDevice(
    id: String,
    transport: DeviceTransportKind,
    serial: String,
    onboardProfileCount: Int
) -> MouseDevice {
    MouseDevice(
        id: id,
        vendor_id: transport == .bluetooth ? 0x068E : 0x1532,
        product_id: transport == .bluetooth ? 0x00BA : 0x00AB,
        product_name: transport == .bluetooth ? "Refactor BT Mouse" : "Refactor USB Mouse",
        transport: transport,
        path_b64: "",
        serial: serial,
        firmware: "1.0.0",
        location_id: 1,
        profile_id: transport == .bluetooth ? .basiliskV3XHyperspeed : .basiliskV3Pro,
        supports_advanced_lighting_effects: true,
        onboard_profile_count: onboardProfileCount
    )
}

private func makeRefactorTestState(
    device: MouseDevice,
    connection: String,
    batteryPercent: Int,
    dpiValues: [Int],
    activeStage: Int,
    dpiValue: Int,
    pollRate: Int,
    sleepTimeout: Int,
    activeOnboardProfile: Int? = nil,
    onboardProfileCount: Int? = nil
) -> MouseState {
    MouseState(
        device: DeviceSummary(
            id: device.id,
            product_name: device.product_name,
            serial: device.serial,
            transport: device.transport,
            firmware: device.firmware
        ),
        connection: connection,
        battery_percent: batteryPercent,
        charging: false,
        dpi: DpiPair(x: dpiValue, y: dpiValue),
        dpi_stages: DpiStages(active_stage: activeStage, values: dpiValues),
        poll_rate: pollRate,
        sleep_timeout: sleepTimeout,
        device_mode: DeviceMode(mode: 0x00, param: 0x00),
        active_onboard_profile: activeOnboardProfile,
        onboard_profile_count: onboardProfileCount,
        led_value: 64,
        capabilities: Capabilities(
            dpi_stages: true,
            poll_rate: true,
            power_management: true,
            button_remap: true,
            lighting: true
        )
    )
}

private func clearRefactorPreferences(for device: MouseDevice) {
    let defaults = UserDefaults.standard
    let key = DevicePersistenceKeys.key(for: device)
    let legacyKey = DevicePersistenceKeys.legacyKey(for: device)
    let prefixes = [
        "lightingColor.\(key)",
        "lightingColor.\(legacyKey)",
        "lightingEffect.\(key)",
        "lightingEffect.\(legacyKey)",
        "buttonBindings.\(key)",
        "buttonBindings.\(legacyKey)",
        "buttonBindings.\(key).profile1",
        "buttonBindings.\(key).profile2",
        "buttonBindings.\(legacyKey).profile1",
        "buttonBindings.\(legacyKey).profile2",
    ]
    for prefix in prefixes {
        defaults.removeObject(forKey: prefix)
    }
}

private func waitForRefactorCondition(
    timeout: TimeInterval = 1.0,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if await condition() {
                    return
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            throw NSError(domain: "AppStateRefactorCharacterizationTests", code: 90, userInfo: [
                NSLocalizedDescriptionKey: "Timed out waiting for characterization condition"
            ])
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw NSError(domain: "AppStateRefactorCharacterizationTests", code: 91, userInfo: [
                NSLocalizedDescriptionKey: "Timed out waiting for characterization condition"
            ])
        }

        _ = try await group.next()
        group.cancelAll()
    }
}
