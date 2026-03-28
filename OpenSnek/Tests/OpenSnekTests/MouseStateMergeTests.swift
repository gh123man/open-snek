import XCTest
import OpenSnekCore

final class MouseStateMergeTests: XCTestCase {
    func testMergeKeepsPreviousOptionalsWhenIncomingMissing() {
        let previous = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: "ABC", transport: .bluetooth, firmware: "1.2"),
            connection: "Bluetooth",
            battery_percent: 88,
            charging: false,
            dpi: DpiPair(x: 800, y: 800),
            dpi_stages: DpiStages(active_stage: 0, values: [800, 6400]),
            poll_rate: nil,
            device_mode: nil,
            low_battery_threshold_raw: 0x26,
            scroll_mode: 1,
            scroll_acceleration: true,
            scroll_smart_reel: false,
            active_onboard_profile: 2,
            onboard_profile_count: 5,
            led_value: 200,
            capabilities: Capabilities(dpi_stages: true, poll_rate: false, button_remap: true, lighting: true)
        )

        let incoming = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: nil, transport: .bluetooth, firmware: nil),
            connection: "Bluetooth",
            battery_percent: nil,
            charging: nil,
            dpi: nil,
            dpi_stages: DpiStages(active_stage: nil, values: nil),
            poll_rate: nil,
            device_mode: nil,
            low_battery_threshold_raw: nil,
            scroll_mode: nil,
            scroll_acceleration: nil,
            scroll_smart_reel: nil,
            active_onboard_profile: nil,
            onboard_profile_count: nil,
            led_value: nil,
            capabilities: Capabilities(dpi_stages: false, poll_rate: false, button_remap: true, lighting: false)
        )

        let merged = incoming.merged(with: previous)
        XCTAssertEqual(merged.battery_percent, 88)
        XCTAssertEqual(merged.dpi?.x, 800)
        XCTAssertEqual(merged.dpi_stages.values ?? [], [800, 6400])
        XCTAssertEqual(merged.low_battery_threshold_raw, 0x26)
        XCTAssertEqual(merged.scroll_mode, 1)
        XCTAssertEqual(merged.scroll_acceleration, true)
        XCTAssertEqual(merged.scroll_smart_reel, false)
        XCTAssertEqual(merged.active_onboard_profile, 2)
        XCTAssertEqual(merged.onboard_profile_count, 5)
        XCTAssertEqual(merged.led_value, 200)
        XCTAssertTrue(merged.capabilities.dpi_stages)
        XCTAssertTrue(merged.capabilities.lighting)
    }

    func testMergeUsesIncomingWhenPresent() {
        let previous = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: "ABC", transport: .bluetooth, firmware: "1.2"),
            connection: "Bluetooth",
            battery_percent: 88,
            charging: false,
            dpi: DpiPair(x: 800, y: 800),
            dpi_stages: DpiStages(active_stage: 0, values: [800, 6400]),
            poll_rate: nil,
            device_mode: nil,
            low_battery_threshold_raw: 0x1F,
            scroll_mode: 0,
            scroll_acceleration: false,
            scroll_smart_reel: false,
            active_onboard_profile: 1,
            onboard_profile_count: 5,
            led_value: 200,
            capabilities: Capabilities(dpi_stages: true, poll_rate: false, button_remap: true, lighting: true)
        )

        let incoming = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: "ABC", transport: .bluetooth, firmware: "1.3"),
            connection: "Bluetooth",
            battery_percent: 92,
            charging: true,
            dpi: DpiPair(x: 6400, y: 6400),
            dpi_stages: DpiStages(active_stage: 1, values: [800, 6400]),
            poll_rate: nil,
            device_mode: nil,
            low_battery_threshold_raw: 0x3F,
            scroll_mode: 1,
            scroll_acceleration: true,
            scroll_smart_reel: true,
            active_onboard_profile: 3,
            onboard_profile_count: 5,
            led_value: 180,
            capabilities: Capabilities(dpi_stages: true, poll_rate: false, button_remap: true, lighting: true)
        )

        let merged = incoming.merged(with: previous)
        XCTAssertEqual(merged.battery_percent, 92)
        XCTAssertEqual(merged.charging, true)
        XCTAssertEqual(merged.dpi?.x, 6400)
        XCTAssertEqual(merged.low_battery_threshold_raw, 0x3F)
        XCTAssertEqual(merged.scroll_mode, 1)
        XCTAssertEqual(merged.scroll_acceleration, true)
        XCTAssertEqual(merged.scroll_smart_reel, true)
        XCTAssertEqual(merged.active_onboard_profile, 3)
        XCTAssertEqual(merged.onboard_profile_count, 5)
        XCTAssertEqual(merged.led_value, 180)
        XCTAssertEqual(merged.device.firmware, "1.3")
    }

    func testMergeClearsStaleChargingWhenFreshBatterySnapshotHasUnknownChargeState() {
        let previous = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: "ABC", transport: .bluetooth, firmware: "1.2"),
            connection: "Bluetooth",
            battery_percent: 88,
            charging: true,
            dpi: DpiPair(x: 800, y: 800),
            dpi_stages: DpiStages(active_stage: 0, values: [800, 6400]),
            poll_rate: nil,
            device_mode: nil,
            low_battery_threshold_raw: nil,
            led_value: 200,
            capabilities: Capabilities(dpi_stages: true, poll_rate: false, button_remap: true, lighting: true)
        )

        let incoming = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: "ABC", transport: .bluetooth, firmware: "1.2"),
            connection: "Bluetooth",
            battery_percent: 87,
            charging: nil,
            dpi: nil,
            dpi_stages: DpiStages(active_stage: nil, values: nil),
            poll_rate: nil,
            device_mode: nil,
            low_battery_threshold_raw: nil,
            led_value: nil,
            capabilities: Capabilities(dpi_stages: true, poll_rate: false, button_remap: true, lighting: true)
        )

        let merged = incoming.merged(with: previous)
        XCTAssertEqual(merged.battery_percent, 87)
        XCTAssertNil(merged.charging)
    }

    func testDiffersOnlyInDynamicDpiStateAcceptsDpiOnlyDelta() {
        let previous = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: "ABC", transport: .bluetooth, firmware: "1.2"),
            connection: "Bluetooth",
            battery_percent: 85,
            charging: false,
            dpi: DpiPair(x: 800, y: 800),
            dpi_stages: DpiStages(active_stage: 0, values: [800, 1600, 3200]),
            poll_rate: nil,
            sleep_timeout: 5,
            device_mode: nil,
            low_battery_threshold_raw: 0x26,
            led_value: 180,
            capabilities: Capabilities(dpi_stages: true, poll_rate: false, power_management: true, button_remap: true, lighting: true)
        )
        let updated = MouseState(
            device: previous.device,
            connection: previous.connection,
            battery_percent: previous.battery_percent,
            charging: previous.charging,
            dpi: DpiPair(x: 1600, y: 1600),
            dpi_stages: DpiStages(active_stage: 1, values: [800, 1600, 3200]),
            poll_rate: previous.poll_rate,
            sleep_timeout: previous.sleep_timeout,
            device_mode: previous.device_mode,
            low_battery_threshold_raw: previous.low_battery_threshold_raw,
            led_value: previous.led_value,
            capabilities: previous.capabilities
        )

        XCTAssertTrue(updated.differsOnlyInDynamicDpiState(from: previous))
    }

    func testDiffersOnlyInDynamicDpiStateRejectsStableTelemetryChanges() {
        let previous = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: "ABC", transport: .bluetooth, firmware: "1.2"),
            connection: "Bluetooth",
            battery_percent: 85,
            charging: false,
            dpi: DpiPair(x: 800, y: 800),
            dpi_stages: DpiStages(active_stage: 0, values: [800, 1600, 3200]),
            poll_rate: nil,
            sleep_timeout: 5,
            device_mode: nil,
            low_battery_threshold_raw: 0x26,
            led_value: 180,
            capabilities: Capabilities(dpi_stages: true, poll_rate: false, power_management: true, button_remap: true, lighting: true)
        )
        let updated = MouseState(
            device: previous.device,
            connection: previous.connection,
            battery_percent: 72,
            charging: false,
            dpi: DpiPair(x: 1600, y: 1600),
            dpi_stages: DpiStages(active_stage: 1, values: [800, 1600, 3200]),
            poll_rate: previous.poll_rate,
            sleep_timeout: previous.sleep_timeout,
            device_mode: previous.device_mode,
            low_battery_threshold_raw: previous.low_battery_threshold_raw,
            led_value: previous.led_value,
            capabilities: previous.capabilities
        )

        XCTAssertFalse(updated.differsOnlyInDynamicDpiState(from: previous))
    }

    func testMergedWithStableReadTelemetryPreservesNewerDpiAndUsesFreshBattery() {
        let newerDpiState = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: "ABC", transport: .bluetooth, firmware: "1.2"),
            connection: "Bluetooth",
            battery_percent: 85,
            charging: false,
            dpi: DpiPair(x: 1600, y: 1600),
            dpi_stages: DpiStages(active_stage: 1, values: [800, 1600, 3200]),
            poll_rate: nil,
            sleep_timeout: 5,
            device_mode: nil,
            low_battery_threshold_raw: 0x26,
            led_value: 180,
            capabilities: Capabilities(dpi_stages: true, poll_rate: false, power_management: true, button_remap: true, lighting: true)
        )
        let staleFullRead = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: "ABC", transport: .bluetooth, firmware: "1.2"),
            connection: "Bluetooth",
            battery_percent: 72,
            charging: false,
            dpi: DpiPair(x: 800, y: 800),
            dpi_stages: DpiStages(active_stage: 0, values: [800, 1600, 3200]),
            poll_rate: nil,
            sleep_timeout: 10,
            device_mode: nil,
            low_battery_threshold_raw: 0x2A,
            led_value: 120,
            capabilities: Capabilities(dpi_stages: true, poll_rate: false, power_management: true, button_remap: true, lighting: true)
        )

        let merged = newerDpiState.mergedWithStableReadTelemetry(from: staleFullRead)

        XCTAssertEqual(merged.battery_percent, 72)
        XCTAssertEqual(merged.dpi?.x, 1600)
        XCTAssertEqual(merged.dpi_stages.active_stage, 1)
        XCTAssertEqual(merged.sleep_timeout, 10)
        XCTAssertEqual(merged.low_battery_threshold_raw, 0x2A)
        XCTAssertEqual(merged.led_value, 120)
    }
}
