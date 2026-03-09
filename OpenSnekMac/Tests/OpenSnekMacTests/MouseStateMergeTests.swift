import XCTest
@testable import OpenSnekMac

final class MouseStateMergeTests: XCTestCase {
    func testMergeKeepsPreviousOptionalsWhenIncomingMissing() {
        let previous = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: "ABC", transport: "bluetooth", firmware: "1.2"),
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
            led_value: 200,
            capabilities: Capabilities(dpi_stages: true, poll_rate: false, button_remap: true, lighting: true)
        )

        let incoming = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: nil, transport: "bluetooth", firmware: nil),
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
        XCTAssertEqual(merged.led_value, 200)
        XCTAssertTrue(merged.capabilities.dpi_stages)
        XCTAssertTrue(merged.capabilities.lighting)
    }

    func testMergeUsesIncomingWhenPresent() {
        let previous = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: "ABC", transport: "bluetooth", firmware: "1.2"),
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
            led_value: 200,
            capabilities: Capabilities(dpi_stages: true, poll_rate: false, button_remap: true, lighting: true)
        )

        let incoming = MouseState(
            device: DeviceSummary(id: "dev", product_name: "Mouse", serial: "ABC", transport: "bluetooth", firmware: "1.3"),
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
        XCTAssertEqual(merged.led_value, 180)
        XCTAssertEqual(merged.device.firmware, "1.3")
    }
}
