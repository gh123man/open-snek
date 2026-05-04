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
            await backend.applyCount() >= 1
        }

        await appState.deviceStore.refreshDpiFast()
        let initialFastReadCount = await backend.fastReadCount()
        XCTAssertEqual(initialFastReadCount, 0)

        try await Task.sleep(nanoseconds: 1_000_000_000)

        await appState.deviceStore.refreshDpiFast()
        let finalFastReadCount = await backend.fastReadCount()
        XCTAssertEqual(finalFastReadCount, 1)
    }

    func testStageApplyPreservesExactNonHundredDpiValues() async throws {
        let device = makeRefactorTestDevice(
            id: "dpi-exact-device",
            transport: .usb,
            serial: "DPI-EXACT-\(UUID().uuidString)",
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
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.editableStageCount = 3
            appState.editorStore.editableStageValues = [1555, 2444, 3777, 6400, 12000]
            appState.editorStore.editableStagePairs = [
                DpiPair(x: 1555, y: 1555),
                DpiPair(x: 2444, y: 2444),
                DpiPair(x: 3777, y: 3777),
                DpiPair(x: 6400, y: 6400),
                DpiPair(x: 12000, y: 12000),
            ]
            appState.editorStore.editableActiveStage = 2
        }
        await appState.editorStore.applyDpiStages()

        try await waitForRefactorCondition {
            await backend.applyCount() == 1
        }

        let patches = await backend.recordedPatches()
        let patch = try XCTUnwrap(patches.first)
        XCTAssertEqual(patch.dpiStages, [1555, 2444, 3777])
        XCTAssertEqual(
            patch.dpiStagePairs,
            [
                DpiPair(x: 1555, y: 1555),
                DpiPair(x: 2444, y: 2444),
                DpiPair(x: 3777, y: 3777),
            ]
        )
        XCTAssertEqual(patch.activeStage, 1)
    }

    func testHydratedEditableDpiStagesClampToSelectedDeviceLimit() async throws {
        let device = makeRefactorTestDevice(
            id: "dpi-clamp-device",
            transport: .bluetooth,
            serial: "DPI-CLAMP-\(UUID().uuidString)",
            onboardProfileCount: 1
        )
        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "bluetooth",
                    batteryPercent: 74,
                    dpiValues: [800, 20_000, 24_000],
                    activeStage: 1,
                    dpiValue: 20_000,
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
            await MainActor.run { appState.editorStore.stageValue(1) == 18_000 }
        }

        let editableValues = await MainActor.run {
            Array(appState.editorStore.editableStageValues.prefix(appState.editorStore.editableStageCount))
        }
        let selectedDPIRange = await MainActor.run {
            DeviceProfiles.dpiRange(for: appState.editorStore.selectedDeviceProfileID)
        }

        XCTAssertEqual(editableValues, [800, 18_000, 18_000])
        XCTAssertEqual(selectedDPIRange, 100...18_000)
    }

    func testBluetoothPersistedSettingsSnapshotReappliesOnFirstHydration() async throws {
        let device = makeRefactorTestDevice(
            id: "bt-lighting-device",
            transport: .bluetooth,
            serial: "BT-LIGHT-\(UUID().uuidString)",
            onboardProfileCount: 1
        )
        let persistedColor = RGBColor(r: 10, g: 20, b: 30)
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistDeviceSettingsSnapshot(
            makeRefactorSettingsSnapshot(
                color: persistedColor,
                buttonBindings: [
                    5: ButtonBindingDraft(
                        kind: .keyboardSimple,
                        hidKey: 80,
                        turboEnabled: false,
                        turboRate: 0x8E,
                        clutchDPI: nil
                    )
                ]
            ),
            device: device
        )
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
            await backend.applyCount() >= 2
        }

        let patches = await backend.recordedPatches()
        let patch = try XCTUnwrap(patches.first)
        let buttonPatch = try XCTUnwrap(patches.first(where: { $0.buttonBinding?.slot == 5 }))
        let editableColor = await MainActor.run { appState.editorStore.editableColor }
        let editableActiveStage = await MainActor.run { appState.editorStore.editableActiveStage }

        XCTAssertEqual(patch.pollRate, 500)
        XCTAssertEqual(patch.sleepTimeout, 420)
        XCTAssertEqual(patch.lowBatteryThresholdRaw, 0x20)
        XCTAssertEqual(patch.scrollMode, 1)
        XCTAssertEqual(patch.scrollAcceleration, true)
        XCTAssertEqual(patch.scrollSmartReel, false)
        XCTAssertEqual(patch.dpiStages, [900, 1800, 3600])
        XCTAssertEqual(patch.activeStage, 2)
        XCTAssertEqual(patch.ledRGB?.r, persistedColor.r)
        XCTAssertEqual(patch.ledRGB?.g, persistedColor.g)
        XCTAssertEqual(patch.ledRGB?.b, persistedColor.b)
        XCTAssertEqual(buttonPatch.buttonBinding?.kind, .keyboardSimple)
        XCTAssertEqual(buttonPatch.buttonBinding?.hidKey, 80)
        XCTAssertEqual(editableColor, persistedColor)
        XCTAssertEqual(editableActiveStage, 3)
    }

    func testUseMouseConnectBehaviorDoesNotAutoRestorePersistedSettingsSnapshot() async throws {
        let device = MouseDevice(
            id: "bt-v3-pro-lighting-zone",
            vendor_id: 0x068E,
            product_id: 0x00AC,
            product_name: "Basilisk V3 Pro",
            transport: .bluetooth,
            path_b64: "",
            serial: "BT-V3PRO-LIGHT-\(UUID().uuidString)",
            firmware: "1.0.0",
            location_id: 1,
            profile_id: .basiliskV3Pro,
            supports_advanced_lighting_effects: false,
            onboard_profile_count: 3
        )
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistDeviceSettingsSnapshot(
            makeRefactorSettingsSnapshot(color: RGBColor(r: 10, g: 20, b: 30)),
            device: device
        )
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

        let applyCount = await backend.applyCount()
        let editableActiveStage = await MainActor.run { appState.editorStore.editableActiveStage }
        let connectBehavior = await MainActor.run { appState.editorStore.connectBehavior }
        let showsCard = await MainActor.run { appState.editorStore.showsConnectBehaviorCard }
        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(editableActiveStage, 2)
        XCTAssertEqual(connectBehavior, .useMouseSettings)
        XCTAssertTrue(showsCard)
    }

    func testRestoreInProgressSkipsAdditionalRefreshReadsForSameDevice() async throws {
        let alphaDevice = makeRefactorTestDevice(
            id: "restore-refresh-selected-device",
            transport: .usb,
            serial: "RESTORE-REFRESH-SELECTED-\(UUID().uuidString)",
            onboardProfileCount: 1
        )
        let betaDevice = makeRefactorTestDevice(
            id: "restore-refresh-target-device",
            transport: .usb,
            serial: "RESTORE-REFRESH-TARGET-\(UUID().uuidString)",
            onboardProfileCount: 1
        )
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistConnectBehavior(.restoreOpenSnekSettings, device: betaDevice)
        preferenceStore.persistDeviceSettingsSnapshot(
            makeRefactorSettingsSnapshot(color: RGBColor(r: 10, g: 20, b: 30)),
            device: betaDevice
        )
        defer {
            clearRefactorPreferences(for: alphaDevice)
            clearRefactorPreferences(for: betaDevice)
        }

        let backend = AppStateRefactorStubBackend(
            devices: [alphaDevice, betaDevice],
            stateByDeviceID: [
                alphaDevice.id: makeRefactorTestState(
                    device: alphaDevice,
                    connection: "usb",
                    batteryPercent: 81,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300
                ),
                betaDevice.id: makeRefactorTestState(
                    device: betaDevice,
                    connection: "usb",
                    batteryPercent: 74,
                    dpiValues: [1000, 2000, 3000],
                    activeStage: 1,
                    dpiValue: 2000,
                    pollRate: 1000,
                    sleepTimeout: 300
                ),
            ],
            shouldUseFastPolling: true,
            holdFirstApply: true
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        let refreshTask = Task {
            await appState.deviceStore.refreshDevices()
        }

        await backend.waitForFirstApplyToStart()

        let readCountBefore = await backend.readCount(for: betaDevice.id)
        let fastReadCountBefore = await backend.fastReadCount(for: betaDevice.id)

        let refreshed = await appState.deviceController.refreshState(for: betaDevice)
        await appState.deviceStore.refreshDpiFast()

        let readCountAfter = await backend.readCount(for: betaDevice.id)
        let fastReadCountAfter = await backend.fastReadCount(for: betaDevice.id)

        XCTAssertFalse(refreshed)
        XCTAssertEqual(readCountAfter, readCountBefore)
        XCTAssertEqual(fastReadCountAfter, fastReadCountBefore)

        await backend.releaseFirstApply()
        await refreshTask.value
    }

    func testRestoreButtonReplayDefersIntermediateReadbacksAndVerifiesOnceAtEnd() async throws {
        let device = makeRefactorUSBLightingRestoreDevice(
            id: "usb-restore-button-readback-device",
            serial: "USB-RESTORE-BUTTON-READBACK-\(UUID().uuidString)"
        )
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistConnectBehavior(.restoreOpenSnekSettings, device: device)
        preferenceStore.persistDeviceSettingsSnapshot(
            makeRefactorSettingsSnapshot(
                color: RGBColor(r: 10, g: 20, b: 30),
                buttonBindings: [
                    4: ButtonBindingDraft(
                        kind: .mouseForward,
                        hidKey: 4,
                        turboEnabled: false,
                        turboRate: 0x8E,
                        clutchDPI: nil
                    )
                ]
            ),
            device: device
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 81,
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
            await backend.applyCount() >= 2
        }

        let readCount = await backend.readCount(for: device.id)
        let policies = await backend.recordedApplyReadbackPolicies()
        XCTAssertEqual(readCount, 2)
        XCTAssertTrue(policies.contains(.skipStateReadback))
        if let first = policies.first, policies.count > 1 {
            XCTAssertEqual(first, .immediateStateReadback)
            XCTAssertTrue(policies.dropFirst().allSatisfy { $0 == .skipStateReadback })
        }
    }

    func testHyperspeedForcesRestoreBehaviorAndHidesConnectBehaviorCard() async throws {
        let device = makeRefactorTestDevice(
            id: "bt-hyperspeed-connect-behavior",
            transport: .bluetooth,
            serial: "BT-CONNECT-BEHAVIOR-\(UUID().uuidString)",
            onboardProfileCount: 1
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "bluetooth",
                    batteryPercent: 71,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600,
                    pollRate: 1000,
                    sleepTimeout: 300
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        let connectBehavior = await MainActor.run { appState.editorStore.connectBehavior }
        let showsCard = await MainActor.run { appState.editorStore.showsConnectBehaviorCard }
        XCTAssertEqual(connectBehavior, .restoreOpenSnekSettings)
        XCTAssertFalse(showsCard)
    }

    func testUSBHyperspeedDoesNotForceRestoreBehavior() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-hyperspeed-connect-behavior",
            transport: .usb,
            serial: "USB-CONNECT-BEHAVIOR-\(UUID().uuidString)",
            onboardProfileCount: 1,
            profileID: .basiliskV3XHyperspeed
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 71,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600,
                    pollRate: 1000,
                    sleepTimeout: 300
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        let connectBehavior = await MainActor.run { appState.editorStore.connectBehavior }
        let showsCard = await MainActor.run { appState.editorStore.showsConnectBehaviorCard }
        XCTAssertEqual(connectBehavior, .useMouseSettings)
        XCTAssertTrue(showsCard)
    }

    func testUSBV3ProUsesRememberedLightingStateWithoutAutoApply() async throws {
        let device = MouseDevice(
            id: "usb-v3-pro-lighting-zone",
            vendor_id: 0x1532,
            product_id: 0x00AB,
            product_name: "Basilisk V3 Pro",
            transport: .usb,
            path_b64: "",
            serial: "USB-V3PRO-LIGHT-\(UUID().uuidString)",
            firmware: "1.0.0",
            location_id: 1,
            profile_id: .basiliskV3Pro,
            supports_advanced_lighting_effects: false,
            onboard_profile_count: 5
        )
        let persistedColor = RGBColor(r: 11, g: 22, b: 33)
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistLightingColor(persistedColor, device: device, zoneID: "logo")
        preferenceStore.persistLightingZoneID("logo", device: device)
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
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

        let applyCount = await backend.applyCount()
        let editableColor = await MainActor.run { appState.editorStore.editableColor }
        let editableZone = await MainActor.run { appState.editorStore.editableUSBLightingZoneID }

        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(editableColor, persistedColor)
        XCTAssertEqual(editableZone, "logo")
    }

    func testUSBPersistedSettingsSnapshotReappliesOnFirstHydrationUsingSavedZone() async throws {
        let device = makeRefactorUSBLightingRestoreDevice(
            id: "usb-lighting-device",
            serial: "USB-LIGHT-\(UUID().uuidString)"
        )
        let persistedColor = RGBColor(r: 40, g: 50, b: 60)
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistConnectBehavior(.restoreOpenSnekSettings, device: device)
        preferenceStore.persistDeviceSettingsSnapshot(
            makeRefactorSettingsSnapshot(color: persistedColor, zoneID: "scroll_wheel"),
            device: device
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 73,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600,
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
            await backend.applyCount() >= 1
        }

        let patches = await backend.recordedPatches()
        let patch = try XCTUnwrap(patches.first)
        let editableColor = await MainActor.run { appState.editorStore.editableColor }
        let editableZone = await MainActor.run { appState.editorStore.editableUSBLightingZoneID }

        XCTAssertEqual(patch.ledRGB?.r, persistedColor.r)
        XCTAssertEqual(patch.ledRGB?.g, persistedColor.g)
        XCTAssertEqual(patch.ledRGB?.b, persistedColor.b)
        XCTAssertNil(patch.lightingEffect)
        XCTAssertEqual(patch.usbLightingZoneLEDIDs, [0x01])
        XCTAssertEqual(editableColor, persistedColor)
        XCTAssertEqual(editableZone, "scroll_wheel")
    }

    func testSelectedDevicePresentationHydratesPersistedSettingsSnapshotBeforeStateRefresh() async throws {
        let device = makeRefactorUSBLightingRestoreDevice(
            id: "usb-selected-lighting-device",
            serial: "USB-SELECTED-LIGHT-\(UUID().uuidString)"
        )
        let persistedColor = RGBColor(r: 91, g: 102, b: 113)
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistConnectBehavior(.restoreOpenSnekSettings, device: device)
        preferenceStore.persistDeviceSettingsSnapshot(
            makeRefactorSettingsSnapshot(color: persistedColor, zoneID: "scroll_wheel"),
            device: device
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(devices: [], stateByDeviceID: [:])
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await MainActor.run {
            _ = appState.deviceController.applyDeviceList([device], source: "refresh")
        }

        let selectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }
        let editableColor = await MainActor.run { appState.editorStore.editableColor }
        let editableZone = await MainActor.run { appState.editorStore.editableUSBLightingZoneID }
        let editableActiveStage = await MainActor.run { appState.editorStore.editableActiveStage }
        let applyCount = await backend.applyCount()

        XCTAssertEqual(selectedDeviceID, device.id)
        XCTAssertEqual(editableColor, persistedColor)
        XCTAssertEqual(editableZone, "scroll_wheel")
        XCTAssertEqual(editableActiveStage, 3)
        XCTAssertEqual(applyCount, 0)
    }

    func testSelectedDeviceLiveDpiStillHydratesWhilePersistedConnectPresentationIsHeld() async throws {
        let device = makeRefactorUSBLightingRestoreDevice(
            id: "usb-selected-live-dpi-device",
            serial: "USB-SELECTED-LIVE-DPI-\(UUID().uuidString)"
        )
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistConnectBehavior(.restoreOpenSnekSettings, device: device)
        preferenceStore.persistDeviceSettingsSnapshot(
            PersistedDeviceSettingsSnapshot(
                stageCount: 5,
                stageValues: [600, 900, 1000, 1200, 1400],
                stagePairs: [
                    DpiPair(x: 600, y: 600),
                    DpiPair(x: 900, y: 900),
                    DpiPair(x: 1000, y: 1000),
                    DpiPair(x: 1200, y: 1200),
                    DpiPair(x: 1400, y: 1400),
                ],
                activeStage: 3,
                pollRate: 500,
                sleepTimeout: 420,
                lowBatteryThresholdRaw: 0x20,
                scrollMode: 1,
                scrollAcceleration: true,
                scrollSmartReel: false,
                ledBrightness: 77,
                primaryLightingColor: RGBColor(r: 91, g: 102, b: 113),
                lightingEffect: nil,
                usbLightingZoneID: "scroll_wheel",
                buttonBindings: [:]
            ),
            device: device
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(devices: [], stateByDeviceID: [:])
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await MainActor.run {
            _ = appState.deviceController.applyDeviceList([device], source: "refresh")
        }

        let persistedActiveStage = await MainActor.run { appState.editorStore.editableActiveStage }
        XCTAssertEqual(persistedActiveStage, 3)

        let liveState = makeRefactorTestState(
            device: device,
            connection: "usb",
            batteryPercent: 81,
            dpiValues: [600, 900, 1000, 1200, 1400],
            activeStage: 0,
            dpiValue: 600,
            pollRate: 1000,
            sleepTimeout: 300
        )

        await MainActor.run {
            appState.deviceController.applyBackendDeviceStateUpdate(
                deviceID: device.id,
                state: liveState,
                updatedAt: Date(timeIntervalSince1970: 1_777_909_776)
            )
        }

        let liveActiveStage = await MainActor.run { appState.editorStore.editableActiveStage }
        XCTAssertEqual(liveActiveStage, 1)
    }

    func testSelectedDeviceBackendStateUpdatePreservesPendingLocalEditsWhileUpdatingLiveDpiPresentation() async {
        let device = makeRefactorTestDevice(
            id: "backend-state-pending-live-dpi-device",
            transport: .usb,
            serial: "BACKEND-STATE-PENDING-LIVE-DPI-\(UUID().uuidString)",
            onboardProfileCount: 1,
            profileID: .basiliskV3Pro
        )
        let appState = await MainActor.run {
            AppState(
                launchRole: .app,
                backend: AppStateRefactorStubBackend(devices: [], stateByDeviceID: [:]),
                autoStart: false
            )
        }

        let initialState = makeRefactorTestState(
            device: device,
            connection: "usb",
            batteryPercent: 81,
            dpiValues: [600, 900, 1000, 1200, 1400],
            activeStage: 1,
            dpiValue: 900,
            pollRate: 1000,
            sleepTimeout: 300
        )
        let liveState = makeRefactorTestState(
            device: device,
            connection: "usb",
            batteryPercent: 81,
            dpiValues: [600, 900, 1000, 1200, 1400],
            activeStage: 3,
            dpiValue: 1200,
            pollRate: 1000,
            sleepTimeout: 300
        )

        await MainActor.run {
            _ = appState.deviceController.applyDeviceList([device], source: "refresh")
            appState.deviceController.applyBackendDeviceStateUpdate(
                deviceID: device.id,
                state: initialState,
                updatedAt: Date(timeIntervalSince1970: 1_777_909_780)
            )
            appState.editorStore.editablePollRate = 500
            appState.applyController.markLocalEditsPending()
            appState.deviceController.applyBackendDeviceStateUpdate(
                deviceID: device.id,
                state: liveState,
                updatedAt: Date(timeIntervalSince1970: 1_777_909_781)
            )
        }

        let liveActiveStage = await MainActor.run { appState.editorStore.editableActiveStage }
        let editablePollRate = await MainActor.run { appState.editorStore.editablePollRate }

        XCTAssertEqual(liveActiveStage, 4)
        XCTAssertEqual(editablePollRate, 500)
    }

    func testUSBLightingZoneSwitchLoadsPersistedZoneSpecificColor() async throws {
        let device = makeRefactorMultiZoneUSBLightingDevice(
            id: "usb-zone-switch-lighting-device",
            serial: "USB-ZONE-SWITCH-\(UUID().uuidString)"
        )
        let wheelColor = RGBColor(r: 40, g: 50, b: 60)
        let logoColor = RGBColor(r: 70, g: 80, b: 90)
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistLightingColor(wheelColor, device: device, zoneID: "scroll_wheel")
        preferenceStore.persistLightingColor(logoColor, device: device, zoneID: "logo")
        preferenceStore.persistLightingZoneID("scroll_wheel", device: device)
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(devices: [], stateByDeviceID: [:])
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await MainActor.run {
            _ = appState.deviceController.applyDeviceList([device], source: "refresh")
        }

        let initialColor = await MainActor.run { appState.editorStore.editableColor }
        let initialZone = await MainActor.run { appState.editorStore.editableUSBLightingZoneID }
        XCTAssertEqual(initialZone, "scroll_wheel")
        XCTAssertEqual(initialColor, wheelColor)

        await MainActor.run {
            appState.editorStore.updateUSBLightingZoneID("logo")
        }

        let selectedZoneColor = await MainActor.run { appState.editorStore.editableColor }
        let selectedZone = await MainActor.run { appState.editorStore.editableUSBLightingZoneID }
        let applyCount = await backend.applyCount()

        XCTAssertEqual(selectedZone, "logo")
        XCTAssertEqual(selectedZoneColor, logoColor)
        XCTAssertEqual(applyCount, 0)
    }

    func testLightingGradientUsesActualZoneColorsInVisibleOrder() async throws {
        let device = makeRefactorMultiZoneUSBLightingDevice(
            id: "usb-lighting-gradient-zones-device",
            serial: "USB-GRADIENT-ZONES-\(UUID().uuidString)"
        )
        let wheelColor = RGBColor(r: 255, g: 0, b: 0)
        let logoColor = RGBColor(r: 0, g: 255, b: 0)
        let underglowColor = RGBColor(r: 0, g: 0, b: 255)
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistLightingColor(wheelColor, device: device, zoneID: "scroll_wheel")
        preferenceStore.persistLightingColor(RGBColor(r: 12, g: 34, b: 56), device: device, zoneID: "logo")
        preferenceStore.persistLightingColor(underglowColor, device: device, zoneID: "underglow")
        preferenceStore.persistLightingZoneID("scroll_wheel", device: device)
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(devices: [], stateByDeviceID: [:])
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await MainActor.run {
            _ = appState.deviceController.applyDeviceList([device], source: "refresh")
            appState.editorStore.updateUSBLightingZoneID("logo")
            appState.editorStore.editableColor = logoColor
        }

        let gradientColors = await MainActor.run { appState.editorStore.lightingGradientDisplayColors }

        XCTAssertEqual(gradientColors, [wheelColor, logoColor, underglowColor])
    }

    func testLightingGradientUsesPersistedZoneColorsWhenEditingAllZones() async throws {
        let device = makeRefactorMultiZoneUSBLightingDevice(
            id: "usb-lighting-gradient-all-zones-device",
            serial: "USB-GRADIENT-ALL-\(UUID().uuidString)"
        )
        let globalColor = RGBColor(r: 80, g: 90, b: 100)
        let wheelColor = RGBColor(r: 255, g: 0, b: 0)
        let logoColor = RGBColor(r: 0, g: 255, b: 0)
        let underglowColor = RGBColor(r: 0, g: 0, b: 255)
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistLightingColor(globalColor, device: device)
        preferenceStore.persistLightingColor(wheelColor, device: device, zoneID: "scroll_wheel")
        preferenceStore.persistLightingColor(logoColor, device: device, zoneID: "logo")
        preferenceStore.persistLightingColor(underglowColor, device: device, zoneID: "underglow")
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(devices: [], stateByDeviceID: [:])
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await MainActor.run {
            _ = appState.deviceController.applyDeviceList([device], source: "refresh")
            appState.editorStore.editableUSBLightingZoneID = "all"
            appState.editorStore.editableColor = globalColor
        }

        let gradientColors = await MainActor.run { appState.editorStore.lightingGradientDisplayColors }

        XCTAssertEqual(gradientColors, [wheelColor, logoColor, underglowColor])
    }

    func testUSBStaticMultiZonePresentationDoesNotLeaveEditorOnAllZones() async throws {
        let device = makeRefactorMultiZoneUSBLightingDevice(
            id: "usb-multizone-static-presentation-device",
            serial: "USB-MULTIZONE-\(UUID().uuidString)"
        )
        let globalColor = RGBColor(r: 10, g: 20, b: 30)
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistLightingColor(globalColor, device: device)
        preferenceStore.persistLightingZoneID("all", device: device)
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(devices: [], stateByDeviceID: [:])
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await MainActor.run {
            _ = appState.deviceController.applyDeviceList([device], source: "refresh")
        }

        let editableZone = await MainActor.run { appState.editorStore.editableUSBLightingZoneID }
        let editableColor = await MainActor.run { appState.editorStore.editableColor }

        XCTAssertEqual(editableZone, "scroll_wheel")
        XCTAssertEqual(editableColor, globalColor)
    }

    func testApplyCurrentStaticColorToAllZonesWritesGlobalPatchAndPersistsEveryZone() async throws {
        let device = makeRefactorMultiZoneUSBLightingDevice(
            id: "usb-apply-all-zones-device",
            serial: "USB-APPLY-ALL-\(UUID().uuidString)"
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 79,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600,
                    pollRate: 1000,
                    sleepTimeout: 300
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.updateUSBLightingZoneID("logo")
            appState.editorStore.editableColor = RGBColor(r: 111, g: 122, b: 133)
        }
        let gradientRevisionBeforeApply = await MainActor.run { appState.editorStore.lightingGradientRevision }

        await appState.editorStore.applyCurrentStaticColorToAllZones()

        try await waitForRefactorCondition {
            await backend.applyCount() == 1
        }

        let patches = await backend.recordedPatches()
        let patch = try XCTUnwrap(patches.first)
        let editableZone = await MainActor.run { appState.editorStore.editableUSBLightingZoneID }
        let gradientRevisionAfterApply = await MainActor.run { appState.editorStore.lightingGradientRevision }
        let preferenceStore = DevicePreferenceStore()
        let expectedColor = RGBColor(r: 111, g: 122, b: 133)

        XCTAssertEqual(patch.lightingEffect?.kind, .staticColor)
        XCTAssertNil(patch.usbLightingZoneLEDIDs)
        XCTAssertEqual(editableZone, "logo")
        XCTAssertGreaterThan(gradientRevisionAfterApply, gradientRevisionBeforeApply)
        XCTAssertEqual(preferenceStore.loadPersistedLightingZoneID(device: device), "logo")
        XCTAssertEqual(preferenceStore.loadPersistedLightingColor(device: device), expectedColor)
        XCTAssertEqual(preferenceStore.loadPersistedLightingColor(device: device, zoneID: "scroll_wheel"), expectedColor)
        XCTAssertEqual(preferenceStore.loadPersistedLightingColor(device: device, zoneID: "logo"), expectedColor)
        XCTAssertEqual(preferenceStore.loadPersistedLightingColor(device: device, zoneID: "underglow"), expectedColor)
    }

    func testUSBPersistedSettingsEffectReappliesOnFirstHydration() async throws {
        let device = makeRefactorUSBLightingRestoreDevice(
            id: "usb-effect-device",
            serial: "USB-EFFECT-\(UUID().uuidString)"
        )
        let persistedColor = RGBColor(r: 70, g: 80, b: 90)
        let persistedEffect = LightingEffectPatch(
            kind: .wave,
            primary: RGBPatch(r: persistedColor.r, g: persistedColor.g, b: persistedColor.b),
            secondary: RGBPatch(r: 1, g: 2, b: 3),
            waveDirection: .right,
            reactiveSpeed: 4
        )
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistConnectBehavior(.restoreOpenSnekSettings, device: device)
        preferenceStore.persistDeviceSettingsSnapshot(
            makeRefactorSettingsSnapshot(
                color: persistedColor,
                zoneID: "logo",
                lightingEffect: persistedEffect
            ),
            device: device
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 71,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600,
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
            await backend.applyCount() >= 1
        }

        let patches = await backend.recordedPatches()
        let patch = try XCTUnwrap(patches.first(where: { $0.lightingEffect != nil }))
        let effect = try XCTUnwrap(patch.lightingEffect)

        XCTAssertNil(patch.ledRGB)
        XCTAssertEqual(effect.kind, .wave)
        XCTAssertEqual(effect.primary.r, persistedColor.r)
        XCTAssertEqual(effect.primary.g, persistedColor.g)
        XCTAssertEqual(effect.primary.b, persistedColor.b)
        XCTAssertEqual(effect.secondary.r, 1)
        XCTAssertEqual(effect.secondary.g, 2)
        XCTAssertEqual(effect.secondary.b, 3)
        XCTAssertEqual(effect.waveDirection, .right)
        XCTAssertEqual(effect.reactiveSpeed, 4)
        XCTAssertNil(patch.usbLightingZoneLEDIDs)
    }

    func testMissingPersistedLightingDoesNotAutoApply() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-no-lighting",
            transport: .usb,
            serial: "USB-NO-LIGHT-\(UUID().uuidString)",
            onboardProfileCount: 1
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 75,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600,
                    pollRate: 1000,
                    sleepTimeout: 300
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        let applyCount = await backend.applyCount()
        XCTAssertEqual(applyCount, 0)
    }

    func testUSBRefreshDoesNotApplyPersistedButtonBindingsWithoutUserAction() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-no-auto-button-apply",
            transport: .usb,
            serial: "USB-NO-AUTO-\(UUID().uuidString)",
            onboardProfileCount: 1
        )
        let preferenceStore = DevicePreferenceStore()
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
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        let applyCount = await backend.applyCount()
        let binding = await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) }
        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(binding, .default)
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

    func testUSBWheelTiltDefaultHydrationUsesDefaultPickerSelection() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-tilt-default-device",
            transport: .usb,
            serial: "USB-TILT-\(UUID().uuidString)",
            onboardProfileCount: 1
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 81,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600,
                    pollRate: 1000,
                    sleepTimeout: 300
                )
            ]
        )
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 52, profileID: .basiliskV3Pro)),
            forDeviceID: device.id,
            slot: 52,
            profile: 1
        )
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 52, profileID: .basiliskV3Pro)),
            forDeviceID: device.id,
            slot: 52,
            profile: 0
        )

        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        try await waitForRefactorCondition {
            await MainActor.run { appState.editorStore.buttonBindingKind(for: 52) == .default }
        }

        let binding = await MainActor.run { appState.editorStore.buttonBindingKind(for: 52) }
        XCTAssertEqual(binding, .default)
    }

    func testUSBButtonHydrationIgnoresPlaceholderSerialCacheWhenReadbackIsUnavailable() async throws {
        struct LegacyPersistedBinding: Codable {
            let kindRaw: String
            let hidKey: Int
            let turboEnabled: Bool
            let turboRate: Int
        }

        let device = makeRefactorTestDevice(
            id: "usb-zero-serial-device",
            transport: .usb,
            serial: "000000000000",
            onboardProfileCount: 2
        )
        let defaults = UserDefaults.standard
        let legacyKey = "buttonBindings.serial:000000000000.profile2"
        let currentKey = "buttonBindings.\(DevicePersistenceKeys.key(for: device)).profile2"
        let previousLegacyData = defaults.data(forKey: legacyKey)
        let previousCurrentData = defaults.data(forKey: currentKey)
        let staleBindings = [
            "4": LegacyPersistedBinding(
                kindRaw: ButtonBindingKind.rightClick.rawValue,
                hidKey: 4,
                turboEnabled: false,
                turboRate: 0x8E
            )
        ]
        defaults.set(try JSONEncoder().encode(staleBindings), forKey: legacyKey)
        defaults.removeObject(forKey: currentKey)
        defer {
            if let previousLegacyData {
                defaults.set(previousLegacyData, forKey: legacyKey)
            } else {
                defaults.removeObject(forKey: legacyKey)
            }
            if let previousCurrentData {
                defaults.set(previousCurrentData, forKey: currentKey)
            } else {
                defaults.removeObject(forKey: currentKey)
            }
        }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 76,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 2,
                    onboardProfileCount: 2
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        let selectedProfile = await MainActor.run { appState.editorStore.editableUSBButtonProfile }
        let binding = await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) }

        XCTAssertEqual(selectedProfile, 2)
        XCTAssertEqual(binding, .default)
    }

    func testSwitchingUSBButtonProfileInvalidatesHydrationCache() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-device",
            transport: .usb,
            serial: "USB-PROFILE-\(UUID().uuidString)",
            onboardProfileCount: 2
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
        await backend.setButtonBindingBlock(
            ButtonBindingSupport.buildUSBFunctionBlock(
                slot: 4,
                kind: .leftClick,
                hidKey: 4,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil,
                profileID: .basiliskV3Pro
            ),
            forDeviceID: device.id,
            slot: 4,
            profile: 1
        )
        await backend.setButtonBindingBlock(
            ButtonBindingSupport.buildUSBFunctionBlock(
                slot: 4,
                kind: .leftClick,
                hidKey: 4,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil,
                profileID: .basiliskV3Pro
            ),
            forDeviceID: device.id,
            slot: 4,
            profile: 0
        )
        await backend.setButtonBindingBlock(
            ButtonBindingSupport.buildUSBFunctionBlock(
                slot: 4,
                kind: .rightClick,
                hidKey: 4,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil,
                profileID: .basiliskV3Pro
            ),
            forDeviceID: device.id,
            slot: 4,
            profile: 2
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

    func testUSBButtonProfileSummariesReflectDefaultAndCustomSlots() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-summary-device",
            transport: .usb,
            serial: "USB-PROFILE-SUMMARY-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 80,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: .basiliskV3Pro)),
            forDeviceID: device.id,
            slot: 4,
            profile: 1
        )
        await backend.setButtonBindingBlock(
            ButtonBindingSupport.buildUSBFunctionBlock(
                slot: 4,
                kind: .rightClick,
                hidKey: 4,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil,
                profileID: .basiliskV3Pro
            ),
            forDeviceID: device.id,
            slot: 4,
            profile: 2
        )
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: .basiliskV3Pro)),
            forDeviceID: device.id,
            slot: 4,
            profile: 3
        )

        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.refreshButtonProfilePresentation()
        }

        try await waitForRefactorCondition(timeout: 2.0) {
            await MainActor.run {
                let summaries = appState.editorStore.visibleUSBButtonProfiles
                guard summaries.count == 3 else { return false }
                return summaries.first(where: { $0.profile == 2 })?.isCustomized == true &&
                    summaries.first(where: { $0.profile == 3 })?.isCustomized == false
            }
        }

        let summaries = await MainActor.run { appState.editorStore.visibleUSBButtonProfiles }
        XCTAssertEqual(summaries.map(\.profile), [1, 2, 3])
        XCTAssertEqual(summaries.first(where: { $0.profile == 1 })?.isCustomized, false)
        XCTAssertEqual(summaries.first(where: { $0.profile == 2 })?.isCustomized, true)
        XCTAssertEqual(summaries.first(where: { $0.profile == 3 })?.isCustomized, false)
    }

    func testDuplicateSelectedUSBButtonProfileEnqueuesProfileActionAndSelectsTarget() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-duplicate-device",
            transport: .usb,
            serial: "USB-PROFILE-DUPLICATE-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 79,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        await backend.setButtonBindingBlock(
            ButtonBindingSupport.buildUSBFunctionBlock(
                slot: 4,
                kind: .rightClick,
                hidKey: 4,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil,
                profileID: .basiliskV3Pro
            ),
            forDeviceID: device.id,
            slot: 4,
            profile: 1
        )
        await backend.setButtonBindingBlock(
            ButtonBindingSupport.buildUSBFunctionBlock(
                slot: 4,
                kind: .rightClick,
                hidKey: 4,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil,
                profileID: .basiliskV3Pro
            ),
            forDeviceID: device.id,
            slot: 4,
            profile: 0
        )
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: .basiliskV3Pro)),
            forDeviceID: device.id,
            slot: 4,
            profile: 2
        )
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: .basiliskV3Pro)),
            forDeviceID: device.id,
            slot: 4,
            profile: 3
        )

        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        try await waitForRefactorCondition(timeout: 2.0) {
            await MainActor.run { appState.editorStore.canDuplicateSelectedUSBButtonProfile }
        }

        await appState.editorStore.duplicateSelectedUSBButtonProfile()

        let patches = await backend.recordedPatches()
        let selectedProfile = await MainActor.run { appState.editorStore.editableUSBButtonProfile }
        let duplicatedBinding = await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) }

        XCTAssertEqual(patches.last?.usbButtonProfileAction?.kind, .duplicateToPersistentSlot)
        XCTAssertEqual(patches.last?.usbButtonProfileAction?.sourceProfile, 1)
        XCTAssertEqual(patches.last?.usbButtonProfileAction?.targetProfile, 2)
        XCTAssertEqual(selectedProfile, 2)
        XCTAssertEqual(duplicatedBinding, .rightClick)
    }

    func testResetSelectedUSBButtonProfileEnqueuesResetActionAndClearsCachedBindings() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-reset-device",
            transport: .usb,
            serial: "USB-PROFILE-RESET-\(UUID().uuidString)",
            onboardProfileCount: 2
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 78,
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
        await backend.setButtonBindingBlock(
            ButtonBindingSupport.buildUSBFunctionBlock(
                slot: 4,
                kind: .rightClick,
                hidKey: 4,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil,
                profileID: .basiliskV3Pro
            ),
            forDeviceID: device.id,
            slot: 4,
            profile: 2
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.updateUSBButtonProfile(2)
        }

        try await waitForRefactorCondition {
            await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) == .rightClick }
        }

        await appState.editorStore.resetSelectedUSBButtonProfile()

        let patches = await backend.recordedPatches()
        let binding = await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) }
        let expectedDefaultKind = ButtonBindingSupport.defaultButtonBinding(for: 4, profileID: device.profile_id).kind

        XCTAssertEqual(patches.last?.usbButtonProfileAction?.kind, .resetPersistentSlot)
        XCTAssertEqual(patches.last?.usbButtonProfileAction?.targetProfile, 2)
        XCTAssertEqual(binding, expectedDefaultKind)
    }

    func testProjectSelectedUSBButtonProfileToDirectLayerEnqueuesProjectAction() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-project-device",
            transport: .usb,
            serial: "USB-PROFILE-PROJECT-\(UUID().uuidString)",
            onboardProfileCount: 2
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 82,
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
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: .basiliskV3Pro)),
            forDeviceID: device.id,
            slot: 4,
            profile: 2
        )

        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.updateUSBButtonProfile(2)
        }

        await appState.editorStore.projectSelectedUSBButtonProfileToDirectLayer()

        let patches = await backend.recordedPatches()
        XCTAssertEqual(patches.last?.usbButtonProfileAction?.kind, .projectToDirectLayer)
        XCTAssertEqual(patches.last?.usbButtonProfileAction?.targetProfile, 2)
    }

    func testLoadingStoredUSBButtonProfileOverwritesBaseProfile() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-load-device",
            transport: .usb,
            serial: "USB-PROFILE-LOAD-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 82,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        await backend.setButtonBindingBlock(
            ButtonBindingSupport.buildUSBFunctionBlock(
                slot: 4,
                kind: .keyboardSimple,
                hidKey: 9,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil,
                profileID: .basiliskV3Pro
            ),
            forDeviceID: device.id,
            slot: 4,
            profile: 2
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await appState.editorStore.loadButtonProfileSourceIntoLive(.mouseSlot(2))

        let patches = await backend.recordedPatches()
        let slotPatch = try XCTUnwrap(patches.last(where: { $0.buttonBinding?.slot == 4 }))
        XCTAssertEqual(slotPatch.buttonBinding?.persistentProfile, 1)
        XCTAssertEqual(slotPatch.buttonBinding?.writePersistentLayer, true)
        XCTAssertEqual(slotPatch.buttonBinding?.writeDirectLayer, true)
        XCTAssertEqual(slotPatch.buttonBinding?.kind, .keyboardSimple)
    }

    func testReloadingKnownStoredUSBButtonProfileSkipsExtraDeviceReadback() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-reload-device",
            transport: .usb,
            serial: "USB-PROFILE-RELOAD-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 82,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        await backend.setButtonBindingBlock(
            ButtonBindingSupport.buildUSBFunctionBlock(
                slot: 4,
                kind: .keyboardSimple,
                hidKey: 9,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil,
                profileID: .basiliskV3Pro
            ),
            forDeviceID: device.id,
            slot: 4,
            profile: 2
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await appState.editorStore.loadButtonProfileSourceIntoLive(.mouseSlot(2))
        try await Task.sleep(nanoseconds: 120_000_000)

        let readsAfterFirstLoad = await backend.buttonReadCount(for: device.id)

        await appState.editorStore.loadButtonProfileSourceIntoLive(.mouseSlot(2))
        try await Task.sleep(nanoseconds: 120_000_000)

        let readsAfterSecondLoad = await backend.buttonReadCount(for: device.id)
        XCTAssertEqual(readsAfterSecondLoad, readsAfterFirstLoad)
    }

    func testStoredUSBButtonProfileDisplaysMatchingSavedProfileName() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-match-device",
            transport: .usb,
            serial: "USB-PROFILE-MATCH-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        let preferenceStore = DevicePreferenceStore()
        let matchingBindings = [
            4: ButtonBindingDraft(
                kind: .keyboardSimple,
                hidKey: 9,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil
            )
        ]
        preferenceStore.saveOpenSnekButtonProfile(name: "Travel", bindings: matchingBindings)
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 82,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        await backend.setButtonBindingBlock(
            ButtonBindingSupport.buildUSBFunctionBlock(
                slot: 4,
                kind: .keyboardSimple,
                hidKey: 9,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil,
                profileID: .basiliskV3Pro
            ),
            forDeviceID: device.id,
            slot: 4,
            profile: 2
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.refreshButtonProfilePresentation()
        }

        try await waitForRefactorCondition(timeout: 2.0) {
            await MainActor.run {
                appState.editorStore.buttonProfileSourceMatchDescription(.mouseSlot(2)) == "Travel"
            }
        }
    }

    func testLoadableMouseButtonSourcesHideDefaultStoredSlots() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-loadable-device",
            transport: .usb,
            serial: "USB-PROFILE-LOADABLE-\(UUID().uuidString)",
            onboardProfileCount: 4
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 82,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 4
                )
            ]
        )
        await backend.setButtonBindingBlock(
            ButtonBindingSupport.buildUSBFunctionBlock(
                slot: 4,
                kind: .keyboardSimple,
                hidKey: 9,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil,
                profileID: .basiliskV3Pro
            ),
            forDeviceID: device.id,
            slot: 4,
            profile: 2
        )
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: .basiliskV3Pro)),
            forDeviceID: device.id,
            slot: 4,
            profile: 3
        )
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: .basiliskV3Pro)),
            forDeviceID: device.id,
            slot: 4,
            profile: 4
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.refreshButtonProfilePresentation()
        }

        try await waitForRefactorCondition(timeout: 2.0) {
            await MainActor.run {
                let summaries = appState.editorStore.visibleUSBButtonProfiles
                guard summaries.count == 4 else { return false }
                return summaries.first(where: { $0.profile == 2 })?.isCustomized == true &&
                    summaries.first(where: { $0.profile == 3 })?.isCustomized == false &&
                    summaries.first(where: { $0.profile == 4 })?.isCustomized == false
            }
        }

        let loadableSlots = await MainActor.run {
            appState.editorStore.loadableMouseButtonSources.compactMap { source -> Int? in
                guard case .mouseSlot(let slot) = source else { return nil }
                return slot
            }
        }
        let writableSlots = await MainActor.run {
            appState.editorStore.writableMouseButtonSources.compactMap { source -> Int? in
                guard case .mouseSlot(let slot) = source else { return nil }
                return slot
            }
        }
        XCTAssertEqual(loadableSlots, [1, 2])
        XCTAssertEqual(writableSlots, [2, 3, 4])
    }

    func testSavingCurrentButtonWorkspaceAsNewProfileUpdatesSavedLibraryImmediately() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-save-source-device",
            transport: .usb,
            serial: "USB-PROFILE-SAVE-SOURCE-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 82,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        await MainActor.run {
            _ = appState.editorStore.saveCurrentButtonWorkspaceAsNewProfile(name: "Bar")
        }

        let savedNames = await MainActor.run {
            appState.editorStore.savedButtonProfiles.map(\.name)
        }
        XCTAssertTrue(savedNames.contains("Bar"))
    }

    func testSavingSelectedUSBButtonProfileUsesExplicitButtonWriteWithoutActivation() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-save-device",
            transport: .usb,
            serial: "USB-PROFILE-SAVE-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 76,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: .basiliskV3Pro)),
            forDeviceID: device.id,
            slot: 4,
            profile: 2
        )

        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.updateUSBButtonProfile(2)
        }

        try await waitForRefactorCondition {
            await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) == .default }
        }

        await MainActor.run {
            appState.editorStore.updateButtonBindingKind(slot: 4, kind: .rightClick)
        }

        let hasUnsavedChanges = await MainActor.run { appState.editorStore.selectedUSBButtonProfileHasUnsavedChanges }
        XCTAssertTrue(hasUnsavedChanges)

        await appState.editorStore.saveSelectedUSBButtonProfile()

        let patches = await backend.recordedPatches()
        let patch = try XCTUnwrap(patches.last)
        XCTAssertEqual(patch.buttonBinding?.persistentProfile, 2)
        XCTAssertEqual(patch.buttonBinding?.kind, .rightClick)
        XCTAssertEqual(patch.buttonBinding?.writeDirectLayer, false)
        XCTAssertNil(patch.usbButtonProfileAction)

        try await waitForRefactorCondition(timeout: 2.0) {
            await MainActor.run { !appState.editorStore.selectedUSBButtonProfileHasUnsavedChanges }
        }

        let liveProfile = await MainActor.run { appState.editorStore.liveUSBButtonProfile }
        let pendingChanges = await MainActor.run { appState.editorStore.selectedUSBButtonProfileHasUnsavedChanges }
        XCTAssertEqual(liveProfile, 1)
        XCTAssertFalse(pendingChanges)
    }

    func testSaveAndActivateSelectedUSBButtonProfileProjectsLiveProfileOverride() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-save-activate-device",
            transport: .usb,
            serial: "USB-PROFILE-SAVE-ACTIVATE-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 76,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: .basiliskV3Pro)),
            forDeviceID: device.id,
            slot: 4,
            profile: 2
        )

        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.updateUSBButtonProfile(2)
        }

        try await waitForRefactorCondition {
            await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) == .default }
        }

        await MainActor.run {
            appState.editorStore.updateButtonBindingKind(slot: 4, kind: .rightClick)
        }

        await appState.editorStore.saveSelectedUSBButtonProfile(activateAfterSave: true)

        let patches = await backend.recordedPatches()
        let buttonPatch = try XCTUnwrap(patches.first(where: { $0.buttonBinding != nil }))
        let projectPatch = try XCTUnwrap(patches.last(where: { $0.usbButtonProfileAction?.kind == .projectToDirectLayer }))
        XCTAssertEqual(buttonPatch.buttonBinding?.persistentProfile, 2)
        XCTAssertEqual(buttonPatch.buttonBinding?.writeDirectLayer, false)
        XCTAssertEqual(projectPatch.usbButtonProfileAction?.targetProfile, 2)

        let liveProfile = await MainActor.run { appState.editorStore.liveUSBButtonProfile }
        let summaries = await MainActor.run { appState.editorStore.visibleUSBButtonProfiles }
        XCTAssertEqual(liveProfile, 2)
        XCTAssertEqual(summaries.first(where: { $0.profile == 2 })?.isLiveActive, true)
        XCTAssertEqual(summaries.first(where: { $0.profile == 1 })?.isHardwareActive, true)
    }

    func testEditingProjectedStoredUSBButtonProfileAutoAppliesToBaseAndDirectLayer() async throws {
        for (profileID, onboardProfileCount) in [
            (DeviceProfileID.basiliskV3, 5),
            (.basiliskV3Pro, 5),
            (.basiliskV335K, 5),
        ] {
            let device = makeRefactorTestDevice(
                id: "usb-profile-projected-auto-apply-\(profileID.rawValue)",
                transport: .usb,
                serial: "USB-PROFILE-PROJECTED-AUTO-\(profileID.rawValue)-\(UUID().uuidString)",
                onboardProfileCount: onboardProfileCount,
                profileID: profileID
            )
            defer { clearRefactorPreferences(for: device) }

            let backend = AppStateRefactorStubBackend(
                devices: [device],
                stateByDeviceID: [
                    device.id: makeRefactorTestState(
                        device: device,
                        connection: "usb",
                        batteryPercent: 76,
                        dpiValues: [800, 1600, 2400],
                        activeStage: 0,
                        dpiValue: 800,
                        pollRate: 1000,
                        sleepTimeout: 300,
                        activeOnboardProfile: 1,
                        onboardProfileCount: onboardProfileCount
                    )
                ]
            )
            await backend.setButtonBindingBlock(
                try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: profileID)),
                forDeviceID: device.id,
                slot: 4,
                profile: 2
            )

            let appState = await MainActor.run {
                AppState(launchRole: .app, backend: backend, autoStart: false)
            }

            await appState.deviceStore.refreshDevices()
            await MainActor.run {
                appState.editorStore.updateUSBButtonProfile(2)
            }

            try await waitForRefactorCondition {
                await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) == .default }
            }

            await appState.editorStore.projectSelectedUSBButtonProfileToDirectLayer()

            await MainActor.run {
                appState.editorStore.updateButtonBindingKind(slot: 4, kind: .rightClick)
            }

            try await waitForRefactorCondition(timeout: 2.0) {
                await backend.recordedPatches().contains(where: { patch in
                    patch.buttonBinding?.slot == 4 && patch.buttonBinding?.kind == .rightClick
                })
            }

            let patches = await backend.recordedPatches()
            let patch = try XCTUnwrap(
                patches.last(where: { $0.buttonBinding?.slot == 4 }),
                "Missing button patch for \(profileID.rawValue)"
            )
            XCTAssertEqual(
                patch.buttonBinding?.persistentProfile,
                1,
                "Projected USB edits should persist to base slot 1 for \(profileID.rawValue)"
            )
            XCTAssertEqual(patch.buttonBinding?.writePersistentLayer, true)
            XCTAssertEqual(patch.buttonBinding?.writeDirectLayer, true)
        }
    }

    func testEditingSavedButtonProfileStillAutoAppliesToBaseAndDirectLayer() async throws {
        let device = makeRefactorTestDevice(
            id: "saved-button-auto-apply-device",
            transport: .usb,
            serial: "SAVED-BUTTON-AUTO-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        let preferenceStore = DevicePreferenceStore()
        let saved = preferenceStore.saveOpenSnekButtonProfile(
            name: "Travel",
            bindings: [
                4: ButtonBindingDraft(kind: .rightClick, hidKey: 4, turboEnabled: false, turboRate: 0x8E, clutchDPI: nil)
            ]
        )
        defer {
            clearSavedButtonProfiles()
            clearRefactorPreferences(for: device)
        }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 74,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.updateUSBButtonProfile(2)
            appState.editorStore.selectButtonProfileSource(.openSnekProfile(saved.id))
            appState.editorStore.updateButtonBindingKind(slot: 4, kind: .mouseForward)
        }

        try await waitForRefactorCondition(timeout: 2.0) {
            await backend.recordedPatches().contains(where: { patch in
                patch.buttonBinding?.slot == 4 && patch.buttonBinding?.kind == .mouseForward
            })
        }

        let patches = await backend.recordedPatches()
        let patch = try XCTUnwrap(patches.last(where: { $0.buttonBinding?.slot == 4 }))
        XCTAssertEqual(patch.buttonBinding?.persistentProfile, 1)
        XCTAssertEqual(patch.buttonBinding?.writePersistentLayer, true)
        XCTAssertEqual(patch.buttonBinding?.writeDirectLayer, true)
    }

    func testEditingBaseProfileAutoAppliesToLiveAndPersistentSlotOne() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-base-auto-apply-device",
            transport: .usb,
            serial: "USB-PROFILE-BASE-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 76,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.updateButtonBindingKind(slot: 4, kind: .rightClick)
        }

        try await waitForRefactorCondition(timeout: 2.0) {
            await backend.recordedPatches().contains(where: { $0.buttonBinding?.slot == 4 })
        }

        try await waitForRefactorCondition(timeout: 2.0) {
            await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) == .rightClick }
        }

        let patches = await backend.recordedPatches()
        let patch = try XCTUnwrap(patches.last(where: { $0.buttonBinding?.slot == 4 }))
        let binding = await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) }
        XCTAssertEqual(patch.buttonBinding?.persistentProfile, 1)
        XCTAssertEqual(patch.buttonBinding?.writePersistentLayer, true)
        XCTAssertEqual(patch.buttonBinding?.writeDirectLayer, true)
        XCTAssertEqual(binding, .rightClick)
        XCTAssertEqual(patches.compactMap(\.buttonBinding).map(\.slot), [4])
    }

    func testDefaultDPIButtonAppliesAsDPICycleOn35K() async throws {
        let device = MouseDevice(
            id: "usb-35k-default-dpi-cycle-device",
            vendor_id: 0x1532,
            product_id: 0x00CB,
            product_name: "Basilisk V3 35K",
            transport: .usb,
            path_b64: "",
            serial: "USB-35K-DPI-\(UUID().uuidString)",
            firmware: "1.0.0",
            location_id: 1,
            profile_id: .basiliskV335K,
            supports_advanced_lighting_effects: true,
            onboard_profile_count: 5
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 76,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 5
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.updateButtonBindingKind(slot: 96, kind: .default)
        }

        try await waitForRefactorCondition(timeout: 2.0) {
            await backend.recordedPatches().contains(where: {
                $0.buttonBinding?.slot == 96 && $0.buttonBinding?.kind == .dpiCycle
            })
        }

        let patches = await backend.recordedPatches()
        let patch = try XCTUnwrap(patches.last(where: { $0.buttonBinding?.slot == 96 }))
        let selectedKind = await MainActor.run { appState.editorStore.buttonBindingKind(for: 96) }
        XCTAssertEqual(patch.buttonBinding?.kind, .dpiCycle)
        XCTAssertEqual(patch.buttonBinding?.persistentProfile, 1)
        XCTAssertEqual(patch.buttonBinding?.writePersistentLayer, true)
        XCTAssertEqual(patch.buttonBinding?.writeDirectLayer, true)
        XCTAssertEqual(selectedKind, .default)
    }

    func testSwitchingUSBDevicesDoesNotPreserveUnsavedButtonWorkspaceAcrossDevices() async throws {
        let firstDevice = makeRefactorTestDevice(
            id: "usb-workspace-a",
            transport: .usb,
            serial: "USB-WORKSPACE-A-\(UUID().uuidString)",
            onboardProfileCount: 5
        )
        let secondDevice = makeRefactorTestDevice(
            id: "usb-workspace-b",
            transport: .usb,
            serial: "USB-WORKSPACE-B-\(UUID().uuidString)",
            onboardProfileCount: 5
        )
        defer {
            clearRefactorPreferences(for: firstDevice)
            clearRefactorPreferences(for: secondDevice)
        }

        let backend = AppStateRefactorStubBackend(
            devices: [firstDevice, secondDevice],
            stateByDeviceID: [
                firstDevice.id: makeRefactorTestState(
                    device: firstDevice,
                    connection: "usb",
                    batteryPercent: 76,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 5
                ),
                secondDevice.id: makeRefactorTestState(
                    device: secondDevice,
                    connection: "usb",
                    batteryPercent: 81,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 5
                )
            ]
        )

        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: .basiliskV3Pro)),
            forDeviceID: firstDevice.id,
            slot: 4,
            profile: 1
        )
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: .basiliskV3Pro)),
            forDeviceID: firstDevice.id,
            slot: 4,
            profile: 0
        )
        await backend.setButtonBindingBlock(
            [0x02, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00],
            forDeviceID: secondDevice.id,
            slot: 4,
            profile: 1
        )
        await backend.setButtonBindingBlock(
            [0x02, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00],
            forDeviceID: secondDevice.id,
            slot: 4,
            profile: 0
        )

        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.deviceStore.selectDevice(firstDevice.id)
        }

        await MainActor.run {
            appState.editorStore.updateButtonBindingKind(slot: 4, kind: .rightClick)
            appState.deviceStore.selectDevice(secondDevice.id)
        }

        try await waitForRefactorCondition(timeout: 2.0) {
            await MainActor.run {
                appState.editorStore.buttonBindingKind(for: 4) == .keyboardSimple &&
                    appState.editorStore.buttonBindingHidKey(for: 4) == 4
            }
        }

        let bindingKind = await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) }
        let hidKey = await MainActor.run { appState.editorStore.buttonBindingHidKey(for: 4) }

        XCTAssertEqual(bindingKind, .keyboardSimple)
        XCTAssertEqual(hidKey, 4)
    }

    func testEditingMouseTurboBindingAutoAppliesToBaseProfile() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-mouse-turbo-device",
            transport: .usb,
            serial: "USB-PROFILE-MOUSE-TURBO-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        defer { clearRefactorPreferences(for: device) }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 79,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        let expectedRate = ButtonBindingSupport.turboPressesPerSecondToRaw(7)

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.updateButtonBindingKind(slot: 4, kind: .rightClick)
            appState.editorStore.updateButtonBindingTurboEnabled(slot: 4, enabled: true)
            appState.editorStore.updateButtonBindingTurboPressesPerSecond(slot: 4, pressesPerSecond: 7)
        }

        try await waitForRefactorCondition(timeout: 2.0) {
            await backend.recordedPatches().contains(where: {
                $0.buttonBinding?.slot == 4 &&
                    $0.buttonBinding?.kind == .rightClick &&
                    $0.buttonBinding?.turboEnabled == true
            })
        }

        let patches = await backend.recordedPatches()
        let patch = try XCTUnwrap(patches.last(where: { $0.buttonBinding?.slot == 4 }))
        let turboEnabled = await MainActor.run { appState.editorStore.buttonBindingTurboEnabled(for: 4) }
        let kind = await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) }

        XCTAssertEqual(kind, .rightClick)
        XCTAssertTrue(turboEnabled)
        XCTAssertEqual(patch.buttonBinding?.kind, .rightClick)
        XCTAssertEqual(patch.buttonBinding?.turboEnabled, true)
        XCTAssertEqual(patch.buttonBinding?.turboRate, expectedRate)
        XCTAssertEqual(patch.buttonBinding?.persistentProfile, 1)
        XCTAssertEqual(patch.buttonBinding?.writePersistentLayer, true)
        XCTAssertEqual(patch.buttonBinding?.writeDirectLayer, true)
    }

    func testLoadingButtonProfileIntoLiveMarksProfileOperationBusyUntilApplyFinishes() async throws {
        let device = makeRefactorTestDevice(
            id: "usb-profile-load-busy-device",
            transport: .usb,
            serial: "USB-PROFILE-LOAD-BUSY-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        let preferenceStore = DevicePreferenceStore()
        let saved = preferenceStore.saveOpenSnekButtonProfile(
            name: "Travel",
            bindings: [
                4: ButtonBindingDraft(kind: .rightClick, hidKey: 4, turboEnabled: false, turboRate: 0x8E, clutchDPI: nil)
            ]
        )
        defer {
            clearSavedButtonProfiles()
            clearRefactorPreferences(for: device)
        }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 82,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ],
            holdFirstApply: true
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        let loadTask = Task {
            await appState.editorStore.loadButtonProfileSourceIntoLive(.openSnekProfile(saved.id))
        }

        await backend.waitForFirstApplyToStart()

        let busyDuringApply = await MainActor.run { appState.editorStore.isButtonProfileOperationInFlight }
        XCTAssertTrue(busyDuringApply)

        await MainActor.run { XCTAssertEqual(appState.editorStore.buttonBindingKind(for: 4), .rightClick) }

        await backend.releaseFirstApply()
        await loadTask.value

        try await waitForRefactorCondition(timeout: 2.0) {
            await MainActor.run { !appState.editorStore.isButtonProfileOperationInFlight }
        }
    }

    func testSelectingSavedButtonProfileHydratesWorkingCopy() async throws {
        let device = makeRefactorTestDevice(
            id: "saved-button-profile-device",
            transport: .usb,
            serial: "SAVED-BUTTON-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        let preferenceStore = DevicePreferenceStore()
        let saved = preferenceStore.saveOpenSnekButtonProfile(
            name: "Travel",
            bindings: [
                4: ButtonBindingDraft(kind: .rightClick, hidKey: 4, turboEnabled: false, turboRate: 0x8E, clutchDPI: nil)
            ]
        )
        defer {
            clearSavedButtonProfiles()
            clearRefactorPreferences(for: device)
        }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 84,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.selectButtonProfileSource(.openSnekProfile(saved.id))
        }

        let binding = await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) }
        let displayName = await MainActor.run { appState.editorStore.currentButtonProfileDisplayName }
        XCTAssertEqual(binding, .rightClick)
        XCTAssertEqual(displayName, "Travel")
    }

    func testApplyCurrentButtonWorkspaceToLiveWritesBaseProfileWithoutOverwritingSavedProfileSource() async throws {
        let device = makeRefactorTestDevice(
            id: "saved-button-apply-device",
            transport: .usb,
            serial: "SAVED-APPLY-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        let preferenceStore = DevicePreferenceStore()
        let saved = preferenceStore.saveOpenSnekButtonProfile(
            name: "Travel",
            bindings: [
                4: ButtonBindingDraft(kind: .rightClick, hidKey: 4, turboEnabled: false, turboRate: 0x8E, clutchDPI: nil)
            ]
        )
        defer {
            clearSavedButtonProfiles()
            clearRefactorPreferences(for: device)
        }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 74,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.selectButtonProfileSource(.openSnekProfile(saved.id))
        }
        await appState.editorStore.applyCurrentButtonWorkspaceToLive()

        let patches = await backend.recordedPatches()
        let slotPatch = try XCTUnwrap(patches.last(where: { $0.buttonBinding?.slot == 4 }))
        let liveDisplayName = await MainActor.run { appState.editorStore.liveButtonProfileDisplayName }
        let currentSource = await MainActor.run { appState.editorStore.currentButtonProfileSource }

        XCTAssertEqual(slotPatch.buttonBinding?.kind, .rightClick)
        XCTAssertEqual(slotPatch.buttonBinding?.persistentProfile, 1)
        XCTAssertEqual(slotPatch.buttonBinding?.writePersistentLayer, true)
        XCTAssertEqual(slotPatch.buttonBinding?.writeDirectLayer, true)
        XCTAssertEqual(currentSource, .openSnekProfile(saved.id))
        XCTAssertEqual(liveDisplayName, "Travel")
    }

    func testWriteCurrentButtonWorkspaceToMouseSlotPersistsWithoutChangingCurrentSource() async throws {
        let device = makeRefactorTestDevice(
            id: "saved-button-write-slot-device",
            transport: .usb,
            serial: "SAVED-WRITE-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        let preferenceStore = DevicePreferenceStore()
        let saved = preferenceStore.saveOpenSnekButtonProfile(
            name: "Travel",
            bindings: [
                4: ButtonBindingDraft(kind: .rightClick, hidKey: 4, turboEnabled: false, turboRate: 0x8E, clutchDPI: nil)
            ]
        )
        defer {
            clearSavedButtonProfiles()
            clearRefactorPreferences(for: device)
        }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 74,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.selectButtonProfileSource(.openSnekProfile(saved.id))
        }
        await appState.editorStore.writeCurrentButtonWorkspaceToMouseSlot(2)

        let patches = await backend.recordedPatches()
        let slotPatch = try XCTUnwrap(patches.last(where: { $0.buttonBinding?.slot == 4 }))
        let currentSource = await MainActor.run { appState.editorStore.currentButtonProfileSource }

        XCTAssertEqual(slotPatch.buttonBinding?.kind, .rightClick)
        XCTAssertEqual(slotPatch.buttonBinding?.persistentProfile, 2)
        XCTAssertEqual(slotPatch.buttonBinding?.writePersistentLayer, true)
        XCTAssertEqual(slotPatch.buttonBinding?.writeDirectLayer, false)
        XCTAssertEqual(currentSource, .openSnekProfile(saved.id))

        await MainActor.run {
            appState.editorStore.selectButtonProfileSource(.mouseSlot(2))
        }

        try await waitForRefactorCondition {
            await MainActor.run { appState.editorStore.buttonBindingKind(for: 4) == .rightClick }
        }
    }

    func testSelectingNextOnboardButtonProfileFollowsVisibleSlotOrder() async throws {
        let device = makeRefactorTestDevice(
            id: "saved-button-next-slot-device",
            transport: .usb,
            serial: "SAVED-NEXT-\(UUID().uuidString)",
            onboardProfileCount: 3
        )
        let preferenceStore = DevicePreferenceStore()
        let saved = preferenceStore.saveOpenSnekButtonProfile(
            name: "Travel",
            bindings: [
                4: ButtonBindingDraft(kind: .rightClick, hidKey: 4, turboEnabled: false, turboRate: 0x8E, clutchDPI: nil)
            ]
        )
        defer {
            clearSavedButtonProfiles()
            clearRefactorPreferences(for: device)
        }

        let backend = AppStateRefactorStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makeRefactorTestState(
                    device: device,
                    connection: "usb",
                    batteryPercent: 74,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300,
                    activeOnboardProfile: 1,
                    onboardProfileCount: 3
                )
            ]
        )
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: .basiliskV3Pro)),
            forDeviceID: device.id,
            slot: 4,
            profile: 1
        )
        await backend.setButtonBindingBlock(
            try XCTUnwrap(ButtonBindingSupport.defaultUSBFunctionBlock(for: 4, profileID: .basiliskV3Pro)),
            forDeviceID: device.id,
            slot: 4,
            profile: 0
        )
        await backend.setButtonBindingBlock(
            ButtonBindingSupport.buildUSBFunctionBlock(
                slot: 4,
                kind: .mouseForward,
                hidKey: 4,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil,
                profileID: .basiliskV3Pro
            ),
            forDeviceID: device.id,
            slot: 4,
            profile: 2
        )
        await backend.setButtonBindingBlock(
            ButtonBindingSupport.buildUSBFunctionBlock(
                slot: 4,
                kind: .rightClick,
                hidKey: 4,
                turboEnabled: false,
                turboRate: 0x8E,
                clutchDPI: nil,
                profileID: .basiliskV3Pro
            ),
            forDeviceID: device.id,
            slot: 4,
            profile: 3
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await MainActor.run {
            appState.editorStore.refreshButtonProfilePresentation()
        }

        try await waitForRefactorCondition(timeout: 2.0) {
            await MainActor.run {
                let summaries = appState.editorStore.visibleUSBButtonProfiles
                guard summaries.count == 3 else { return false }
                return summaries.first(where: { $0.profile == 2 })?.isCustomized == true &&
                    summaries.first(where: { $0.profile == 3 })?.isCustomized == true
            }
        }
        await MainActor.run {
            appState.editorStore.selectButtonProfileSource(.openSnekProfile(saved.id))
            appState.editorStore.selectNextOnboardButtonProfile()
        }

        try await waitForRefactorCondition {
            await MainActor.run {
                appState.editorStore.currentButtonProfileSource == .mouseSlot(2) &&
                    appState.editorStore.buttonBindingKind(for: 4) == .mouseForward
            }
        }

        await MainActor.run {
            appState.editorStore.selectNextOnboardButtonProfile()
        }
        try await waitForRefactorCondition {
            await MainActor.run {
                appState.editorStore.currentButtonProfileSource == .mouseSlot(3) &&
                    appState.editorStore.buttonBindingKind(for: 4) == .rightClick
            }
        }

        await MainActor.run {
            appState.editorStore.selectNextOnboardButtonProfile()
        }
        try await waitForRefactorCondition {
            await MainActor.run {
                appState.editorStore.currentButtonProfileSource == .mouseSlot(1) &&
                    appState.editorStore.buttonBindingKind(for: 4) == .default
            }
        }
    }

    func testSwitchingBetweenUSBDevicesReusesSessionButtonBindingCache() async throws {
        let alphaDevice = makeRefactorTestDevice(
            id: "usb-alpha-device",
            transport: .usb,
            serial: "USB-ALPHA-\(UUID().uuidString)",
            onboardProfileCount: 1
        )
        let betaDevice = makeRefactorTestDevice(
            id: "usb-beta-device",
            transport: .usb,
            serial: "USB-BETA-\(UUID().uuidString)",
            onboardProfileCount: 1
        )

        let backend = AppStateRefactorStubBackend(
            devices: [alphaDevice, betaDevice],
            stateByDeviceID: [
                alphaDevice.id: makeRefactorTestState(
                    device: alphaDevice,
                    connection: "usb",
                    batteryPercent: 77,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800,
                    pollRate: 1000,
                    sleepTimeout: 300
                ),
                betaDevice.id: makeRefactorTestState(
                    device: betaDevice,
                    connection: "usb",
                    batteryPercent: 78,
                    dpiValues: [900, 1800, 2700],
                    activeStage: 1,
                    dpiValue: 1800,
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
            await backend.buttonReadCount(for: alphaDevice.id) > 0
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let alphaReadCountAfterInitialHydration = await backend.buttonReadCount(for: alphaDevice.id)

        await MainActor.run {
            appState.deviceStore.selectDevice(betaDevice.id)
        }

        try await waitForRefactorCondition {
            await backend.buttonReadCount(for: betaDevice.id) > 0
        }
        try await Task.sleep(nanoseconds: 250_000_000)

        await MainActor.run {
            appState.deviceStore.selectDevice(alphaDevice.id)
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        let alphaReadCountAfterReselect = await backend.buttonReadCount(for: alphaDevice.id)
        XCTAssertEqual(alphaReadCountAfterReselect, alphaReadCountAfterInitialHydration)
    }
}

private actor AppStateRefactorStubBackend: DeviceBackend, ApplyOptionsSupportingBackend {
    nonisolated var usesRemoteServiceTransport: Bool { false }

    private let devices: [MouseDevice]
    private var stateByDeviceID: [String: MouseState]
    private var fastByDeviceID: [String: DpiFastSnapshot]
    private let shouldUseFastPolling: Bool
    private let holdFirstApply: Bool
    private var applyPatches: [DevicePatch] = []
    private var applyReadbackPolicies: [ApplyReadbackPolicy] = []
    private var applyInvocationCount = 0
    private var activeApplyCount = 0
    private var maxObservedConcurrentApplies = 0
    private var firstApplyStartedContinuation: CheckedContinuation<Void, Never>?
    private var firstApplyReleaseContinuation: CheckedContinuation<Void, Never>?
    private var buttonBindingBlocks: [String: [UInt8]] = [:]
    private var buttonReadCountByDeviceID: [String: Int] = [:]
    private var readCountByDeviceID: [String: Int] = [:]
    private var fastReadInvocationCount = 0
    private var fastReadCountByDeviceID: [String: Int] = [:]

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
        readCountByDeviceID[device.id, default: 0] += 1
        guard let state = stateByDeviceID[device.id] else {
            throw NSError(domain: "AppStateRefactorCharacterizationTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing state for \(device.id)"
            ])
        }
        return state
    }

    func readDpiStagesFast(device: MouseDevice) async throws -> DpiFastSnapshot? {
        fastReadInvocationCount += 1
        fastReadCountByDeviceID[device.id, default: 0] += 1
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

    func apply(device: MouseDevice, patch: DevicePatch, options: ApplyOptions) async throws -> MouseState {
        applyInvocationCount += 1
        activeApplyCount += 1
        maxObservedConcurrentApplies = max(maxObservedConcurrentApplies, activeApplyCount)
        applyReadbackPolicies.append(options.readbackPolicy)

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
        buttonReadCountByDeviceID[device.id, default: 0] += 1
        return buttonBindingBlocks[buttonKey(deviceID: device.id, slot: slot, profile: profile)]
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

    func recordedApplyReadbackPolicies() -> [ApplyReadbackPolicy] {
        applyReadbackPolicies
    }

    func applyCount() -> Int {
        applyInvocationCount
    }

    func maxConcurrentApplies() -> Int {
        maxObservedConcurrentApplies
    }

    func readCount(for deviceID: String) -> Int {
        readCountByDeviceID[deviceID, default: 0]
    }

    func fastReadCount() -> Int {
        fastReadInvocationCount
    }

    func fastReadCount(for deviceID: String) -> Int {
        fastReadCountByDeviceID[deviceID, default: 0]
    }

    func setButtonBindingBlock(_ block: [UInt8], forDeviceID deviceID: String, slot: Int, profile: Int) {
        buttonBindingBlocks[buttonKey(deviceID: deviceID, slot: slot, profile: profile)] = block
    }

    func buttonReadCount(for deviceID: String) -> Int {
        buttonReadCountByDeviceID[deviceID, default: 0]
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
    onboardProfileCount: Int,
    profileID: DeviceProfileID? = nil
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
        profile_id: profileID ?? (transport == .bluetooth ? .basiliskV3XHyperspeed : .basiliskV3Pro),
        supports_advanced_lighting_effects: true,
        onboard_profile_count: onboardProfileCount
    )
}

private func makeRefactorUSBLightingRestoreDevice(
    id: String,
    serial: String
) -> MouseDevice {
    MouseDevice(
        id: id,
        vendor_id: 0x1532,
        product_id: 0x00B9,
        product_name: "Refactor USB Lighting Restore Mouse",
        transport: .usb,
        path_b64: "",
        serial: serial,
        firmware: "1.0.0",
        location_id: 1,
        profile_id: .basiliskV3XHyperspeed,
        supports_advanced_lighting_effects: true,
        onboard_profile_count: 1
    )
}

private func makeRefactorMultiZoneUSBLightingDevice(
    id: String,
    serial: String
) -> MouseDevice {
    MouseDevice(
        id: id,
        vendor_id: 0x1532,
        product_id: 0x00AB,
        product_name: "Refactor Multi-Zone USB Lighting Mouse",
        transport: .usb,
        path_b64: "",
        serial: serial,
        firmware: "1.0.0",
        location_id: 1,
        profile_id: .basiliskV3Pro,
        supports_advanced_lighting_effects: true,
        onboard_profile_count: 1
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

private func makeRefactorSettingsSnapshot(
    color: OpenSnekCore.RGBColor,
    zoneID: String = "all",
    lightingEffect: LightingEffectPatch? = nil,
    buttonBindings: [Int: ButtonBindingDraft] = [:]
) -> PersistedDeviceSettingsSnapshot {
    PersistedDeviceSettingsSnapshot(
        stageCount: 3,
        stageValues: [900, 1800, 3600],
        stagePairs: [
            DpiPair(x: 900, y: 900),
            DpiPair(x: 1800, y: 1800),
            DpiPair(x: 3600, y: 3600),
        ],
        activeStage: 3,
        pollRate: 500,
        sleepTimeout: 420,
        lowBatteryThresholdRaw: 0x20,
        scrollMode: 1,
        scrollAcceleration: true,
        scrollSmartReel: false,
        ledBrightness: 77,
        primaryLightingColor: color,
        lightingEffect: lightingEffect,
        usbLightingZoneID: zoneID,
        buttonBindings: buttonBindings
    )
}

private func clearRefactorPreferences(for device: MouseDevice) {
    let defaults = UserDefaults.standard
    let key = DevicePersistenceKeys.key(for: device)
    let legacyKey = DevicePersistenceKeys.legacyKey(for: device)
    let prefixes = [
        "lightingColor.\(key)",
        "lightingColor.\(legacyKey)",
        "lightingZone.\(key)",
        "lightingZone.\(legacyKey)",
        "lightingEffect.\(key)",
        "lightingEffect.\(legacyKey)",
        "connectBehavior.\(key)",
        "connectBehavior.\(legacyKey)",
        "settingsSnapshot.\(key)",
        "settingsSnapshot.\(legacyKey)",
        "buttonBindings.\(key)",
        "buttonBindings.\(legacyKey)",
        "buttonBindings.\(key).profile1",
        "buttonBindings.\(key).profile2",
        "buttonBindings.\(key).profile3",
        "buttonBindings.\(key).profile4",
        "buttonBindings.\(key).profile5",
        "buttonBindings.\(legacyKey).profile1",
        "buttonBindings.\(legacyKey).profile2",
        "buttonBindings.\(legacyKey).profile3",
        "buttonBindings.\(legacyKey).profile4",
        "buttonBindings.\(legacyKey).profile5",
    ]
    for storedKey in defaults.dictionaryRepresentation().keys {
        if prefixes.contains(where: { storedKey.hasPrefix($0) }) {
            defaults.removeObject(forKey: storedKey)
        }
    }
    clearSavedButtonProfiles()
}

private func clearSavedButtonProfiles() {
    UserDefaults.standard.removeObject(forKey: "openSnekButtonProfiles")
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
