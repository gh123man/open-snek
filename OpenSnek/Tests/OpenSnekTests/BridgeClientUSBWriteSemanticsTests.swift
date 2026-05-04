import XCTest
@testable import OpenSnek

final class BridgeClientUSBWriteSemanticsTests: XCTestCase {
    func testUSBButtonWriteFailsWhenPersistentLayerFails() {
        XCTAssertFalse(
            BridgeClient.usbButtonWriteSucceeded(
                writePersistentLayer: true,
                writeDirectLayer: true,
                wrotePersistent: false,
                wroteDirect: true
            )
        )
    }

    func testUSBButtonWriteFailsWhenDirectLayerFails() {
        XCTAssertFalse(
            BridgeClient.usbButtonWriteSucceeded(
                writePersistentLayer: true,
                writeDirectLayer: true,
                wrotePersistent: true,
                wroteDirect: false
            )
        )
    }

    func testUSBButtonWriteSucceedsWhenOnlyPersistentLayerRequestedAndWritten() {
        XCTAssertTrue(
            BridgeClient.usbButtonWriteSucceeded(
                writePersistentLayer: true,
                writeDirectLayer: false,
                wrotePersistent: true,
                wroteDirect: false
            )
        )
    }

    func testUSBButtonWriteSucceedsWhenOnlyDirectLayerRequestedAndWritten() {
        XCTAssertTrue(
            BridgeClient.usbButtonWriteSucceeded(
                writePersistentLayer: false,
                writeDirectLayer: true,
                wrotePersistent: false,
                wroteDirect: true
            )
        )
    }

    func testUSBSleepTimeoutWriteSucceedsWhenAcked() {
        XCTAssertTrue(
            BridgeClient.usbSleepTimeoutWriteSucceeded(
                writeAcknowledged: true,
                requestedSeconds: 135,
                readbackSeconds: nil
            )
        )
    }

    func testUSBSleepTimeoutWriteSucceedsWhenReadbackMatchesClampedValue() {
        XCTAssertTrue(
            BridgeClient.usbSleepTimeoutWriteSucceeded(
                writeAcknowledged: false,
                requestedSeconds: 30,
                readbackSeconds: 60
            )
        )
    }

    func testUSBSleepTimeoutWriteFailsWhenAckMissingAndReadbackMismatches() {
        XCTAssertFalse(
            BridgeClient.usbSleepTimeoutWriteSucceeded(
                writeAcknowledged: false,
                requestedSeconds: 135,
                readbackSeconds: 120
            )
        )
    }
}
