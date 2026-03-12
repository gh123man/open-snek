import Foundation
import XCTest
import OpenSnekCore
import OpenSnekHardware
@testable import OpenSnek

final class USBPassiveDPIEventTests: XCTestCase {
    func testPassiveUSBMonitorReplaceTargetsReturnsForEmptyList() async throws {
        let monitor = USBPassiveDPIEventMonitor()

        let active = try await withAsyncTimeout(seconds: 1.0) {
            await monitor.replaceTargets([])
        }

        XCTAssertTrue(active.isEmpty)
    }

    func testPassiveUSBFastPollingFallsBackUntilRealEventIsObserved() {
        let usbDevice = makePassiveTestDevice(id: "usb-passive-gating", transport: .usb)
        let bluetoothDevice = makePassiveTestDevice(id: "bt-passive-gating", transport: .bluetooth)

        XCTAssertTrue(
            BridgeClient.shouldUseFastDPIPolling(
                device: usbDevice,
                armedPassiveDpiDeviceIDs: [],
                observedPassiveDpiDeviceIDs: []
            )
        )
        XCTAssertTrue(
            BridgeClient.shouldUseFastDPIPolling(
                device: usbDevice,
                armedPassiveDpiDeviceIDs: [usbDevice.id],
                observedPassiveDpiDeviceIDs: []
            )
        )
        XCTAssertFalse(
            BridgeClient.shouldUseFastDPIPolling(
                device: usbDevice,
                armedPassiveDpiDeviceIDs: [usbDevice.id],
                observedPassiveDpiDeviceIDs: [usbDevice.id]
            )
        )
        XCTAssertTrue(
            BridgeClient.shouldUseFastDPIPolling(
                device: bluetoothDevice,
                armedPassiveDpiDeviceIDs: [bluetoothDevice.id],
                observedPassiveDpiDeviceIDs: [bluetoothDevice.id]
            )
        )
    }

    func testPassiveUSBParserAcceptsObservedV3ProFrames() {
        let descriptor = try! XCTUnwrap(
            DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x00AB, transport: .usb)?.usbPassiveDPIInput
        )

        let staged800 = USBPassiveDPIParser.parse(
            report: [0x05, 0x02, 0x03, 0x20, 0x03, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            descriptor: descriptor
        )
        let staged2000 = USBPassiveDPIParser.parse(
            report: [0x05, 0x02, 0x07, 0xD0, 0x07, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            descriptor: descriptor
        )
        let staged1100 = USBPassiveDPIParser.parse(
            report: [0x02, 0x04, 0x4C, 0x04, 0x4C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            descriptor: descriptor
        )
        let shortObservedFrame = USBPassiveDPIParser.parse(
            report: [0x05, 0x02, 0x04, 0x4C, 0x04, 0x4C, 0x00, 0x00],
            descriptor: descriptor
        )

        XCTAssertEqual(staged800, USBPassiveDPIReading(dpiX: 800, dpiY: 800))
        XCTAssertEqual(staged2000, USBPassiveDPIReading(dpiX: 2000, dpiY: 2000))
        XCTAssertEqual(staged1100, USBPassiveDPIReading(dpiX: 1100, dpiY: 1100))
        XCTAssertEqual(shortObservedFrame, USBPassiveDPIReading(dpiX: 1100, dpiY: 1100))
    }

    func testPassiveUSBParserRejectsInvalidSubtypeAndOutOfRangeValues() {
        let descriptor = try! XCTUnwrap(
            DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x00AB, transport: .usb)?.usbPassiveDPIInput
        )

        let wrongSubtype = USBPassiveDPIParser.parse(
            report: [0x05, 0x03, 0x03, 0x20, 0x03, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            descriptor: descriptor
        )
        let outOfRange = USBPassiveDPIParser.parse(
            report: [0x05, 0x02, 0x00, 0x32, 0x00, 0x32, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            descriptor: descriptor
        )

        XCTAssertNil(wrongSubtype)
        XCTAssertNil(outOfRange)
    }

    func testPassiveUSBMergeUpdatesActiveStageOnlyForUniqueMatch() {
        let device = makePassiveTestDevice(id: "usb-passive-merge", transport: .usb)
        let uniqueMatch = mergedStateFromPassiveUSBDpiEvent(
            previous: makePassiveTestState(
                device: device,
                dpiValues: [800, 900, 2000, 1100, 1200],
                activeStage: 0,
                dpiValue: 800
            ),
            event: USBPassiveDPIEvent(deviceID: device.id, dpiX: 2000, dpiY: 2000, observedAt: Date())
        )
        let duplicateMatch = mergedStateFromPassiveUSBDpiEvent(
            previous: makePassiveTestState(
                device: device,
                dpiValues: [800, 2000, 2000],
                activeStage: 0,
                dpiValue: 800
            ),
            event: USBPassiveDPIEvent(deviceID: device.id, dpiX: 2000, dpiY: 2000, observedAt: Date())
        )

        XCTAssertEqual(uniqueMatch?.dpi?.x, 2000)
        XCTAssertEqual(uniqueMatch?.dpi_stages.active_stage, 2)
        XCTAssertEqual(duplicateMatch?.dpi?.x, 2000)
        XCTAssertEqual(duplicateMatch?.dpi_stages.active_stage, 0)
    }

    func testPassiveUSBMergeDropsEventWithoutSeededState() {
        let merged = mergedStateFromPassiveUSBDpiEvent(
            previous: nil,
            event: USBPassiveDPIEvent(deviceID: "missing", dpiX: 1100, dpiY: 1100, observedAt: Date())
        )

        XCTAssertNil(merged)
    }

    func testAppStateAppliesBackendStateUpdatesWithoutWaitingForPolling() async {
        let device = makePassiveTestDevice(id: "usb-passive-live", transport: .usb)
        let backend = PassiveUpdateStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makePassiveTestState(
                    device: device,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 0,
                    dpiValue: 800
                )
            ],
            shouldUseFastPolling: false
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await Task.yield()
        await appState.refreshDevices()
        await backend.emitStateUpdate(
            deviceID: device.id,
            state: makePassiveTestState(
                device: device,
                dpiValues: [800, 1600, 3200],
                activeStage: 2,
                dpiValue: 3200
            )
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        let liveDpi = await MainActor.run { appState.state?.dpi?.x }
        let activeStage = await MainActor.run { appState.editableActiveStage }

        XCTAssertEqual(liveDpi, 3200)
        XCTAssertEqual(activeStage, 3)
    }

    func testAppStateSkipsFastPollingWhenPassiveUSBUpdatesAreAvailable() async {
        let device = makePassiveTestDevice(id: "usb-passive-skip", transport: .usb)
        let backend = PassiveUpdateStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makePassiveTestState(
                    device: device,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600
                )
            ],
            shouldUseFastPolling: false
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await Task.yield()
        await appState.refreshDevices()
        await appState.refreshDpiFast()

        let fastReadCount = await backend.fastReadCount()
        XCTAssertEqual(fastReadCount, 0)
    }

    func testAppStateFallsBackToFastPollingWhenPassiveUSBUpdatesAreUnavailable() async {
        let device = makePassiveTestDevice(id: "usb-passive-fallback", transport: .usb)
        let backend = PassiveUpdateStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makePassiveTestState(
                    device: device,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600
                )
            ],
            shouldUseFastPolling: true
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await Task.yield()
        await appState.refreshDevices()
        await appState.refreshDpiFast()

        let fastReadCount = await backend.fastReadCount()
        XCTAssertEqual(fastReadCount, 1)
    }
}

private struct AsyncTimeoutError: Error {}

private func withAsyncTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AsyncTimeoutError()
        }

        let result = try await group.next()
        group.cancelAll()
        return try XCTUnwrap(result)
    }
}

private actor PassiveUpdateStubBackend: DeviceBackend {
    nonisolated var usesRemoteServiceTransport: Bool { false }

    private let devices: [MouseDevice]
    private let shouldUseFastPollingValue: Bool
    private var stateByDeviceID: [String: MouseState]
    private var fastReadCounter = 0
    private let stateUpdateStreamPair = AsyncStream.makeStream(of: BackendStateUpdate.self)

    init(
        devices: [MouseDevice],
        stateByDeviceID: [String: MouseState],
        shouldUseFastPolling: Bool
    ) {
        self.devices = devices
        self.stateByDeviceID = stateByDeviceID
        self.shouldUseFastPollingValue = shouldUseFastPolling
    }

    func listDevices() async throws -> [MouseDevice] {
        devices
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        guard let state = stateByDeviceID[device.id] else {
            throw NSError(domain: "USBPassiveDPIEventTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing state for \(device.id)"
            ])
        }
        return state
    }

    func readDpiStagesFast(device: MouseDevice) async throws -> DpiFastSnapshot? {
        fastReadCounter += 1
        guard let state = stateByDeviceID[device.id],
              let active = state.dpi_stages.active_stage,
              let values = state.dpi_stages.values else {
            return nil
        }
        return DpiFastSnapshot(active: active, values: values)
    }

    func shouldUseFastDPIPolling(device _: MouseDevice) async -> Bool {
        shouldUseFastPollingValue
    }

    func stateUpdates() async -> AsyncStream<BackendStateUpdate> {
        stateUpdateStreamPair.stream
    }

    func apply(device _: MouseDevice, patch _: DevicePatch) async throws -> MouseState {
        throw NSError(domain: "USBPassiveDPIEventTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "apply not implemented"
        ])
    }

    func readLightingColor(device _: MouseDevice) async throws -> RGBPatch? {
        nil
    }

    func debugUSBReadButtonBinding(device _: MouseDevice, slot _: Int, profile _: Int) async throws -> [UInt8]? {
        nil
    }

    func emitStateUpdate(deviceID: String, state: MouseState, updatedAt: Date = Date()) {
        stateByDeviceID[deviceID] = state
        stateUpdateStreamPair.continuation.yield(.deviceState(deviceID: deviceID, state: state, updatedAt: updatedAt))
    }

    func fastReadCount() -> Int {
        fastReadCounter
    }
}

private func makePassiveTestDevice(id: String, transport: DeviceTransportKind) -> MouseDevice {
    MouseDevice(
        id: id,
        vendor_id: 0x1532,
        product_id: transport == .bluetooth ? 0x00BA : 0x00AB,
        product_name: "Passive Test Mouse",
        transport: transport,
        path_b64: "",
        serial: "PASSIVE-\(id)",
        firmware: "1.0.0",
        location_id: abs(id.hashValue),
        profile_id: .basiliskV3Pro,
        supports_advanced_lighting_effects: true,
        onboard_profile_count: 3
    )
}

private func makePassiveTestState(
    device: MouseDevice,
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
        connection: device.transport.connectionLabel,
        battery_percent: 82,
        charging: false,
        dpi: DpiPair(x: dpiValue, y: dpiValue),
        dpi_stages: DpiStages(active_stage: activeStage, values: dpiValues),
        poll_rate: 1000,
        sleep_timeout: 300,
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
