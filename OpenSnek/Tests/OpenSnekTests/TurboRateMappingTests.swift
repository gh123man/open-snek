import XCTest
import OpenSnekCore

@MainActor
final class TurboRateMappingTests: XCTestCase {
    func testTurboRawToPressesPerSecondExtremes() {
        XCTAssertEqual(ButtonBindingSupport.turboRawToPressesPerSecond(1), 20)
        XCTAssertEqual(ButtonBindingSupport.turboRawToPressesPerSecond(255), 1)
    }

    func testTurboPressesPerSecondToRawExtremes() {
        XCTAssertEqual(ButtonBindingSupport.turboPressesPerSecondToRaw(20), 1)
        XCTAssertEqual(ButtonBindingSupport.turboPressesPerSecondToRaw(1), 255)
    }

    func testTurboRateMappingRoundTripsWithSmallError() {
        for pps in 1...20 {
            let raw = ButtonBindingSupport.turboPressesPerSecondToRaw(pps)
            let decoded = ButtonBindingSupport.turboRawToPressesPerSecond(raw)
            XCTAssertLessThanOrEqual(abs(decoded - pps), 1)
        }
    }
}
