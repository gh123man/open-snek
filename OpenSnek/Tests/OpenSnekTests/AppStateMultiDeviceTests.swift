import Foundation
import XCTest
import OpenSnekAppSupport
import OpenSnekCore
@testable import OpenSnek

final class AppStateMultiDeviceTests: XCTestCase {
    func testRefreshDevicesRefreshesAllDeviceCachesAndKeepsSelectedPresentationStable() async {
        let alphaDevice = makeTestDevice(
            id: "alpha-device",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "ALPHA",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let betaDevice = makeTestDevice(
            id: "beta-device",
            productName: "Beta Mouse",
            transport: .bluetooth,
            serial: "BETA",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let backend = MultiDeviceStubBackend(
            devices: [betaDevice, alphaDevice],
            stateByDeviceID: [
                alphaDevice.id: makeTestState(
                    device: alphaDevice,
                    connection: "usb",
                    batteryPercent: 81,
                    dpiValues: [1200, 2400, 3600],
                    activeStage: 0,
                    dpiValue: 1200
                ),
                betaDevice.id: makeTestState(
                    device: betaDevice,
                    connection: "bluetooth",
                    batteryPercent: 72,
                    dpiValues: [3200, 4800, 6400],
                    activeStage: 1,
                    dpiValue: 4800
                ),
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        let selectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }
        let selectedDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }
        let initialReadOrder = await backend.recordedReadOrder()

        XCTAssertEqual(selectedDeviceID, alphaDevice.id)
        XCTAssertEqual(selectedDpi, 1200)
        XCTAssertEqual(initialReadOrder, [alphaDevice.id, betaDevice.id])

        await MainActor.run {
            appState.deviceStore.selectDevice(betaDevice.id)
        }

        let betaDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }
        let activeStage = await MainActor.run { appState.editorStore.editableActiveStage }
        let readCountAfterSelection = await backend.readCount()

        XCTAssertEqual(betaDpi, 4800)
        XCTAssertEqual(activeStage, 2)
        XCTAssertEqual(readCountAfterSelection, 2)
    }

    func testRefreshDevicesBacksOffRepeatedlyFailingNonSelectedDevice() async {
        let bluetoothDevice = makeTestDevice(
            id: "bt-device",
            productName: "Alpha Mouse",
            transport: .bluetooth,
            serial: "BT-OK",
            locationID: 1,
            profile: .basiliskV3XHyperspeed
        )
        let unavailableDongle = makeTestDevice(
            id: "usb-dongle",
            productName: "Zeta Mouse",
            transport: .usb,
            serial: "USB-IDLE",
            locationID: 2,
            profile: .basiliskV3Pro
        )
        let backend = PartiallyFailingMultiDeviceStubBackend(
            devices: [unavailableDongle, bluetoothDevice],
            stateByDeviceID: [
                bluetoothDevice.id: makeTestState(
                    device: bluetoothDevice,
                    connection: "bluetooth",
                    batteryPercent: 72,
                    dpiValues: [3200, 4800, 6400],
                    activeStage: 1,
                    dpiValue: 4800
                )
            ],
            failingDeviceIDs: [unavailableDongle.id]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        let firstReadOrder = await backend.recordedReadOrder()

        await appState.deviceStore.refreshDevices()
        let secondReadOrder = await backend.recordedReadOrder()
        let selectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }
        let selectedDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }

        XCTAssertEqual(selectedDeviceID, bluetoothDevice.id)
        XCTAssertEqual(selectedDpi, 4800)
        XCTAssertEqual(firstReadOrder, [bluetoothDevice.id, unavailableDongle.id])
        XCTAssertEqual(secondReadOrder, [bluetoothDevice.id, unavailableDongle.id, bluetoothDevice.id])
    }

    func testSelectedUnavailableDeviceClearsPresentedStateInsteadOfShowingStaleCache() async {
        let usbDevice = makeTestDevice(
            id: "usb-dongle",
            productName: "Zeta Mouse",
            transport: .usb,
            serial: "USB-IDLE",
            locationID: 2,
            profile: .basiliskV3Pro
        )
        let initialState = makeTestState(
            device: usbDevice,
            connection: "usb",
            batteryPercent: 72,
            dpiValues: [800, 900, 2000, 1100, 1200],
            activeStage: 2,
            dpiValue: 2000
        )
        let backend = DisconnectingMultiDeviceStubBackend(
            devices: [usbDevice],
            stateByDeviceID: [usbDevice.id: initialState]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await backend.setUnavailable(true)
        await appState.deviceStore.refreshState()
        await appState.deviceStore.pollDevicePresence()

        let selectedDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }
        let lastUpdated = await MainActor.run { appState.deviceStore.lastUpdated }
        let status = await MainActor.run { appState.deviceStore.currentDeviceStatusIndicator.label }

        XCTAssertNil(selectedDpi)
        XCTAssertNil(lastUpdated)
        XCTAssertEqual(status, "Disconnected")
    }

    func testDiagnosticsExposePollingVsRealtimeHIDAndDisableControlsWhenDisconnected() async throws {
        let usbDevice = makeTestDevice(
            id: "usb-diagnostics",
            productName: "Zeta Mouse",
            transport: .usb,
            serial: "USB-DIAG",
            locationID: 3,
            profile: .basiliskV3Pro
        )
        let initialState = makeTestState(
            device: usbDevice,
            connection: "usb",
            batteryPercent: 68,
            dpiValues: [800, 1600, 3200],
            activeStage: 1,
            dpiValue: 1600
        )
        let backend = DeviceListUpdatingStubBackend(
            devices: [usbDevice],
            stateByDeviceID: [usbDevice.id: initialState],
            shouldUseFastDPIPolling: true
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await appState.deviceStore.refreshConnectionDiagnostics(for: usbDevice)

        let pollingLines = await MainActor.run { appState.deviceStore.diagnosticsConnectionLines(for: usbDevice) }
        let controlsInitiallyEnabled = await MainActor.run { appState.deviceStore.selectedDeviceControlsEnabled }
        XCTAssertTrue(pollingLines.contains("DPI updates: Polling fallback active"))
        XCTAssertTrue(controlsInitiallyEnabled)

        await backend.setShouldUseFastDPIPolling(false)
        await appState.deviceStore.refreshConnectionDiagnostics(for: usbDevice)

        let passiveLines = await MainActor.run { appState.deviceStore.diagnosticsConnectionLines(for: usbDevice) }
        XCTAssertTrue(passiveLines.contains("DPI updates: Real-time HID active"))

        await backend.emitDeviceListUpdate([])

        try await waitForAppStateCondition {
            await MainActor.run { !appState.deviceStore.selectedDeviceControlsEnabled }
        }

        let status = await MainActor.run { appState.deviceStore.currentDeviceStatusIndicator.label }
        XCTAssertEqual(status, "Disconnected")
    }

    func testConnectedStatusPillStaysGreenWhileListeningForFirstHIDEvent() async {
        let bluetoothDevice = makeTestDevice(
            id: "bt-fallback",
            productName: "Basilisk V3 Pro",
            transport: .bluetooth,
            serial: "BT-FALLBACK",
            locationID: 4,
            profile: .basiliskV3Pro
        )
        let initialState = makeTestState(
            device: bluetoothDevice,
            connection: "bluetooth",
            batteryPercent: 74,
            dpiValues: [800, 1600, 3200],
            activeStage: 1,
            dpiValue: 1600
        )
        let backend = DeviceListUpdatingStubBackend(
            devices: [bluetoothDevice],
            stateByDeviceID: [bluetoothDevice.id: initialState],
            shouldUseFastDPIPolling: true,
            dpiUpdateTransportStatus: .listening
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        let indicator = await MainActor.run { appState.deviceStore.currentDeviceStatusIndicator }
        let connectionTooltip = await MainActor.run { appState.deviceStore.currentDeviceConnectionTooltip }
        let tooltip = await MainActor.run { appState.deviceStore.currentDeviceStatusTooltip }

        XCTAssertEqual(indicator.label, "Connected")
        XCTAssertEqual(OpenSnekCore.RGBColor.fromColor(indicator.color), RGBColor(r: 48, g: 209, b: 88))
        XCTAssertEqual(
            connectionTooltip,
            """
            Transport: Bluetooth
            Connection state: Live
            Control transport: bluetooth
            Real-time HID: Listening for first HID event
            Input Monitoring: Granted
            """
        )
        XCTAssertEqual(
            tooltip,
            """
            Control transport: bluetooth
            Telemetry: Live
            Real-time HID: Listening for first HID event
            Input Monitoring: Granted
            """
        )
    }

    func testConnectedStatusPillWarnsWhenRealtimeHIDFallsBack() async {
        let bluetoothDevice = makeTestDevice(
            id: "bt-warning",
            productName: "Basilisk V3 Pro",
            transport: .bluetooth,
            serial: "BT-WARNING",
            locationID: 5,
            profile: .basiliskV3Pro
        )
        let initialState = makeTestState(
            device: bluetoothDevice,
            connection: "bluetooth",
            batteryPercent: 71,
            dpiValues: [800, 1600, 3200],
            activeStage: 1,
            dpiValue: 1600
        )
        let backend = DeviceListUpdatingStubBackend(
            devices: [bluetoothDevice],
            stateByDeviceID: [bluetoothDevice.id: initialState],
            shouldUseFastDPIPolling: true,
            dpiUpdateTransportStatus: .pollingFallback,
            hidAccessAuthorization: .denied
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        let indicator = await MainActor.run { appState.deviceStore.currentDeviceStatusIndicator }
        let connectionTooltip = await MainActor.run { appState.deviceStore.currentDeviceConnectionTooltip }
        let tooltip = await MainActor.run { appState.deviceStore.currentDeviceStatusTooltip }

        XCTAssertEqual(indicator.label, "Connected")
        XCTAssertEqual(OpenSnekCore.RGBColor.fromColor(indicator.color), RGBColor(r: 244, g: 198, b: 93))
        XCTAssertEqual(
            connectionTooltip,
            """
            Transport: Bluetooth
            Connection state: Live
            Control transport: bluetooth
            Real-time HID: Polling fallback active
            Input Monitoring: Denied
            """
        )
        XCTAssertEqual(
            tooltip,
            """
            Control transport: bluetooth
            Telemetry: Live
            Real-time HID: Polling fallback active
            Input Monitoring: Denied
            """
        )
    }

    func testConnectionDiagnosticsRevisionUpdatesWhenTransportStatusChanges() async {
        let bluetoothDevice = makeTestDevice(
            id: "bt-revision",
            productName: "Basilisk V3 Pro",
            transport: .bluetooth,
            serial: "BT-REVISION",
            locationID: 6,
            profile: .basiliskV3Pro
        )
        let initialState = makeTestState(
            device: bluetoothDevice,
            connection: "bluetooth",
            batteryPercent: 69,
            dpiValues: [800, 1600, 3200],
            activeStage: 1,
            dpiValue: 1600
        )
        let backend = DeviceListUpdatingStubBackend(
            devices: [bluetoothDevice],
            stateByDeviceID: [bluetoothDevice.id: initialState],
            shouldUseFastDPIPolling: true,
            dpiUpdateTransportStatus: .pollingFallback
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        let initialRevision = await MainActor.run { appState.deviceStore.connectionDiagnosticsRevision }

        await backend.setDpiUpdateTransportStatus(.listening)
        await appState.deviceStore.refreshConnectionDiagnostics(for: bluetoothDevice)

        let updatedRevision = await MainActor.run { appState.deviceStore.connectionDiagnosticsRevision }
        let indicator = await MainActor.run { appState.deviceStore.currentDeviceStatusIndicator }

        XCTAssertGreaterThan(updatedRevision, initialRevision)
        XCTAssertEqual(indicator.label, "Connected")
        XCTAssertEqual(OpenSnekCore.RGBColor.fromColor(indicator.color), RGBColor(r: 48, g: 209, b: 88))
    }

    func testFastDpiPollingDoesNotDowngradeListeningStatusToFallback() async {
        let bluetoothDevice = makeTestDevice(
            id: "bt-listening-fast",
            productName: "Basilisk V3 Pro",
            transport: .bluetooth,
            serial: "BT-LISTENING-FAST",
            locationID: 7,
            profile: .basiliskV3Pro
        )
        let initialState = makeTestState(
            device: bluetoothDevice,
            connection: "bluetooth",
            batteryPercent: 66,
            dpiValues: [800, 1600, 3200],
            activeStage: 1,
            dpiValue: 1600
        )
        let backend = DeviceListUpdatingStubBackend(
            devices: [bluetoothDevice],
            stateByDeviceID: [bluetoothDevice.id: initialState],
            shouldUseFastDPIPolling: true,
            dpiUpdateTransportStatus: .listening
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await appState.deviceStore.refreshDpiFast()

        let indicator = await MainActor.run { appState.deviceStore.currentDeviceStatusIndicator }
        let tooltip = await MainActor.run { appState.deviceStore.currentDeviceStatusTooltip }

        XCTAssertEqual(indicator.label, "Connected")
        XCTAssertEqual(OpenSnekCore.RGBColor.fromColor(indicator.color), RGBColor(r: 48, g: 209, b: 88))
        XCTAssertTrue(tooltip?.contains("Real-time HID: Listening for first HID event") == true)
    }

    func testBackendDeviceListUpdateRemovesDisconnectedDeviceImmediately() async throws {
        let bluetoothDevice = makeTestDevice(
            id: "bt-device",
            productName: "Alpha Mouse",
            transport: .bluetooth,
            serial: "BT-ONE",
            locationID: 1,
            profile: .basiliskV3XHyperspeed
        )
        let backend = DeviceListUpdatingStubBackend(
            devices: [bluetoothDevice],
            stateByDeviceID: [
                bluetoothDevice.id: makeTestState(
                    device: bluetoothDevice,
                    connection: "bluetooth",
                    batteryPercent: 72,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 1,
                    dpiValue: 1600
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await backend.emitDeviceListUpdate([])

        try await waitForAppStateCondition {
            await MainActor.run { appState.deviceStore.devices.isEmpty }
        }

        let selectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }
        let state = await MainActor.run { appState.deviceStore.state }

        XCTAssertNil(selectedDeviceID)
        XCTAssertNil(state)
    }

    func testBackendDeviceListUpdateRefreshesStateForReconnectWithStableDeviceID() async throws {
        let usbDevice = makeTestDevice(
            id: "usb-reconnect",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "USB-ONE",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let initialState = makeTestState(
            device: usbDevice,
            connection: "usb",
            batteryPercent: 81,
            dpiValues: [800, 1600, 3200],
            activeStage: 0,
            dpiValue: 800
        )
        let refreshedState = makeTestState(
            device: usbDevice,
            connection: "usb",
            batteryPercent: 81,
            dpiValues: [800, 1600, 3200],
            activeStage: 2,
            dpiValue: 3200
        )
        let backend = DeviceListUpdatingStubBackend(
            devices: [usbDevice],
            stateByDeviceID: [usbDevice.id: initialState]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        let initialReadCount = await backend.readCount(for: usbDevice.id)

        await backend.setState(refreshedState, for: usbDevice.id)
        await backend.emitDeviceListUpdate([usbDevice])

        try await waitForAppStateCondition {
            await MainActor.run { appState.deviceStore.state?.dpi?.x == 3200 }
        }

        let readCount = await backend.readCount(for: usbDevice.id)
        let activeStage = await MainActor.run { appState.deviceStore.state?.dpi_stages.active_stage }

        XCTAssertGreaterThanOrEqual(readCount, initialReadCount + 1)
        XCTAssertEqual(activeStage, 2)
    }

    func testBackendDeviceListUpdateRearmsLightingRestoreForStableReconnect() async throws {
        let usbDevice = makeTestDevice(
            id: "usb-lighting-reconnect",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "USB-LIGHTING-RECONNECT",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let persistedColor = RGBColor(r: 11, g: 22, b: 33)
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistLightingColor(persistedColor, device: usbDevice)
        preferenceStore.persistLightingZoneID("logo", device: usbDevice)
        defer { clearMultiDeviceLightingPreferences(for: usbDevice) }

        let backend = DeviceListUpdatingStubBackend(
            devices: [usbDevice],
            stateByDeviceID: [
                usbDevice.id: makeTestState(
                    device: usbDevice,
                    connection: "usb",
                    batteryPercent: 81,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 0,
                    dpiValue: 800
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        try await waitForAppStateCondition {
            await backend.applyCount() == 1
        }

        await backend.emitDeviceListUpdate([usbDevice])

        try await waitForAppStateCondition {
            await backend.applyCount() == 2
        }

        let patches = await backend.recordedPatches()
        XCTAssertEqual(patches.count, 2)
        XCTAssertEqual(patches[0].ledRGB?.r, persistedColor.r)
        XCTAssertEqual(patches[1].ledRGB?.r, persistedColor.r)
    }

    func testNonSelectedReconnectLightingRestoreDoesNotChangeSelection() async throws {
        let alphaDevice = makeTestDevice(
            id: "alpha-selected",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "ALPHA-SELECTED",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let betaDevice = makeTestDevice(
            id: "beta-restore",
            productName: "Beta Mouse",
            transport: .usb,
            serial: "BETA-RESTORE",
            locationID: 2,
            profile: .basiliskV3Pro
        )
        let persistedColor = RGBColor(r: 21, g: 31, b: 41)
        let preferenceStore = DevicePreferenceStore()
        preferenceStore.persistLightingColor(persistedColor, device: betaDevice)
        preferenceStore.persistLightingZoneID("logo", device: betaDevice)
        defer {
            clearMultiDeviceLightingPreferences(for: alphaDevice)
            clearMultiDeviceLightingPreferences(for: betaDevice)
        }

        let backend = DeviceListUpdatingStubBackend(
            devices: [betaDevice, alphaDevice],
            stateByDeviceID: [
                alphaDevice.id: makeTestState(
                    device: alphaDevice,
                    connection: "usb",
                    batteryPercent: 81,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 0,
                    dpiValue: 800
                ),
                betaDevice.id: makeTestState(
                    device: betaDevice,
                    connection: "usb",
                    batteryPercent: 79,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600
                )
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        try await waitForAppStateCondition {
            await backend.applyCount() == 1
        }

        let initialSelectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }
        let initialApplyDevices = await backend.recordedApplyDeviceIDs()
        XCTAssertEqual(initialSelectedDeviceID, alphaDevice.id)
        XCTAssertEqual(initialApplyDevices, [betaDevice.id])

        await backend.emitDeviceListUpdate([betaDevice, alphaDevice])

        try await waitForAppStateCondition {
            await backend.applyCount() == 2
        }

        let selectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }
        let applyDeviceIDs = await backend.recordedApplyDeviceIDs()

        XCTAssertEqual(selectedDeviceID, alphaDevice.id)
        XCTAssertEqual(applyDeviceIDs, [betaDevice.id, betaDevice.id])
    }

    func testBackendDeviceListUpdateRecoversSelectionToMatchingBluetoothTransportWhenUSBHasNoTelemetry() async throws {
        let usbDevice = makeTestDevice(
            id: "usb-recovery",
            productName: "Shared Mouse",
            transport: .usb,
            serial: "MATCHED-DEVICE",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let bluetoothDevice = makeTestDevice(
            id: "bt-recovery",
            productName: "Shared Mouse",
            transport: .bluetooth,
            serial: "MATCHED-DEVICE",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let bluetoothState = makeTestState(
            device: bluetoothDevice,
            connection: "bluetooth",
            batteryPercent: 74,
            dpiValues: [1200, 2400, 3600],
            activeStage: 1,
            dpiValue: 2400
        )
        let backend = DeviceListUpdatingStubBackend(
            devices: [usbDevice],
            stateByDeviceID: [bluetoothDevice.id: bluetoothState]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await backend.emitDeviceListUpdate([usbDevice, bluetoothDevice])

        try await waitForAppStateCondition(timeout: 2.0) {
            await MainActor.run {
                appState.deviceStore.selectedDeviceID == bluetoothDevice.id &&
                    appState.deviceStore.state?.device.id == bluetoothDevice.id
            }
        }

        let selectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }
        let selectedDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }
        let status = await MainActor.run { appState.deviceStore.currentDeviceStatusIndicator.label }

        XCTAssertEqual(selectedDeviceID, bluetoothDevice.id)
        XCTAssertEqual(selectedDpi, 2400)
        XCTAssertEqual(status, "Connected")
    }

    func testBackendDeviceListUpdateDoesNotSwitchToUnrelatedBluetoothDeviceDuringUSBRecovery() async throws {
        let usbDevice = makeTestDevice(
            id: "usb-unrelated",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "USB-ONLY",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let bluetoothDevice = makeTestDevice(
            id: "bt-unrelated",
            productName: "Beta Mouse",
            transport: .bluetooth,
            serial: "BT-ONLY",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let bluetoothState = makeTestState(
            device: bluetoothDevice,
            connection: "bluetooth",
            batteryPercent: 74,
            dpiValues: [1200, 2400, 3600],
            activeStage: 1,
            dpiValue: 2400
        )
        let backend = DeviceListUpdatingStubBackend(
            devices: [usbDevice],
            stateByDeviceID: [bluetoothDevice.id: bluetoothState]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await backend.emitDeviceListUpdate([usbDevice, bluetoothDevice])

        try await waitForAppStateCondition(timeout: 1.0) {
            await MainActor.run {
                appState.deviceStore.devices.count == 2
            }
        }

        let selectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }

        XCTAssertEqual(selectedDeviceID, usbDevice.id)
    }

    func testRemotePresenceSelectedDeviceDrivesServiceInteractivePollingUntilExpiry() async {
        let suiteName = "AppStateMultiDeviceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: UserDefaults(suiteName: suiteName)!)
        }
        let appState = await MainActor.run {
            AppState(launchRole: .service, serviceCoordinator: coordinator, autoStart: false)
        }
        let alphaDevice = makeTestDevice(
            id: "alpha-device",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "ALPHA",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let betaDevice = makeTestDevice(
            id: "beta-device",
            productName: "Beta Mouse",
            transport: .usb,
            serial: "BETA",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let now = Date(timeIntervalSince1970: 1_773_400_000)

        await MainActor.run {
            appState.deviceStore.devices = [alphaDevice, betaDevice]
            appState.deviceStore.selectedDeviceID = betaDevice.id
            appState.runtimeStore.recordRemoteClientPresence(
                CrossProcessClientPresence(sourceProcessID: 41, selectedDeviceID: alphaDevice.id),
                now: now
            )
        }

        let activeProfile = await MainActor.run { appState.runtimeStore.pollingProfile(at: now) }
        let activeDeviceIDs = await MainActor.run { appState.runtimeStore.activeFastPollingDeviceIDs(at: now) }
        let expiredProfile = await MainActor.run { appState.runtimeStore.pollingProfile(at: now.addingTimeInterval(3.0)) }
        let expiredDeviceIDs = await MainActor.run { appState.runtimeStore.activeFastPollingDeviceIDs(at: now.addingTimeInterval(3.0)) }
        let selectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }

        XCTAssertEqual(selectedDeviceID, betaDevice.id)
        XCTAssertEqual(activeProfile, .serviceInteractive)
        XCTAssertEqual(activeDeviceIDs, [alphaDevice.id])
        XCTAssertEqual(expiredProfile, .serviceIdle)
        XCTAssertTrue(expiredDeviceIDs.isEmpty)
    }

    func testRemotePresenceWithoutSelectedDeviceFallsBackToServiceSelectionForFastPolling() async {
        let suiteName = "AppStateMultiDeviceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: UserDefaults(suiteName: suiteName)!)
        }
        let appState = await MainActor.run {
            AppState(launchRole: .service, serviceCoordinator: coordinator, autoStart: false)
        }
        let alphaDevice = makeTestDevice(
            id: "alpha-device",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "ALPHA",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let betaDevice = makeTestDevice(
            id: "beta-device",
            productName: "Beta Mouse",
            transport: .usb,
            serial: "BETA",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let now = Date(timeIntervalSince1970: 1_773_400_050)

        await MainActor.run {
            appState.deviceStore.devices = [alphaDevice, betaDevice]
            appState.deviceStore.selectedDeviceID = betaDevice.id
            appState.runtimeStore.recordRemoteClientPresence(
                CrossProcessClientPresence(sourceProcessID: 41, selectedDeviceID: nil),
                now: now
            )
        }

        let activeProfile = await MainActor.run { appState.runtimeStore.pollingProfile(at: now) }
        let activeDeviceIDs = await MainActor.run { appState.runtimeStore.activeFastPollingDeviceIDs(at: now) }

        XCTAssertEqual(activeProfile, .serviceInteractive)
        XCTAssertEqual(activeDeviceIDs, [betaDevice.id])
    }

    func testServiceFastPollingUnionIncludesLocalAndRemoteSelections() async {
        let suiteName = "AppStateMultiDeviceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: UserDefaults(suiteName: suiteName)!)
        }
        let appState = await MainActor.run {
            AppState(launchRole: .service, serviceCoordinator: coordinator, autoStart: false)
        }
        let alphaDevice = makeTestDevice(
            id: "alpha-device",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "ALPHA",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let betaDevice = makeTestDevice(
            id: "beta-device",
            productName: "Beta Mouse",
            transport: .usb,
            serial: "BETA",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let now = Date(timeIntervalSince1970: 1_773_400_100)

        await MainActor.run {
            appState.deviceStore.devices = [alphaDevice, betaDevice]
            appState.deviceStore.selectedDeviceID = betaDevice.id
            appState.runtimeStore.setCompactMenuPresented(true)
            appState.runtimeStore.recordRemoteClientPresence(
                CrossProcessClientPresence(sourceProcessID: 42, selectedDeviceID: alphaDevice.id),
                now: now
            )
        }

        let profile = await MainActor.run { appState.runtimeStore.pollingProfile(at: now) }
        let activeDeviceIDs = await MainActor.run { appState.runtimeStore.activeFastPollingDeviceIDs(at: now) }

        XCTAssertEqual(profile, .serviceInteractive)
        XCTAssertEqual(activeDeviceIDs, [betaDevice.id, alphaDevice.id])
    }

    func testServiceSelectionFollowsDeviceWithMeaningfulRefreshChange() async {
        let alphaDevice = makeTestDevice(
            id: "alpha-device",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "ALPHA",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let betaDevice = makeTestDevice(
            id: "beta-device",
            productName: "Beta Mouse",
            transport: .usb,
            serial: "BETA",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let backend = MultiDeviceStubBackend(
            devices: [alphaDevice, betaDevice],
            stateByDeviceID: [
                alphaDevice.id: makeTestState(
                    device: alphaDevice,
                    connection: "usb",
                    batteryPercent: 81,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800
                ),
                betaDevice.id: makeTestState(
                    device: betaDevice,
                    connection: "usb",
                    batteryPercent: 77,
                    dpiValues: [1000, 2000, 3000],
                    activeStage: 0,
                    dpiValue: 1000
                ),
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .service, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        await MainActor.run {
            appState.deviceStore.selectDevice(alphaDevice.id)
        }
        await backend.setState(
            makeTestState(
                device: betaDevice,
                connection: "usb",
                batteryPercent: 77,
                dpiValues: [1800, 3600, 5400],
                activeStage: 1,
                dpiValue: 3600
            ),
            for: betaDevice.id
        )

        await appState.deviceStore.refreshDevices()

        let selectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }
        let selectedDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }
        let activeStage = await MainActor.run { appState.editorStore.editableActiveStage }

        XCTAssertEqual(selectedDeviceID, betaDevice.id)
        XCTAssertEqual(selectedDpi, 3600)
        XCTAssertEqual(activeStage, 2)
    }

    func testServiceSelectionFollowsDeviceWithFastDpiActivity() async {
        let alphaDevice = makeTestDevice(
            id: "alpha-device",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "ALPHA",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let betaDevice = makeTestDevice(
            id: "beta-device",
            productName: "Beta Mouse",
            transport: .usb,
            serial: "BETA",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let backend = MultiDeviceStubBackend(
            devices: [alphaDevice, betaDevice],
            stateByDeviceID: [
                alphaDevice.id: makeTestState(
                    device: alphaDevice,
                    connection: "usb",
                    batteryPercent: 81,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800
                ),
                betaDevice.id: makeTestState(
                    device: betaDevice,
                    connection: "usb",
                    batteryPercent: 77,
                    dpiValues: [1000, 2000, 3000],
                    activeStage: 0,
                    dpiValue: 1000
                ),
            ]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .service, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()

        await MainActor.run {
            appState.deviceStore.selectDevice(betaDevice.id)
            appState.runtimeStore.setCompactMenuPresented(true)
            appState.runtimeStore.recordRemoteClientPresence(
                CrossProcessClientPresence(sourceProcessID: 99, selectedDeviceID: alphaDevice.id),
                now: Date()
            )
        }
        await backend.setFastSnapshot(DpiFastSnapshot(active: 2, values: [800, 1600, 5200]), for: alphaDevice.id)

        await appState.deviceStore.refreshDpiFast()

        let selectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }
        let selectedDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }
        let activeStage = await MainActor.run { appState.editorStore.editableActiveStage }

        XCTAssertEqual(selectedDeviceID, alphaDevice.id)
        XCTAssertEqual(selectedDpi, 5200)
        XCTAssertEqual(activeStage, 3)
    }
}

private actor MultiDeviceStubBackend: DeviceBackend {
    nonisolated var usesRemoteServiceTransport: Bool { false }

    private let devices: [MouseDevice]
    private var stateByDeviceID: [String: MouseState]
    private var fastByDeviceID: [String: DpiFastSnapshot]
    private var readOrder: [String] = []

    init(devices: [MouseDevice], stateByDeviceID: [String: MouseState]) {
        self.devices = devices
        self.stateByDeviceID = stateByDeviceID
        self.fastByDeviceID = stateByDeviceID.reduce(into: [:]) { partialResult, entry in
            if let active = entry.value.dpi_stages.active_stage,
               let values = entry.value.dpi_stages.values {
                partialResult[entry.key] = DpiFastSnapshot(active: active, values: values)
            }
        }
    }

    func listDevices() async throws -> [MouseDevice] {
        devices
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        readOrder.append(device.id)
        guard let state = stateByDeviceID[device.id] else {
            throw NSError(domain: "AppStateMultiDeviceTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing stub state for \(device.id)"
            ])
        }
        return state
    }

    func readDpiStagesFast(device: MouseDevice) async throws -> DpiFastSnapshot? {
        fastByDeviceID[device.id]
    }

    func shouldUseFastDPIPolling(device _: MouseDevice) async -> Bool {
        true
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

    func apply(device _: MouseDevice, patch _: DevicePatch) async throws -> MouseState {
        throw NSError(domain: "AppStateMultiDeviceTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "apply not implemented"
        ])
    }

    func readLightingColor(device _: MouseDevice) async throws -> RGBPatch? {
        nil
    }

    func debugUSBReadButtonBinding(device _: MouseDevice, slot _: Int, profile _: Int) async throws -> [UInt8]? {
        nil
    }

    func recordedReadOrder() -> [String] {
        readOrder
    }

    func readCount() -> Int {
        readOrder.count
    }

    func setState(_ state: MouseState, for deviceID: String) {
        stateByDeviceID[deviceID] = state
        if let active = state.dpi_stages.active_stage,
           let values = state.dpi_stages.values {
            fastByDeviceID[deviceID] = DpiFastSnapshot(active: active, values: values)
        }
    }

    func setFastSnapshot(_ snapshot: DpiFastSnapshot, for deviceID: String) {
        fastByDeviceID[deviceID] = snapshot
    }
}

private actor PartiallyFailingMultiDeviceStubBackend: DeviceBackend {
    nonisolated var usesRemoteServiceTransport: Bool { false }

    private let devices: [MouseDevice]
    private let failingDeviceIDs: Set<String>
    private var stateByDeviceID: [String: MouseState]
    private var readOrder: [String] = []

    init(devices: [MouseDevice], stateByDeviceID: [String: MouseState], failingDeviceIDs: Set<String>) {
        self.devices = devices
        self.stateByDeviceID = stateByDeviceID
        self.failingDeviceIDs = failingDeviceIDs
    }

    func listDevices() async throws -> [MouseDevice] {
        devices
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        readOrder.append(device.id)
        if failingDeviceIDs.contains(device.id) {
            throw NSError(domain: "AppStateMultiDeviceTests", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "USB device telemetry unavailable. Feature-report interface did not return usable responses."
            ])
        }
        guard let state = stateByDeviceID[device.id] else {
            throw NSError(domain: "AppStateMultiDeviceTests", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Missing stub state for \(device.id)"
            ])
        }
        return state
    }

    func readDpiStagesFast(device _: MouseDevice) async throws -> DpiFastSnapshot? {
        nil
    }

    func shouldUseFastDPIPolling(device _: MouseDevice) async -> Bool {
        false
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

    func apply(device _: MouseDevice, patch _: DevicePatch) async throws -> MouseState {
        throw NSError(domain: "AppStateMultiDeviceTests", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "apply not implemented"
        ])
    }

    func readLightingColor(device _: MouseDevice) async throws -> RGBPatch? {
        nil
    }

    func debugUSBReadButtonBinding(device _: MouseDevice, slot _: Int, profile _: Int) async throws -> [UInt8]? {
        nil
    }

    func recordedReadOrder() -> [String] {
        readOrder
    }
}

private actor DisconnectingMultiDeviceStubBackend: DeviceBackend {
    nonisolated var usesRemoteServiceTransport: Bool { false }

    private let devices: [MouseDevice]
    private var stateByDeviceID: [String: MouseState]
    private var unavailable = false

    init(devices: [MouseDevice], stateByDeviceID: [String: MouseState]) {
        self.devices = devices
        self.stateByDeviceID = stateByDeviceID
    }

    func listDevices() async throws -> [MouseDevice] {
        devices
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        if unavailable {
            throw NSError(domain: "AppStateMultiDeviceTests", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "USB device telemetry unavailable. Feature-report interface did not return usable responses."
            ])
        }
        guard let state = stateByDeviceID[device.id] else {
            throw NSError(domain: "AppStateMultiDeviceTests", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Missing stub state for \(device.id)"
            ])
        }
        return state
    }

    func readDpiStagesFast(device _: MouseDevice) async throws -> DpiFastSnapshot? {
        nil
    }

    func shouldUseFastDPIPolling(device _: MouseDevice) async -> Bool {
        false
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

    func apply(device _: MouseDevice, patch _: DevicePatch) async throws -> MouseState {
        throw NSError(domain: "AppStateMultiDeviceTests", code: 8, userInfo: [
            NSLocalizedDescriptionKey: "apply not implemented"
        ])
    }

    func readLightingColor(device _: MouseDevice) async throws -> RGBPatch? {
        nil
    }

    func debugUSBReadButtonBinding(device _: MouseDevice, slot _: Int, profile _: Int) async throws -> [UInt8]? {
        nil
    }

    func setUnavailable(_ unavailable: Bool) {
        self.unavailable = unavailable
    }
}

private actor DeviceListUpdatingStubBackend: DeviceBackend {
    nonisolated var usesRemoteServiceTransport: Bool { false }

    private var devices: [MouseDevice]
    private var stateByDeviceID: [String: MouseState]
    private var usesFastDPIPolling: Bool
    private var dpiUpdateTransportStatusOverride: DpiUpdateTransportStatus?
    private var hidAccessAuthorization: HIDAccessAuthorization
    private var readCountByDeviceID: [String: Int] = [:]
    private var applyPatches: [DevicePatch] = []
    private var applyDeviceIDs: [String] = []
    private let stateUpdateStreamPair = AsyncStream.makeStream(of: BackendStateUpdate.self)

    init(
        devices: [MouseDevice],
        stateByDeviceID: [String: MouseState],
        shouldUseFastDPIPolling: Bool = false,
        dpiUpdateTransportStatus: DpiUpdateTransportStatus? = nil,
        hidAccessAuthorization: HIDAccessAuthorization = .granted
    ) {
        self.devices = devices
        self.stateByDeviceID = stateByDeviceID
        self.usesFastDPIPolling = shouldUseFastDPIPolling
        self.dpiUpdateTransportStatusOverride = dpiUpdateTransportStatus
        self.hidAccessAuthorization = hidAccessAuthorization
    }

    func listDevices() async throws -> [MouseDevice] {
        devices
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        readCountByDeviceID[device.id, default: 0] += 1
        guard let state = stateByDeviceID[device.id] else {
            throw NSError(domain: "AppStateMultiDeviceTests", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Missing stub state for \(device.id)"
            ])
        }
        return state
    }

    func readDpiStagesFast(device: MouseDevice) async throws -> DpiFastSnapshot? {
        guard let state = stateByDeviceID[device.id],
              let active = state.dpi_stages.active_stage,
              let values = state.dpi_stages.values else {
            return nil
        }
        return DpiFastSnapshot(active: active, values: values)
    }

    func shouldUseFastDPIPolling(device _: MouseDevice) async -> Bool {
        usesFastDPIPolling
    }

    func dpiUpdateTransportStatus(device _: MouseDevice) async -> DpiUpdateTransportStatus {
        dpiUpdateTransportStatusOverride ?? (usesFastDPIPolling ? .pollingFallback : .realTimeHID)
    }

    func hidAccessStatus() async -> HIDAccessStatus {
        HIDAccessStatus(
            authorization: hidAccessAuthorization,
            hostLabel: "Test Host (io.opensnek.OpenSnek)",
            bundleIdentifier: "io.opensnek.OpenSnek",
            detail: nil
        )
    }

    func stateUpdates() async -> AsyncStream<BackendStateUpdate> {
        stateUpdateStreamPair.stream
    }

    func apply(device: MouseDevice, patch: DevicePatch) async throws -> MouseState {
        applyDeviceIDs.append(device.id)
        applyPatches.append(patch)
        guard let current = stateByDeviceID[device.id] else {
            throw NSError(domain: "AppStateMultiDeviceTests", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Missing apply state for \(device.id)"
            ])
        }
        let next = stateApplying(patch, to: current)
        stateByDeviceID[device.id] = next
        return next
    }

    func readLightingColor(device _: MouseDevice) async throws -> RGBPatch? {
        nil
    }

    func debugUSBReadButtonBinding(device _: MouseDevice, slot _: Int, profile _: Int) async throws -> [UInt8]? {
        nil
    }

    func setState(_ state: MouseState, for deviceID: String) {
        stateByDeviceID[deviceID] = state
    }

    func emitDeviceListUpdate(_ devices: [MouseDevice], updatedAt: Date = Date()) {
        self.devices = devices
        stateUpdateStreamPair.continuation.yield(.deviceList(devices, updatedAt: updatedAt))
    }

    func setShouldUseFastDPIPolling(_ value: Bool) {
        usesFastDPIPolling = value
    }

    func setDpiUpdateTransportStatus(_ value: DpiUpdateTransportStatus?) {
        dpiUpdateTransportStatusOverride = value
    }

    func readCount(for deviceID: String) -> Int {
        readCountByDeviceID[deviceID] ?? 0
    }

    func applyCount() -> Int {
        applyPatches.count
    }

    func recordedPatches() -> [DevicePatch] {
        applyPatches
    }

    func recordedApplyDeviceIDs() -> [String] {
        applyDeviceIDs
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

private func makeTestDevice(
    id: String,
    productName: String,
    transport: DeviceTransportKind,
    serial: String,
    locationID: Int,
    profile: DeviceProfileID
) -> MouseDevice {
    MouseDevice(
        id: id,
        vendor_id: 0x1532,
        product_id: transport == .bluetooth ? 0x00BA : 0x00AB,
        product_name: productName,
        transport: transport,
        path_b64: "",
        serial: serial,
        firmware: "1.0.0",
        location_id: locationID,
        profile_id: profile,
        supports_advanced_lighting_effects: true,
        onboard_profile_count: 1
    )
}

private func makeTestState(
    device: MouseDevice,
    connection: String,
    batteryPercent: Int,
    dpiValues: [Int],
    activeStage: Int,
    dpiValue: Int
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
        poll_rate: 1000,
        device_mode: DeviceMode(mode: 0x00, param: 0x00),
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

private func clearMultiDeviceLightingPreferences(for device: MouseDevice) {
    let defaults = UserDefaults.standard
    let key = DevicePersistenceKeys.key(for: device)
    let legacyKey = DevicePersistenceKeys.legacyKey(for: device)
    let keys = [
        "lightingColor.\(key)",
        "lightingColor.\(legacyKey)",
        "lightingZone.\(key)",
        "lightingZone.\(legacyKey)",
        "lightingEffect.\(key)",
        "lightingEffect.\(legacyKey)",
    ]
    for key in keys {
        defaults.removeObject(forKey: key)
    }
}

private func waitForAppStateCondition(
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
            throw NSError(domain: "AppStateMultiDeviceTests", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Timed out waiting for AppState condition"
            ])
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw NSError(domain: "AppStateMultiDeviceTests", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Timed out waiting for AppState condition"
            ])
        }

        _ = try await group.next()
        group.cancelAll()
    }
}
