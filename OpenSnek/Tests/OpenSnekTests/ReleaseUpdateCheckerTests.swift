import XCTest
@testable import OpenSnek

final class ReleaseUpdateCheckerTests: XCTestCase {
    func testReleaseVersionParsesLeadingVPrefix() {
        XCTAssertEqual(ReleaseVersion.parse("v1.2.3"), ReleaseVersion(components: [1, 2, 3]))
    }

    func testReleaseVersionDropsSuffixAfterDash() {
        XCTAssertEqual(ReleaseVersion.parse("0.0.0-test5"), ReleaseVersion(components: [0, 0, 0]))
    }

    func testReleaseVersionComparesDifferentComponentLengths() {
        XCTAssertTrue(ReleaseVersion.parse("1.2.1")! > ReleaseVersion.parse("1.2")!)
        XCTAssertTrue(ReleaseVersion.parse("1.2")! == ReleaseVersion.parse("1.2.0")!)
    }

    func testReleaseVersionRejectsNonNumericValues() {
        XCTAssertNil(ReleaseVersion.parse("main"))
        XCTAssertNil(ReleaseVersion.parse("v1.beta.0"))
    }
}
