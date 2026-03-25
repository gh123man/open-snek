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
}
