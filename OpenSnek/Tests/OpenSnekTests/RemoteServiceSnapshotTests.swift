import Foundation
import XCTest
import OpenSnekCore
@testable import OpenSnek

final class RemoteServiceSnapshotTests: XCTestCase {
    func testLocalBridgeMergedApplyStatePreservesBatteryAcrossBluetoothDelta() {
        let previous = makeSnapshotState(
            device: makeSnapshotDevice(
                id: "delta-device",
                productName: "Delta Mouse",
                transport: .bluetooth,
                serial: "DELTA",
                locationID: 9,
                profile: .basiliskV3Pro
            ),
            connection: "bluetooth",
            batteryPercent: 83,
            dpiValues: [800, 1600, 2400],
            activeStage: 1,
            dpiValue: 1600
        )
        let delta = MouseState(
            device: previous.device,
            connection: previous.connection,
            battery_percent: nil,
            charging: nil,
            dpi: nil,
            dpi_stages: DpiStages(active_stage: nil, values: nil),
            poll_rate: nil,
            sleep_timeout: nil,
            device_mode: nil,
            low_battery_threshold_raw: nil,
            scroll_mode: nil,
            scroll_acceleration: nil,
            scroll_smart_reel: nil,
            active_onboard_profile: nil,
            onboard_profile_count: nil,
            led_value: 20,
            capabilities: previous.capabilities
        )

        let merged = LocalBridgeBackend.mergedApplyState(delta, previous: previous)

        XCTAssertEqual(merged.battery_percent, 83)
        XCTAssertEqual(merged.charging, false)
        XCTAssertEqual(merged.led_value, 20)
    }

    func testRemoteServiceBackendUsesRemoteTransport() async {
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: SnapshotTestRemoteBackend(), autoStart: false)
        }

        let usesRemoteTransport = await MainActor.run { appState.environment.usesRemoteServiceTransport }
        XCTAssertTrue(usesRemoteTransport)
    }

    func testApplyRemoteServiceSnapshotHydratesSelectedState() async {
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: SnapshotTestRemoteBackend(), autoStart: false)
        }

        let device = makeSnapshotDevice(
            id: "snapshot-device",
            productName: "Snapshot Mouse",
            transport: .usb,
            serial: "SNAPSHOT",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let state = makeSnapshotState(
            device: device,
            connection: "usb",
            batteryPercent: 81,
            dpiValues: [800, 2400, 6400],
            activeStage: 1,
            dpiValue: 2400
        )
        let snapshot = SharedServiceSnapshot(
            devices: [device],
            stateByDeviceID: [device.id: state],
            lastUpdatedByDeviceID: [device.id: Date(timeIntervalSince1970: 1_773_320_000)]
        )

        await MainActor.run {
            appState.deviceStore.applyRemoteServiceSnapshot(snapshot)
        }

        let selectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }
        let selectedDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }
        let activeStage = await MainActor.run { appState.editorStore.editableActiveStage }
        let pollRate = await MainActor.run { appState.editorStore.editablePollRate }

        XCTAssertEqual(selectedDeviceID, device.id)
        XCTAssertEqual(selectedDpi, 2400)
        XCTAssertEqual(activeStage, 2)
        XCTAssertEqual(pollRate, 1000)
    }

    func testApplyingLaterSnapshotKeepsExistingLocalSelection() async {
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: SnapshotTestRemoteBackend(), autoStart: false)
        }

        let bluetoothDevice = makeSnapshotDevice(
            id: "bluetooth-device",
            productName: "A Bluetooth Mouse",
            transport: .bluetooth,
            serial: "BT",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let usbDevice = makeSnapshotDevice(
            id: "usb-device",
            productName: "Z USB Mouse",
            transport: .usb,
            serial: "USB",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let initialSnapshot = SharedServiceSnapshot(
            devices: [bluetoothDevice, usbDevice],
            stateByDeviceID: [
                bluetoothDevice.id: makeSnapshotState(
                    device: bluetoothDevice,
                    connection: "bluetooth",
                    batteryPercent: 74,
                    dpiValues: [1200, 2400, 3200],
                    activeStage: 2,
                    dpiValue: 3200
                ),
                usbDevice.id: makeSnapshotState(
                    device: usbDevice,
                    connection: "usb",
                    batteryPercent: 81,
                    dpiValues: [800, 2400, 6400],
                    activeStage: 1,
                    dpiValue: 2400
                ),
            ],
            lastUpdatedByDeviceID: [
                bluetoothDevice.id: Date(timeIntervalSince1970: 1_773_320_010),
                usbDevice.id: Date(timeIntervalSince1970: 1_773_320_000),
            ]
        )
        let laterSnapshot = SharedServiceSnapshot(
            devices: [bluetoothDevice, usbDevice],
            stateByDeviceID: [
                bluetoothDevice.id: makeSnapshotState(
                    device: bluetoothDevice,
                    connection: "bluetooth",
                    batteryPercent: 75,
                    dpiValues: [1400, 2800, 4200],
                    activeStage: 2,
                    dpiValue: 4200
                ),
                usbDevice.id: makeSnapshotState(
                    device: usbDevice,
                    connection: "usb",
                    batteryPercent: 82,
                    dpiValues: [900, 1800, 3600],
                    activeStage: 0,
                    dpiValue: 900
                ),
            ],
            lastUpdatedByDeviceID: [
                bluetoothDevice.id: Date(timeIntervalSince1970: 1_773_320_020),
                usbDevice.id: Date(timeIntervalSince1970: 1_773_320_021),
            ]
        )

        await MainActor.run {
            appState.deviceStore.applyRemoteServiceSnapshot(initialSnapshot)
            appState.deviceStore.selectDevice(usbDevice.id)
            appState.deviceStore.applyRemoteServiceSnapshot(laterSnapshot)
        }

        let selectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }
        let selectedDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }
        let selectedBattery = await MainActor.run { appState.deviceStore.state?.battery_percent }
        let activeStage = await MainActor.run { appState.editorStore.editableActiveStage }

        XCTAssertEqual(selectedDeviceID, usbDevice.id)
        XCTAssertEqual(selectedDpi, 900)
        XCTAssertEqual(selectedBattery, 82)
        XCTAssertEqual(activeStage, 1)
    }

    func testCurrentDeviceStatusUsesSelectedDeviceFreshnessFromSnapshotCache() async {
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: SnapshotTestRemoteBackend(), autoStart: false)
        }

        let alphaDevice = makeSnapshotDevice(
            id: "alpha-device",
            productName: "Alpha Mouse",
            transport: .usb,
            serial: "ALPHA",
            locationID: 1,
            profile: .basiliskV3Pro
        )
        let betaDevice = makeSnapshotDevice(
            id: "beta-device",
            productName: "Beta Mouse",
            transport: .usb,
            serial: "BETA",
            locationID: 2,
            profile: .basiliskV3XHyperspeed
        )
        let snapshot = SharedServiceSnapshot(
            devices: [alphaDevice, betaDevice],
            stateByDeviceID: [
                alphaDevice.id: makeSnapshotState(
                    device: alphaDevice,
                    connection: "usb",
                    batteryPercent: 70,
                    dpiValues: [800, 1600, 2400],
                    activeStage: 0,
                    dpiValue: 800
                ),
                betaDevice.id: makeSnapshotState(
                    device: betaDevice,
                    connection: "usb",
                    batteryPercent: 72,
                    dpiValues: [1000, 2000, 3000],
                    activeStage: 1,
                    dpiValue: 2000
                ),
            ],
            lastUpdatedByDeviceID: [
                alphaDevice.id: Date(timeIntervalSince1970: 1_700_000_000),
                betaDevice.id: Date(),
            ]
        )

        await MainActor.run {
            appState.deviceStore.applyRemoteServiceSnapshot(snapshot)
            appState.deviceStore.selectDevice(alphaDevice.id)
        }
        let staleLabel = await MainActor.run { appState.deviceStore.currentDeviceStatusIndicator.label }

        await MainActor.run {
            appState.deviceStore.selectDevice(betaDevice.id)
        }
        let freshLabel = await MainActor.run { appState.deviceStore.currentDeviceStatusIndicator.label }

        XCTAssertEqual(staleLabel, "Reconnecting")
        XCTAssertEqual(freshLabel, "Connected")
    }

    func testOlderRemoteSnapshotDoesNotOverwriteNewerPerDeviceState() async {
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: SnapshotTestRemoteBackend(), autoStart: false)
        }

        let device = makeSnapshotDevice(
            id: "bt-snapshot-stale",
            productName: "Snapshot BT Mouse",
            transport: .bluetooth,
            serial: "BT-SNAPSHOT",
            locationID: 3,
            profile: .basiliskV3XHyperspeed
        )
        let newerSnapshot = SharedServiceSnapshot(
            devices: [device],
            stateByDeviceID: [
                device.id: makeSnapshotState(
                    device: device,
                    connection: "bluetooth",
                    batteryPercent: 75,
                    dpiValues: [800, 900, 1000, 1100, 1500],
                    activeStage: 3,
                    dpiValue: 1100
                )
            ],
            lastUpdatedByDeviceID: [
                device.id: Date(timeIntervalSince1970: 1_773_520_020)
            ]
        )
        let olderSnapshot = SharedServiceSnapshot(
            devices: [device],
            stateByDeviceID: [
                device.id: makeSnapshotState(
                    device: device,
                    connection: "bluetooth",
                    batteryPercent: 74,
                    dpiValues: [800, 900, 1000, 1100, 1500],
                    activeStage: 1,
                    dpiValue: 900
                )
            ],
            lastUpdatedByDeviceID: [
                device.id: Date(timeIntervalSince1970: 1_773_520_010)
            ]
        )

        await MainActor.run {
            appState.deviceStore.applyRemoteServiceSnapshot(newerSnapshot)
            appState.deviceStore.applyRemoteServiceSnapshot(olderSnapshot)
        }

        let selectedDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }
        let selectedBattery = await MainActor.run { appState.deviceStore.state?.battery_percent }
        let activeStage = await MainActor.run { appState.editorStore.editableActiveStage }

        XCTAssertEqual(selectedDpi, 1100)
        XCTAssertEqual(selectedBattery, 75)
        XCTAssertEqual(activeStage, 4)
    }

    func testRemoteServiceStartBootstrapsSelectedStateBeforeFirstSnapshot() async throws {
        let suiteName = "RemoteServiceSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let backend = RemoteBootstrapServiceBackend()
        let host = try BackgroundServiceHost(backend: backend, defaults: defaults)
        try await host.start()
        defer { host.stop() }

        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: UserDefaults(suiteName: suiteName)!)
        }
        let appState = await MainActor.run {
            AppState(launchRole: .app, serviceCoordinator: coordinator, autoStart: false)
        }

        await MainActor.run {
            appState.environment.hasCheckedForUpdates = true
        }
        await appState.runtimeStore.start()

        let selectedDeviceID = await MainActor.run { appState.deviceStore.selectedDeviceID }
        let selectedBattery = await MainActor.run { appState.deviceStore.state?.battery_percent }
        let selectedDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }

        XCTAssertEqual(selectedDeviceID, RemoteBootstrapServiceBackend.device.id)
        XCTAssertEqual(selectedBattery, 83)
        XCTAssertEqual(selectedDpi, 1600)
    }

    func testRemoteServiceAppliesPushedSnapshotUpdatesOverTCPAfterBootstrap() async throws {
        let suiteName = "RemoteServiceSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let backend = RemoteBootstrapServiceBackend()
        let (subscriptionStream, subscriptionContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { subscriptionContinuation.finish() }

        let host = try BackgroundServiceHost(
            backend: backend,
            defaults: defaults,
            remoteClientPresenceHandler: { _ in
                subscriptionContinuation.yield(())
            }
        )
        try await host.start()
        defer { host.stop() }

        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: UserDefaults(suiteName: suiteName)!)
        }
        let appState = await MainActor.run {
            AppState(launchRole: .app, serviceCoordinator: coordinator, autoStart: false)
        }

        await MainActor.run {
            appState.environment.hasCheckedForUpdates = true
        }
        await appState.runtimeStore.start()

        var subscriptionIterator = subscriptionStream.makeAsyncIterator()
        _ = await subscriptionIterator.next()
        let bootstrappedUpdatedAt = await MainActor.run { appState.deviceStore.lastUpdated ?? Date() }

        let updatedState = makeSnapshotState(
            device: RemoteBootstrapServiceBackend.device,
            connection: "bluetooth",
            batteryPercent: 79,
            dpiValues: [1000, 2000, 3000],
            activeStage: 2,
            dpiValue: 3000
        )
        await backend.emit(
            .snapshot(
                SharedServiceSnapshot(
                    devices: [RemoteBootstrapServiceBackend.device],
                    stateByDeviceID: [RemoteBootstrapServiceBackend.device.id: updatedState],
                    lastUpdatedByDeviceID: [RemoteBootstrapServiceBackend.device.id: bootstrappedUpdatedAt.addingTimeInterval(1)]
                )
            )
        )

        try await waitUntil {
            await MainActor.run {
                appState.deviceStore.state?.dpi?.x == 3000 &&
                    appState.deviceStore.state?.battery_percent == 79
            }
        }

        let selectedDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }
        let selectedBattery = await MainActor.run { appState.deviceStore.state?.battery_percent }
        XCTAssertEqual(selectedDpi, 3000)
        XCTAssertEqual(selectedBattery, 79)
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollInterval: UInt64 = 20_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollInterval)
        }
        XCTFail("Timed out waiting for condition")
    }
}

private func makeSnapshotDevice(
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

private func makeSnapshotState(
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

private final class SnapshotTestRemoteBackend: DeviceBackend {
    var usesRemoteServiceTransport: Bool { true }

    func listDevices() async throws -> [MouseDevice] { [] }
    func readState(device _: MouseDevice) async throws -> MouseState { throw SnapshotBackendError.unimplemented }
    func readDpiStagesFast(device _: MouseDevice) async throws -> DpiFastSnapshot? { nil }
    func shouldUseFastDPIPolling(device _: MouseDevice) async -> Bool { false }
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
    func apply(device _: MouseDevice, patch _: DevicePatch) async throws -> MouseState { throw SnapshotBackendError.unimplemented }
    func readLightingColor(device _: MouseDevice) async throws -> RGBPatch? { nil }
    func debugUSBReadButtonBinding(device _: MouseDevice, slot _: Int, profile _: Int) async throws -> [UInt8]? { nil }
}

private actor RemoteBootstrapServiceBackend: DeviceBackend {
    nonisolated var usesRemoteServiceTransport: Bool { false }

    nonisolated static let device = MouseDevice(
        id: "remote-bootstrap-device",
        vendor_id: 0x068E,
        product_id: 0x00AC,
        product_name: "Bootstrap Mouse",
        transport: .bluetooth,
        path_b64: "",
        serial: "BOOTSTRAP",
        firmware: "1.0.0",
        location_id: 1,
        profile_id: .basiliskV3Pro,
        supports_advanced_lighting_effects: true,
        onboard_profile_count: 1
    )

    private let stateUpdatesStream: AsyncStream<BackendStateUpdate>
    private let stateUpdatesContinuation: AsyncStream<BackendStateUpdate>.Continuation

    private let state = MouseState(
        device: DeviceSummary(
            id: "remote-bootstrap-device",
            product_name: "Bootstrap Mouse",
            serial: "BOOTSTRAP",
            transport: .bluetooth,
            firmware: "1.0.0"
        ),
        connection: "bluetooth",
        battery_percent: 83,
        charging: false,
        dpi: DpiPair(x: 1600, y: 1600),
        dpi_stages: DpiStages(active_stage: 1, values: [800, 1600, 2400]),
        poll_rate: nil,
        sleep_timeout: 300,
        device_mode: nil,
        led_value: 64,
        capabilities: Capabilities(
            dpi_stages: true,
            poll_rate: false,
            power_management: true,
            button_remap: true,
            lighting: true
        )
    )

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: BackendStateUpdate.self)
        stateUpdatesStream = stream
        stateUpdatesContinuation = continuation
    }

    func listDevices() async throws -> [MouseDevice] { [Self.device] }
    func readState(device _: MouseDevice) async throws -> MouseState { state }
    func readDpiStagesFast(device _: MouseDevice) async throws -> DpiFastSnapshot? {
        DpiFastSnapshot(active: 1, values: [800, 1600, 2400])
    }
    func shouldUseFastDPIPolling(device _: MouseDevice) async -> Bool { false }
    func hidAccessStatus() async -> HIDAccessStatus {
        HIDAccessStatus(
            authorization: .granted,
            hostLabel: "Test Host (io.opensnek.OpenSnek)",
            bundleIdentifier: "io.opensnek.OpenSnek",
            detail: nil
        )
    }
    func stateUpdates() async -> AsyncStream<BackendStateUpdate> {
        stateUpdatesStream
    }
    func emit(_ update: BackendStateUpdate) {
        stateUpdatesContinuation.yield(update)
    }
    func apply(device _: MouseDevice, patch _: DevicePatch) async throws -> MouseState { state }
    func readLightingColor(device _: MouseDevice) async throws -> RGBPatch? { RGBPatch(r: 12, g: 34, b: 56) }
    func debugUSBReadButtonBinding(device _: MouseDevice, slot _: Int, profile _: Int) async throws -> [UInt8]? { nil }
}

private enum SnapshotBackendError: Error {
    case unimplemented
}
