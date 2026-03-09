import XCTest
@testable import OpenSnekMac

final class HardwareUSBStateSmokeTests: XCTestCase {
    private func requireHardwareRunEnabled() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPEN_SNEK_HW"] == "1" else {
            throw XCTSkip("Set OPEN_SNEK_HW=1 to run hardware USB smoke tests.")
        }
        guard env["OPEN_SNEK_USB"] == "1" else {
            throw XCTSkip("Set OPEN_SNEK_USB=1 to run USB-specific smoke tests.")
        }
    }

    private func readStateWithRetry(client: BridgeClient, device: MouseDevice, attempts: Int = 4) async throws -> MouseState {
        var firstError: Error?
        for attempt in 0..<max(1, attempts) {
            do {
                return try await client.readState(device: device)
            } catch {
                if firstError == nil {
                    firstError = error
                }
                if attempt + 1 < attempts {
                    try? await Task.sleep(nanoseconds: 140_000_000)
                }
            }
        }
        throw firstError ?? BridgeError.commandFailed("USB state read failed")
    }

    func testUSBReadStateIncludesExpectedCoreTelemetry() async throws {
        try requireHardwareRunEnabled()

        let client = BridgeClient()
        let devices = try await client.listDevices()
        guard let usb = devices.first(where: { $0.transport == "usb" }) else {
            throw XCTSkip("No USB device found for USB smoke test.")
        }

        let state = try await readStateWithRetry(client: client, device: usb)
        print(
            "USB state: id=\(usb.id) " +
            "dpiActive=\(state.dpi_stages.active_stage.map(String.init) ?? "nil") " +
            "dpiValues=\(state.dpi_stages.values?.map(String.init).joined(separator: ",") ?? "nil") " +
            "led=\(state.led_value.map(String.init) ?? "nil") " +
            "poll=\(state.poll_rate.map(String.init) ?? "nil") " +
            "mode=\(state.device_mode.map { "\($0.mode):\($0.param)" } ?? "nil")"
        )

        XCTAssertNotNil(state.poll_rate, "Expected USB poll-rate telemetry")
        XCTAssertNotNil(state.dpi_stages.values, "Expected USB DPI stage telemetry")
    }

    func testUSBApplyCurrentStateRoundTrips() async throws {
        try requireHardwareRunEnabled()

        let client = BridgeClient()
        let devices = try await client.listDevices()
        guard let usb = devices.first(where: { $0.transport == "usb" }) else {
            throw XCTSkip("No USB device found for USB smoke test.")
        }

        let before = try await readStateWithRetry(client: client, device: usb)
        guard let stages = before.dpi_stages.values, !stages.isEmpty else {
            throw XCTSkip("USB device did not return DPI stage telemetry.")
        }

        var patch = DevicePatch()
        patch.dpiStages = stages
        patch.activeStage = before.dpi_stages.active_stage ?? 0
        if let poll = before.poll_rate {
            patch.pollRate = poll
        }
        _ = try await client.apply(device: usb, patch: patch)
        let after = try await readStateWithRetry(client: client, device: usb)

        XCTAssertEqual(after.dpi_stages.values ?? [], stages, "USB DPI stages should round-trip on apply")
        XCTAssertEqual(
            after.dpi_stages.active_stage ?? 0,
            before.dpi_stages.active_stage ?? 0,
            "USB active DPI stage should round-trip on apply"
        )
        if let poll = before.poll_rate {
            XCTAssertEqual(after.poll_rate, poll, "USB poll rate should round-trip on apply")
        }
    }

    func testUSBApplySingleStageDpiChangePersists() async throws {
        try requireHardwareRunEnabled()

        let client = BridgeClient()
        let devices = try await client.listDevices()
        guard let usb = devices.first(where: { $0.transport == "usb" }) else {
            throw XCTSkip("No USB device found for USB smoke test.")
        }

        let before = try await readStateWithRetry(client: client, device: usb)
        guard let beforeStages = before.dpi_stages.values, !beforeStages.isEmpty else {
            throw XCTSkip("USB device did not return DPI stage telemetry.")
        }
        print("before dpi=\(before.dpi?.x ?? -1) active=\(before.dpi_stages.active_stage ?? -1) stages=\(beforeStages)")

        let originalActive = before.dpi_stages.active_stage ?? 0
        let originalStages = beforeStages
        let active = max(0, min(beforeStages.count - 1, originalActive))
        let target = min(30_000, max(100, beforeStages[active] + 400))
        var modifiedStages = beforeStages
        modifiedStages[active] = target

        var writePatch = DevicePatch()
        writePatch.dpiStages = modifiedStages
        writePatch.activeStage = active
        _ = try await client.apply(device: usb, patch: writePatch)

        let changed = try await readStateWithRetry(client: client, device: usb)
        print("changed dpi=\(changed.dpi?.x ?? -1) active=\(changed.dpi_stages.active_stage ?? -1) stages=\(changed.dpi_stages.values ?? [])")
        XCTAssertEqual(changed.dpi_stages.values?[active], target, "Expected active-stage DPI update to persist")
        XCTAssertEqual(changed.dpi_stages.active_stage ?? 0, active, "Expected active stage to remain selected")

        // Restore original stage table to avoid leaving hardware altered after test.
        var restorePatch = DevicePatch()
        restorePatch.dpiStages = originalStages
        restorePatch.activeStage = originalActive
        _ = try await client.apply(device: usb, patch: restorePatch)

        let restored = try await readStateWithRetry(client: client, device: usb)
        print("restored dpi=\(restored.dpi?.x ?? -1) active=\(restored.dpi_stages.active_stage ?? -1) stages=\(restored.dpi_stages.values ?? [])")
        XCTAssertEqual(restored.dpi_stages.values?.prefix(originalStages.count), originalStages.prefix(originalStages.count))
        XCTAssertEqual(restored.dpi_stages.active_stage ?? 0, originalActive)
    }

    func testUSBApplyMultiStageAndActiveSelectionPersists() async throws {
        try requireHardwareRunEnabled()

        let client = BridgeClient()
        let devices = try await client.listDevices()
        guard let usb = devices.first(where: { $0.transport == "usb" }) else {
            throw XCTSkip("No USB device found for USB smoke test.")
        }

        let before = try await readStateWithRetry(client: client, device: usb)
        guard let beforeStages = before.dpi_stages.values, !beforeStages.isEmpty else {
            throw XCTSkip("USB device did not return DPI stage telemetry.")
        }

        let originalActive = before.dpi_stages.active_stage ?? 0
        let originalStages = beforeStages

        let base = max(800, min(24_000, before.dpi?.x ?? beforeStages[0]))
        let targets = [
            max(100, min(30_000, base)),
            max(100, min(30_000, base + 800)),
            max(100, min(30_000, base + 1_600)),
        ]
        for targetActive in [2, 0] {
            var writePatch = DevicePatch()
            writePatch.dpiStages = targets
            writePatch.activeStage = targetActive
            _ = try await client.apply(device: usb, patch: writePatch)

            let changed = try await readStateWithRetry(client: client, device: usb)
            let changedValues = changed.dpi_stages.values ?? []
            print("multi changed dpi=\(changed.dpi?.x ?? -1) active=\(changed.dpi_stages.active_stage ?? -1) stages=\(changedValues)")
            XCTAssertEqual(Array(changedValues.prefix(targets.count)), targets, "Expected multi-stage table to persist")
            XCTAssertEqual(changed.dpi_stages.active_stage ?? -1, targetActive, "Expected active stage to persist")
        }

        var restorePatch = DevicePatch()
        restorePatch.dpiStages = originalStages
        restorePatch.activeStage = originalActive
        _ = try await client.apply(device: usb, patch: restorePatch)

        let restored = try await readStateWithRetry(client: client, device: usb)
        print("multi restored dpi=\(restored.dpi?.x ?? -1) active=\(restored.dpi_stages.active_stage ?? -1) stages=\(restored.dpi_stages.values ?? [])")
        XCTAssertEqual(restored.dpi_stages.values?.prefix(originalStages.count), originalStages.prefix(originalStages.count))
        XCTAssertEqual(restored.dpi_stages.active_stage ?? 0, originalActive)
    }
}
