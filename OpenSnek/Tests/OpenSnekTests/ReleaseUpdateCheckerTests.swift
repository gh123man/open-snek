import XCTest
@testable import OpenSnek

final class ReleaseUpdateCheckerTests: XCTestCase {
    func testReleaseVersionParsesLeadingVPrefix() {
        XCTAssertEqual(ReleaseVersion.parse("v1.2.3"), ReleaseVersion(components: [1, 2, 3], preRelease: []))
    }

    func testReleaseVersionParsesPreReleaseSuffix() {
        XCTAssertEqual(
            ReleaseVersion.parse("0.0.0-alpha.5"),
            ReleaseVersion(
                components: [0, 0, 0],
                preRelease: [.textual("alpha"), .numeric(5)]
            )
        )
    }

    func testReleaseVersionComparesDifferentComponentLengths() {
        XCTAssertTrue(ReleaseVersion.parse("1.2.1")! > ReleaseVersion.parse("1.2")!)
        XCTAssertTrue(ReleaseVersion.parse("1.2")! == ReleaseVersion.parse("1.2.0")!)
    }

    func testReleaseVersionComparesPreReleaseIterations() {
        XCTAssertTrue(ReleaseVersion.parse("0.1.0-alpha.3")! > ReleaseVersion.parse("0.1.0-alpha.1")!)
    }

    func testStableReleaseBeatsPreReleaseOfSameCoreVersion() {
        XCTAssertTrue(ReleaseVersion.parse("0.1.0")! > ReleaseVersion.parse("0.1.0-alpha.3")!)
    }

    func testReleaseVersionRejectsNonNumericValues() {
        XCTAssertNil(ReleaseVersion.parse("main"))
        XCTAssertNil(ReleaseVersion.parse("v1.beta.0"))
    }
}
