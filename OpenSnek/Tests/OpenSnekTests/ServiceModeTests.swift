import Foundation
import XCTest
import OpenSnekCore
@testable import OpenSnek

final class ServiceModeTests: XCTestCase {
    func testPollingProfileIntervalsMatchExpectedCadence() {
        XCTAssertEqual(PollingProfile.foreground.refreshStateInterval, 2.0)
        XCTAssertEqual(PollingProfile.foreground.devicePresenceInterval, 1.2)
        XCTAssertEqual(PollingProfile.foreground.fastDpiInterval, 0.20)

        XCTAssertEqual(PollingProfile.serviceIdle.refreshStateInterval, 8.0)
        XCTAssertEqual(PollingProfile.serviceIdle.devicePresenceInterval, 4.0)
        XCTAssertNil(PollingProfile.serviceIdle.fastDpiInterval)

        XCTAssertEqual(PollingProfile.serviceInteractive.refreshStateInterval, 2.0)
        XCTAssertEqual(PollingProfile.serviceInteractive.devicePresenceInterval, 1.2)
        XCTAssertEqual(PollingProfile.serviceInteractive.fastDpiInterval, 0.25)
    }

    func testServiceRoleTransitionsBetweenIdleAndInteractiveProfiles() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: defaults)
        }
        let appState = await MainActor.run {
            AppState(launchRole: .service, serviceCoordinator: coordinator, autoStart: false)
        }

        let initial = await MainActor.run { appState.runtimeStore.currentPollingProfile }
        XCTAssertEqual(initial, .serviceIdle)

        await MainActor.run {
            appState.runtimeStore.setCompactMenuPresented(true)
        }
        let interactive = await MainActor.run { appState.runtimeStore.currentPollingProfile }
        XCTAssertEqual(interactive, .serviceInteractive)

        await MainActor.run {
            appState.runtimeStore.setCompactMenuPresented(false)
        }
        let afterClose = await MainActor.run { appState.runtimeStore.currentPollingProfile }
        XCTAssertEqual(afterClose, .serviceInteractive)
    }

    func testWindowedAppAlwaysUsesForegroundProfile() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(defaults: defaults)
        }
        let appState = await MainActor.run {
            AppState(launchRole: .app, serviceCoordinator: coordinator, autoStart: false)
        }

        let profile = await MainActor.run { appState.runtimeStore.currentPollingProfile }
        XCTAssertEqual(profile, .foreground)
    }

    func testRuntimeWakeScheduleBacksOffToIdlePresenceDeadline() {
        let now = Date(timeIntervalSince1970: 1_773_400_000)

        let sleep = RuntimeWakeSchedule.nextSleepInterval(
            now: now,
            profile: .serviceIdle,
            fastDpiInterval: nil,
            usesRemoteServiceUpdates: false,
            lastDevicePresencePollAt: now,
            lastRefreshStatePollAt: now,
            lastFastDpiPollAt: now,
            lastRemoteClientPresencePingAt: .distantPast,
            transientStatusUntil: nil,
            nextRemoteClientPresenceExpiry: nil
        )

        XCTAssertEqual(sleep, 4.0, accuracy: 0.001)
    }

    func testRuntimeWakeScheduleKeepsInteractiveFastPollingCadence() {
        let now = Date(timeIntervalSince1970: 1_773_400_100)

        let sleep = RuntimeWakeSchedule.nextSleepInterval(
            now: now,
            profile: .serviceInteractive,
            fastDpiInterval: PollingProfile.serviceInteractive.fastDpiInterval,
            usesRemoteServiceUpdates: false,
            lastDevicePresencePollAt: now,
            lastRefreshStatePollAt: now,
            lastFastDpiPollAt: now,
            lastRemoteClientPresencePingAt: .distantPast,
            transientStatusUntil: nil,
            nextRemoteClientPresenceExpiry: nil
        )

        XCTAssertEqual(sleep, 0.25, accuracy: 0.001)
    }

    func testRuntimeWakeScheduleUsesRemotePresencePingDeadline() {
        let now = Date(timeIntervalSince1970: 1_773_400_200)

        let sleep = RuntimeWakeSchedule.nextSleepInterval(
            now: now,
            profile: .foreground,
            fastDpiInterval: PollingProfile.foreground.fastDpiInterval,
            usesRemoteServiceUpdates: true,
            lastDevicePresencePollAt: .distantPast,
            lastRefreshStatePollAt: .distantPast,
            lastFastDpiPollAt: .distantPast,
            lastRemoteClientPresencePingAt: now,
            transientStatusUntil: nil,
            nextRemoteClientPresenceExpiry: nil
        )

        XCTAssertEqual(sleep, 1.0, accuracy: 0.001)
    }

    func testHIDAccessStatusDeniedUsesExpectedDiagnosticsAndResetCommand() {
        let status = HIDAccessStatus(
            authorization: .denied,
            hostLabel: "OpenSnek (io.opensnek.OpenSnek)",
            bundleIdentifier: "io.opensnek.OpenSnek",
            detail: "Input Monitoring is required."
        )

        XCTAssertTrue(status.isDenied)
        XCTAssertEqual(status.diagnosticsLabel, "Denied")
        XCTAssertEqual(
            PermissionSupport.permissionResetCommand(bundleIdentifier: status.bundleIdentifier),
            "tccutil reset All io.opensnek.OpenSnek"
        )
    }

    @MainActor
    func testServiceIdleKeepsSlowFastPollingForSelectedFallbackDevice() async {
        let backend = ServiceModeTransportBackend(transportStatus: .pollingFallback)
        let appState = AppState(launchRole: .service, backend: backend, autoStart: false)
        let device = backend.device

        _ = appState.deviceController.applyDeviceList([device], source: "test")
        await appState.deviceController.refreshConnectionDiagnostics(for: device)

        XCTAssertEqual(
            appState.runtimeStore.activeFastPollingDeviceIDs(at: Date()),
            [device.id]
        )
        XCTAssertEqual(
            appState.runtimeController.effectiveFastDpiInterval(at: Date()),
            1.0
        )
    }

    @MainActor
    func testServiceIdleDoesNotFastPollWhilePassiveHIDIsListening() async {
        let backend = ServiceModeTransportBackend(transportStatus: .listening)
        let appState = AppState(launchRole: .service, backend: backend, autoStart: false)
        let device = backend.device

        _ = appState.deviceController.applyDeviceList([device], source: "test")
        await appState.deviceController.refreshConnectionDiagnostics(for: device)

        XCTAssertEqual(
            appState.runtimeStore.activeFastPollingDeviceIDs(at: Date()),
            []
        )
        XCTAssertNil(appState.runtimeController.effectiveFastDpiInterval(at: Date()))
    }

    @MainActor
    func testServiceIdleDoesNotFastPollWhilePassiveHIDStreamIsActive() async {
        let backend = ServiceModeTransportBackend(transportStatus: .streamActive)
        let appState = AppState(launchRole: .service, backend: backend, autoStart: false)
        let device = backend.device

        _ = appState.deviceController.applyDeviceList([device], source: "test")
        await appState.deviceController.refreshConnectionDiagnostics(for: device)

        XCTAssertEqual(
            appState.runtimeStore.activeFastPollingDeviceIDs(at: Date()),
            []
        )
        XCTAssertNil(appState.runtimeController.effectiveFastDpiInterval(at: Date()))
    }

    @MainActor
    func testServiceIdleKeepsSlowFastPollingWhilePassiveHIDRealtimeIsActive() async {
        let backend = ServiceModeTransportBackend(
            transportStatus: .realTimeHID,
            device: makeServiceModeDevice(id: "service-test-usb-device", transport: .usb, productID: 0x00AB)
        )
        let appState = AppState(launchRole: .service, backend: backend, autoStart: false)
        let device = backend.device

        _ = appState.deviceController.applyDeviceList([device], source: "test")
        await appState.deviceController.refreshConnectionDiagnostics(for: device)

        XCTAssertEqual(
            appState.runtimeStore.activeFastPollingDeviceIDs(at: Date()),
            [device.id]
        )
        XCTAssertEqual(
            appState.runtimeController.effectiveFastDpiInterval(at: Date()),
            1.0
        )
    }

    @MainActor
    func testServiceInteractiveDoesNotScheduleFastPollingWithoutFallbackCandidates() async {
        let backend = ServiceModeTransportBackend(transportStatus: .streamActive)
        let appState = AppState(launchRole: .service, backend: backend, autoStart: false)
        let device = backend.device
        let now = Date(timeIntervalSince1970: 1_773_400_250)

        _ = appState.deviceController.applyDeviceList([device], source: "test")
        await appState.deviceController.refreshConnectionDiagnostics(for: device)
        appState.runtimeController.setCompactMenuPresented(true)

        XCTAssertEqual(appState.runtimeStore.currentPollingProfile, .serviceInteractive)
        XCTAssertEqual(appState.runtimeStore.activeFastPollingDeviceIDs(at: now), [])
        XCTAssertNil(appState.runtimeController.effectiveFastDpiInterval(at: now))
        XCTAssertEqual(
            appState.runtimeController.runtimeSleepInterval(after: now),
            RuntimeWakeSchedule.minimumSleepInterval,
            accuracy: 0.001
        )
    }

    @MainActor
    func testRemoteClientPresenceDoesNotScheduleFastPollingWithoutFallbackCandidates() async {
        let backend = ServiceModeTransportBackend(transportStatus: .streamActive)
        let appState = AppState(launchRole: .service, backend: backend, autoStart: false)
        let device = backend.device
        let now = Date(timeIntervalSince1970: 1_773_400_275)

        _ = appState.deviceController.applyDeviceList([device], source: "test")
        await appState.deviceController.refreshConnectionDiagnostics(for: device)
        appState.runtimeController.recordRemoteClientPresence(
            CrossProcessClientPresence(sourceProcessID: 42, selectedDeviceID: device.id),
            now: now
        )

        XCTAssertEqual(appState.runtimeStore.pollingProfile(at: now), .serviceInteractive)
        XCTAssertEqual(appState.runtimeStore.activeFastPollingDeviceIDs(at: now), [])
        XCTAssertNil(appState.runtimeController.effectiveFastDpiInterval(at: now))
    }

    @MainActor
    func testSystemSleepSuspendsRuntimePollingUntilWake() async {
        let backend = ServiceModeTransportBackend(transportStatus: .pollingFallback)
        let appState = AppState(launchRole: .service, backend: backend, autoStart: false)
        let now = Date(timeIntervalSince1970: 1_773_400_300)

        appState.runtimeController.handleSystemWillSleep(now: now)
        XCTAssertEqual(
            appState.runtimeController.runtimeSleepInterval(after: now),
            RuntimeWakeSchedule.suspendedForSleepInterval,
            accuracy: 0.001
        )

        appState.runtimeController.handleSystemDidWake(now: now.addingTimeInterval(30))
        XCTAssertEqual(
            appState.runtimeController.runtimeSleepInterval(after: now.addingTimeInterval(30)),
            RuntimeWakeSchedule.minimumSleepInterval,
            accuracy: 0.001
        )
    }

    @MainActor
    func testSystemSleepClearsRemotePresenceSoWakeResumesIdle() async {
        let backend = ServiceModeTransportBackend(transportStatus: .realTimeHID)
        let appState = AppState(launchRole: .service, backend: backend, autoStart: false)
        let now = Date(timeIntervalSince1970: 1_773_400_400)

        appState.runtimeController.recordRemoteClientPresence(
            CrossProcessClientPresence(sourceProcessID: 42, selectedDeviceID: backend.device.id),
            now: now
        )
        XCTAssertEqual(appState.runtimeStore.pollingProfile(at: now), .serviceInteractive)

        appState.runtimeController.handleSystemWillSleep(now: now.addingTimeInterval(1))
        appState.runtimeController.handleSystemDidWake(now: now.addingTimeInterval(10))

        XCTAssertEqual(
            appState.runtimeStore.pollingProfile(at: now.addingTimeInterval(10)),
            .serviceIdle
        )
    }

    @MainActor
    func testSelectedDpiActivityPromotesServiceBackToInteractiveProfile() async {
        let backend = ServiceModeTransportBackend(transportStatus: .realTimeHID)
        let appState = AppState(launchRole: .service, backend: backend, autoStart: false)
        let device = backend.device
        let previous = try! await backend.readState(device: device)
        let next = MouseState(
            device: previous.device,
            connection: previous.connection,
            battery_percent: previous.battery_percent,
            charging: previous.charging,
            dpi: DpiPair(x: 3200, y: 3200),
            dpi_stages: DpiStages(active_stage: 2, values: [800, 1600, 3200]),
            poll_rate: previous.poll_rate,
            sleep_timeout: previous.sleep_timeout,
            device_mode: previous.device_mode,
            low_battery_threshold_raw: previous.low_battery_threshold_raw,
            scroll_mode: previous.scroll_mode,
            scroll_acceleration: previous.scroll_acceleration,
            scroll_smart_reel: previous.scroll_smart_reel,
            active_onboard_profile: previous.active_onboard_profile,
            onboard_profile_count: previous.onboard_profile_count,
            led_value: previous.led_value,
            capabilities: previous.capabilities
        )

        _ = appState.deviceController.applyDeviceList([device], source: "test")
        appState.deviceStore.selectedDeviceID = device.id
        appState.runtimeController.setCompactInteraction(until: nil)

        appState.runtimeController.updateStatusItemTransientDpi(
            previous: previous,
            next: next,
            deviceID: device.id
        )

        let queryNow = Date()
        XCTAssertEqual(appState.runtimeStore.pollingProfile(at: queryNow), .serviceInteractive)
        XCTAssertEqual(appState.runtimeStore.activeFastPollingDeviceIDs(at: queryNow), [device.id])
    }
}

private actor ServiceModeTransportBackend: DeviceBackend {
    nonisolated var usesRemoteServiceTransport: Bool { false }

    let device: MouseDevice

    private let transportStatus: DpiUpdateTransportStatus

    init(
        transportStatus: DpiUpdateTransportStatus,
        device: MouseDevice = makeServiceModeDevice(id: "service-test-device", transport: .bluetooth, productID: 0x00AC)
    ) {
        self.transportStatus = transportStatus
        self.device = device
    }

    func listDevices() async throws -> [MouseDevice] {
        [device]
    }

    func readState(device _: MouseDevice) async throws -> MouseState {
        MouseState(
            device: DeviceSummary(
                id: device.id,
                product_name: device.product_name,
                serial: device.serial,
                transport: device.transport,
                firmware: device.firmware
            ),
            connection: "Bluetooth",
            battery_percent: 80,
            charging: false,
            dpi: DpiPair(x: 1600, y: 1600),
            dpi_stages: DpiStages(active_stage: 1, values: [800, 1600, 3200]),
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
    }

    func readDpiStagesFast(device _: MouseDevice) async throws -> DpiFastSnapshot? {
        DpiFastSnapshot(active: 1, values: [800, 1600, 3200])
    }

    func shouldUseFastDPIPolling(device _: MouseDevice) async -> Bool {
        transportStatus != .realTimeHID
    }

    func dpiUpdateTransportStatus(device _: MouseDevice) async -> DpiUpdateTransportStatus {
        transportStatus
    }

    func hidAccessStatus() async -> HIDAccessStatus {
        .unknown()
    }

    func stateUpdates() async -> AsyncStream<BackendStateUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func apply(device targetDevice: MouseDevice, patch _: DevicePatch) async throws -> MouseState {
        try await readState(device: targetDevice)
    }

    func readLightingColor(device _: MouseDevice) async throws -> RGBPatch? {
        nil
    }

    func debugUSBReadButtonBinding(device _: MouseDevice, slot _: Int, profile _: Int) async throws -> [UInt8]? {
        nil
    }
}

private func makeServiceModeDevice(id: String, transport: DeviceTransportKind, productID: Int) -> MouseDevice {
    MouseDevice(
        id: id,
        vendor_id: transport == .bluetooth ? 0x068E : 0x1532,
        product_id: productID,
        product_name: "Basilisk V3 Pro",
        transport: transport,
        path_b64: "",
        serial: "SERVICE",
        firmware: "1.0.0",
        location_id: 1,
        profile_id: .basiliskV3Pro,
        supports_advanced_lighting_effects: true,
        onboard_profile_count: 1
    )
}
