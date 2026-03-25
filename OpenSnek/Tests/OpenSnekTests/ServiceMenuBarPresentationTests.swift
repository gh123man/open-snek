import XCTest
import OpenSnekCore
@testable import OpenSnek

final class ServiceMenuBarPresentationTests: XCTestCase {
    func testCompactDpiTextFormatsCommonValues() {
        XCTAssertNil(ServiceMenuBarPresentation.compactDpiText(for: nil))
        XCTAssertEqual(ServiceMenuBarPresentation.compactDpiText(for: 800), "800")
        XCTAssertEqual(ServiceMenuBarPresentation.compactDpiText(for: 1600), "1.6k")
        XCTAssertEqual(ServiceMenuBarPresentation.compactDpiText(for: 2000), "2k")
        XCTAssertEqual(ServiceMenuBarPresentation.compactDpiText(for: 12_000), "12k")
    }

    func testCompactDpiControlModeUsesSingleSliderForScalarStages() {
        XCTAssertEqual(
            ServiceMenuBarPresentation.compactDpiControlMode(
                for: DpiPair(x: 1600, y: 1600),
                supportsIndependentXYDPI: true
            ),
            .scalar(1600)
        )
        XCTAssertEqual(
            ServiceMenuBarPresentation.compactDpiControlMode(
                for: DpiPair(x: 1600, y: 2000),
                supportsIndependentXYDPI: false
            ),
            .scalar(1600)
        )
    }

    func testCompactDpiControlModeUsesSplitSlidersForSplitStages() {
        XCTAssertEqual(
            ServiceMenuBarPresentation.compactDpiControlMode(
                for: DpiPair(x: 1600, y: 2000),
                supportsIndependentXYDPI: true
            ),
            .split(DpiPair(x: 1600, y: 2000))
        )
    }

    func testBatteryIconUsesAdaptiveSymbolAndSharedPresentation() {
        let shared = BatteryPresentation.icon(percent: 33, charging: true)
        let compactMenu = ServiceMenuBarPresentation.batteryIcon(percent: 33, charging: true)

        XCTAssertEqual(shared, compactMenu)
        XCTAssertEqual(shared.symbolName, "battery.100percent.bolt")
        XCTAssertEqual(shared.variableValue, 0.33, accuracy: 0.001)
        XCTAssertEqual(shared.accent, .normal)
    }

    func testBatteryIconClampsVariableValueToPercentBounds() {
        XCTAssertEqual(BatteryPresentation.icon(percent: -10, charging: false).variableValue, 0.0, accuracy: 0.001)
        XCTAssertEqual(BatteryPresentation.icon(percent: 58, charging: nil).variableValue, 0.50, accuracy: 0.001)
        XCTAssertEqual(BatteryPresentation.icon(percent: 120, charging: false).variableValue, 1.0, accuracy: 0.001)
        XCTAssertEqual(BatteryPresentation.icon(percent: 58, charging: nil).symbolName, "battery.50percent")
    }

    func testBatteryIconUsesLowAccentWhenDeviceFallsBelowThreshold() {
        let icon = BatteryPresentation.icon(percent: 20, charging: false, thresholdRaw: 0x3F)

        XCTAssertEqual(icon.symbolName, "battery.25percent")
        XCTAssertEqual(icon.accent, .low)
    }

    func testBatteryIconUsesTieredSymbolsAcrossLevels() {
        XCTAssertEqual(BatteryPresentation.icon(percent: 8, charging: false).symbolName, "battery.0percent")
        XCTAssertEqual(BatteryPresentation.icon(percent: 30, charging: false).symbolName, "battery.25percent")
        XCTAssertEqual(BatteryPresentation.icon(percent: 58, charging: false).symbolName, "battery.50percent")
        XCTAssertEqual(BatteryPresentation.icon(percent: 80, charging: false).symbolName, "battery.75percent")
        XCTAssertEqual(BatteryPresentation.icon(percent: 96, charging: false).symbolName, "battery.100percent")
    }

    func testBatteryIconDoesNotUseLowAccentWhileCharging() {
        let icon = BatteryPresentation.icon(percent: 20, charging: true, thresholdRaw: 0x3F)

        XCTAssertEqual(icon.symbolName, "battery.100percent.bolt")
        XCTAssertEqual(icon.accent, .normal)
    }

    func testStatusGlyphBatteryIconOnlyAppearsForLowBatteryStates() {
        let lowState = makeBatteryState(percent: 20)
        let healthyState = makeBatteryState(percent: 60)

        XCTAssertEqual(ServiceMenuBarPresentation.statusGlyphBatteryIcon(state: lowState)?.symbolName, "battery.25percent")
        XCTAssertNil(ServiceMenuBarPresentation.statusGlyphBatteryIcon(state: healthyState))
    }

    private func makeBatteryState(percent: Int) -> MouseState {
        MouseState(
            device: DeviceSummary(
                id: "dev",
                product_name: "Basilisk V3 Pro",
                serial: "ABC123",
                transport: .usb,
                firmware: "1.0"
            ),
            connection: "USB",
            battery_percent: percent,
            charging: false,
            dpi: DpiPair(x: 1600, y: 1600),
            dpi_stages: DpiStages(active_stage: 0, values: [1600]),
            poll_rate: 1000,
            device_mode: DeviceMode(mode: 0x00, param: 0x00),
            low_battery_threshold_raw: 0x3F,
            led_value: 64,
            capabilities: Capabilities(
                dpi_stages: true,
                poll_rate: true,
                button_remap: true,
                lighting: true
            )
        )
    }
}
