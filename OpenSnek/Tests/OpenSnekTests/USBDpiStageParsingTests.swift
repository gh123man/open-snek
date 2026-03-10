import XCTest
@testable import OpenSnek

final class USBDpiStageParsingTests: XCTestCase {
    func testUSBStageSnapshotParsingUsesCorrectResponseOffsets() async {
        let client = BridgeClient()

        var response = [UInt8](repeating: 0, count: 11 + (2 * 7))
        response[0] = 0x02
        response[8] = 0x01
        response[9] = 0x02
        response[10] = 0x02

        response[11] = 0x01
        response[12] = 0x03
        response[13] = 0x20
        response[14] = 0x03
        response[15] = 0x20

        response[18] = 0x02
        response[19] = 0x06
        response[20] = 0x40
        response[21] = 0x06
        response[22] = 0x40

        let snapshot = await client.parseUSBDpiStageSnapshotResponse(response)

        XCTAssertEqual(snapshot?.active, 1)
        XCTAssertEqual(snapshot?.values, [800, 1600])
        XCTAssertEqual(snapshot?.stageIDs, [0x01, 0x02])
    }
}
