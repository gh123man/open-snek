import XCTest
@testable import OpenSnekMac

@MainActor
final class TurboRateMappingTests: XCTestCase {
    func testTurboRawToPressesPerSecondExtremes() {
        XCTAssertEqual(AppState.turboRawToPressesPerSecond(1), 20)
        XCTAssertEqual(AppState.turboRawToPressesPerSecond(255), 1)
    }

    func testTurboPressesPerSecondToRawExtremes() {
        XCTAssertEqual(AppState.turboPressesPerSecondToRaw(20), 1)
        XCTAssertEqual(AppState.turboPressesPerSecondToRaw(1), 255)
    }

    func testTurboRateMappingRoundTripsWithSmallError() {
        for pps in 1...20 {
            let raw = AppState.turboPressesPerSecondToRaw(pps)
            let decoded = AppState.turboRawToPressesPerSecond(raw)
            XCTAssertLessThanOrEqual(abs(decoded - pps), 1)
        }
    }
}
