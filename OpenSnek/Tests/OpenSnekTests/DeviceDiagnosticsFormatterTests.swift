import XCTest
import OpenSnekCore

final class DeviceDiagnosticsFormatterTests: XCTestCase {
    func testSupportedDeviceDumpIncludesProfileLayoutAndState() {
        let device = MouseDevice(
            id: "usb-35k",
            vendor_id: 0x1532,
            product_id: 0x00CB,
            product_name: "Basilisk V3 35K",
            transport: .usb,
            path_b64: "ZmFrZS11c2ItcGF0aA==",
            serial: "35K123",
            firmware: "1.2.3",
            location_id: 0x00123456,
            profile_id: .basiliskV335K,
            button_layout: DeviceProfiles.basiliskV335KUSB.buttonLayout,
            supports_advanced_lighting_effects: true,
            onboard_profile_count: 5
        )
        let state = MouseState(
            device: DeviceSummary(
                id: device.id,
                product_name: device.product_name,
                serial: device.serial,
                transport: device.transport,
                firmware: device.firmware
            ),
            connection: "USB",
            battery_percent: 83,
            charging: false,
            dpi: DpiPair(x: 1600, y: 1600),
            dpi_stages: DpiStages(active_stage: 1, values: [800, 1600, 3200]),
            poll_rate: 1000,
            sleep_timeout: 300,
            device_mode: DeviceMode(mode: 0x00, param: 0x00),
            low_battery_threshold_raw: 0x26,
            scroll_mode: 1,
            scroll_acceleration: true,
            scroll_smart_reel: false,
            active_onboard_profile: 2,
            onboard_profile_count: 5,
            led_value: 64,
            capabilities: Capabilities(
                dpi_stages: true,
                poll_rate: true,
                power_management: true,
                button_remap: true,
                lighting: true
            )
        )

        let dump = DeviceDiagnosticsFormatter.format(
            device: device,
            state: state,
            profile: DeviceProfiles.basiliskV335KUSB,
            generatedAt: Date(timeIntervalSince1970: 0),
            appContextLines: ["Warning: None"]
        )

        XCTAssertTrue(dump.contains("Support status: Validated profile"))
        XCTAssertTrue(dump.contains("Resolved profile: basilisk_v3_35k"))
        XCTAssertTrue(dump.contains("Writable slots: 1, 2, 3, 4, 5, 9, 10, 52, 53, 96"))
        XCTAssertTrue(dump.contains("Hidden unsupported buttons:"))
        XCTAssertTrue(dump.contains("Scroll Mode Toggle"))
        XCTAssertTrue(dump.contains("Supported effects: Off, Static, Spectrum, Wave"))
        XCTAssertTrue(dump.contains("USB zones: Scroll Wheel [0x01]; Logo [0x04]; Underglow [0x0A]"))
        XCTAssertTrue(dump.contains("DPI stages: 1:800, 2:1600*, 3:3200"))
        XCTAssertTrue(dump.contains("Battery: 83% (not charging)"))
    }

    func testGenericDeviceDumpCallsOutBestEffortSupport() {
        let device = MouseDevice(
            id: "unknown",
            vendor_id: 0x1532,
            product_id: 0x9999,
            product_name: "Mystery Mouse",
            transport: .usb,
            path_b64: "",
            serial: nil,
            firmware: nil,
            location_id: 0x00000001
        )

        let dump = DeviceDiagnosticsFormatter.format(
            device: device,
            state: nil,
            profile: nil,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(dump.contains("Support status: Generic best-effort"))
        XCTAssertTrue(dump.contains("Resolved profile: none"))
        XCTAssertTrue(dump.contains("No mapped button layout"))
        XCTAssertTrue(dump.contains("Live state unavailable"))
    }
}
