import XCTest
@testable import OpenSnekMac

final class BLEVendorProtocolTests: XCTestCase {
    func testReadHeaderEncoding() {
        let data = BLEVendorProtocol.buildReadHeader(req: 0x34, key: .dpiStagesGet)
        XCTAssertEqual(Array(data), [0x34, 0x00, 0x00, 0x00, 0x0B, 0x84, 0x01, 0x00])
    }

    func testWriteHeaderEncoding() {
        let data = BLEVendorProtocol.buildWriteHeader(req: 0x34, payloadLength: 0x26, key: .dpiStagesSet)
        XCTAssertEqual(Array(data), [0x34, 0x26, 0x00, 0x00, 0x0B, 0x04, 0x01, 0x00])
    }

    func testParsePayloadFramesSuccess() {
        let header = Data([0x40, 0x03, 0, 0, 0, 0, 0, 0x02] + Array(repeating: 0, count: 12))
        let payloadFrame = Data([0xAA, 0xBB, 0xCC] + Array(repeating: 0, count: 17))
        let parsed = BLEVendorProtocol.parsePayloadFrames(notifies: [header, payloadFrame], req: 0x40)
        XCTAssertEqual(Array(parsed ?? Data()), [0xAA, 0xBB, 0xCC])
    }

    func testParsePayloadFramesErrorStatusReturnsNil() {
        let header = Data([0x40, 0x03, 0, 0, 0, 0, 0, 0x03] + Array(repeating: 0, count: 12))
        let payloadFrame = Data([0xAA, 0xBB, 0xCC] + Array(repeating: 0, count: 17))
        let parsed = BLEVendorProtocol.parsePayloadFrames(notifies: [header, payloadFrame], req: 0x40)
        XCTAssertNil(parsed)
    }

    func testParseAndBuildDpiStagesRoundTrip() {
        let payload = BLEVendorProtocol.buildDpiStagePayload(active: 1, count: 3, slots: [800, 1600, 3200, 6400, 12000], marker: 0x03)
        let parsed = BLEVendorProtocol.parseDpiStages(blob: payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.active, 1)
        XCTAssertEqual(parsed?.count, 3)
        XCTAssertEqual(parsed?.values.prefix(3), [800, 1600, 3200])
    }

    func testMergedStageSlotsSingleModeMirrors() {
        let merged = BLEVendorProtocol.mergedStageSlots(
            currentSlots: [400, 800, 1600, 3200, 6400],
            requestedCount: 1,
            requestedValues: [1800]
        )
        XCTAssertEqual(merged, [1800, 1800, 1800, 1800, 1800])
    }

    func testMergedStageSlotsMultiModePreservesTail() {
        let merged = BLEVendorProtocol.mergedStageSlots(
            currentSlots: [400, 800, 1600, 3200, 6400],
            requestedCount: 3,
            requestedValues: [500, 900, 1700]
        )
        XCTAssertEqual(merged, [500, 900, 1700, 3200, 6400])
    }

    func testButtonPayloadKeyboardSimple() {
        let payload = BLEVendorProtocol.buildButtonPayload(slot: 0x02, kind: .keyboardSimple, hidKey: 0x2C)
        XCTAssertEqual(Array(payload), [0x01, 0x02, 0x00, 0x02, 0x02, 0x00, 0x2C, 0x00, 0x00, 0x00])
    }

    func testButtonPayloadMiddleClick() {
        let payload = BLEVendorProtocol.buildButtonPayload(slot: 0x03, kind: .middleClick, hidKey: nil)
        XCTAssertEqual(Array(payload), [0x01, 0x03, 0x00, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00, 0x00])
    }

    func testButtonPayloadScrollUp() {
        let payload = BLEVendorProtocol.buildButtonPayload(slot: 0x09, kind: .scrollUp, hidKey: nil)
        XCTAssertEqual(Array(payload), [0x01, 0x09, 0x00, 0x01, 0x01, 0x09, 0x00, 0x00, 0x00, 0x00])
    }

    func testButtonPayloadScrollDown() {
        let payload = BLEVendorProtocol.buildButtonPayload(slot: 0x0A, kind: .scrollDown, hidKey: nil)
        XCTAssertEqual(Array(payload), [0x01, 0x0A, 0x00, 0x01, 0x01, 0x0A, 0x00, 0x00, 0x00, 0x00])
    }

    func testButtonPayloadDefaultSlot2UsesExplicitRightClickRestore() {
        let payload = BLEVendorProtocol.buildButtonPayload(slot: 0x02, kind: .default, hidKey: nil)
        XCTAssertEqual(Array(payload), [0x01, 0x02, 0x00, 0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00])
    }

    func testButtonPayloadDefaultSlot60UsesCaptureBackedDpiRestore() {
        let payload = BLEVendorProtocol.buildButtonPayload(slot: 0x60, kind: .default, hidKey: nil)
        XCTAssertEqual(Array(payload), [0x01, 0x60, 0x00, 0x06, 0x01, 0x06, 0x00, 0x00, 0x00, 0x00])
    }

    func testParseVariableLengthDpiBlob() {
        // [active=0][count=2]
        // stage0: [00][20 03][20 03][00][00] -> 800
        // stage1: [01][00 19][00 19][00][00] -> 6400
        let blob = Data([0x00, 0x02, 0x00, 0x20, 0x03, 0x20, 0x03, 0x00, 0x00, 0x01, 0x00, 0x19, 0x00, 0x19, 0x00, 0x00])
        let parsed = BLEVendorProtocol.parseDpiStages(blob: blob)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.active, 0)
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?.values, [800, 6400])
    }

    func testParseVariableLengthDpiBlobPreservesWireEntryOrder() {
        // [active=1][count=3]
        // entries are intentionally out of order by stage id:
        // stage2 -> 3200, stage0 -> 800, stage1 -> 1600
        let blob = Data([
            0x01, 0x03,
            0x02, 0x80, 0x0C, 0x80, 0x0C, 0x00, 0x00,
            0x00, 0x20, 0x03, 0x20, 0x03, 0x00, 0x00,
            0x01, 0x40, 0x06, 0x40, 0x06, 0x00, 0x03,
        ])
        let parsed = BLEVendorProtocol.parseDpiStages(blob: blob)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.active, 2)
        XCTAssertEqual(parsed?.count, 3)
        XCTAssertEqual(parsed?.values, [3200, 800, 1600])
    }

    func testParseVariableLengthDpiBlobPadsFromLastWireEntry() {
        // [active=2][count=3]
        // stage entries present: 800 then 3200.
        // Parser should preserve wire order and pad the missing trailing entry.
        let blob = Data([
            0x02, 0x03,
            0x00, 0x20, 0x03, 0x20, 0x03, 0x00, 0x00,
            0x02, 0x80, 0x0C, 0x80, 0x0C, 0x00, 0x03,
        ])
        let parsed = BLEVendorProtocol.parseDpiStages(blob: blob)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.count, 3)
        XCTAssertEqual(parsed?.values, [800, 3200, 3200])
        XCTAssertEqual(parsed?.active, 1)
    }

    func testParseDpiBlobLengthShortByOneStillParsesTwoStages() {
        // Some capture-backed read headers report payload length one byte short.
        // Here count=2 with second entry marker omitted (15 bytes total).
        let blob = Data([
            0x01, 0x02,
            0x01, 0x20, 0x03, 0x20, 0x03, 0x00, 0x00,
            0x02, 0x00, 0x19, 0x00, 0x19, 0x00,
        ])
        let parsed = BLEVendorProtocol.parseDpiStages(blob: blob)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.active, 0)
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?.values, [800, 6400])
    }

    func testParseDpiBlobLengthShortByOneStillParsesThreeStages() {
        // count=3 with final entry marker omitted (22 bytes total).
        let blob = Data([
            0x02, 0x03,
            0x01, 0x20, 0x03, 0x20, 0x03, 0x00, 0x00,
            0x02, 0x40, 0x06, 0x40, 0x06, 0x00, 0x00,
            0x03, 0x80, 0x0C, 0x80, 0x0C, 0x00,
        ])
        let parsed = BLEVendorProtocol.parseDpiStages(blob: blob)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.active, 1)
        XCTAssertEqual(parsed?.count, 3)
        XCTAssertEqual(parsed?.values, [800, 1600, 3200])
    }
}
