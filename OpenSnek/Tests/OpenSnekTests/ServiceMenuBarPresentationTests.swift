import XCTest
@testable import OpenSnek

final class ServiceMenuBarPresentationTests: XCTestCase {
    func testCompactDpiTextFormatsCommonValues() {
        XCTAssertNil(ServiceMenuBarPresentation.compactDpiText(for: nil))
        XCTAssertEqual(ServiceMenuBarPresentation.compactDpiText(for: 800), "800")
        XCTAssertEqual(ServiceMenuBarPresentation.compactDpiText(for: 1600), "1.6k")
        XCTAssertEqual(ServiceMenuBarPresentation.compactDpiText(for: 2000), "2k")
        XCTAssertEqual(ServiceMenuBarPresentation.compactDpiText(for: 12_000), "12k")
    }

    func testBatterySymbolNameMatchesChargeBands() {
        XCTAssertEqual(ServiceMenuBarPresentation.batterySymbolName(percent: 5, charging: false), "battery.0")
        XCTAssertEqual(ServiceMenuBarPresentation.batterySymbolName(percent: 22, charging: false), "battery.25")
        XCTAssertEqual(ServiceMenuBarPresentation.batterySymbolName(percent: 55, charging: false), "battery.50")
        XCTAssertEqual(ServiceMenuBarPresentation.batterySymbolName(percent: 80, charging: false), "battery.75")
        XCTAssertEqual(ServiceMenuBarPresentation.batterySymbolName(percent: 99, charging: false), "battery.100percent")
        XCTAssertEqual(ServiceMenuBarPresentation.batterySymbolName(percent: 33, charging: true), "battery.100percent.bolt")
    }
}
