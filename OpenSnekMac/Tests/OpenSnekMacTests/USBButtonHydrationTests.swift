import XCTest
@testable import OpenSnekMac

final class USBButtonHydrationTests: XCTestCase {
    func testDefaultBlockMapsToDefaultKind() {
        let block: [UInt8] = [0x01, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00]
        let draft = AppState.buttonBindingDraftFromUSBFunctionBlock(slot: 4, functionBlock: block)
        XCTAssertEqual(draft?.kind, .default)
        XCTAssertEqual(draft?.turboEnabled, false)
    }

    func testMouseBlockMapsToMouseKind() {
        let block: [UInt8] = [0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00]
        let draft = AppState.buttonBindingDraftFromUSBFunctionBlock(slot: 4, functionBlock: block)
        XCTAssertEqual(draft?.kind, .rightClick)
        XCTAssertEqual(draft?.turboEnabled, false)
    }

    func testKeyboardSimpleBlockMapsToKeyboardKind() {
        let block: [UInt8] = [0x02, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00]
        let draft = AppState.buttonBindingDraftFromUSBFunctionBlock(slot: 4, functionBlock: block)
        XCTAssertEqual(draft?.kind, .keyboardSimple)
        XCTAssertEqual(draft?.hidKey, 4)
        XCTAssertEqual(draft?.turboEnabled, false)
    }

    func testKeyboardTurboBlockMapsToTurboKeyboardKind() {
        let block: [UInt8] = [0x0D, 0x04, 0x00, 0x04, 0x00, 0x8E, 0x00]
        let draft = AppState.buttonBindingDraftFromUSBFunctionBlock(slot: 4, functionBlock: block)
        XCTAssertEqual(draft?.kind, .keyboardSimple)
        XCTAssertEqual(draft?.hidKey, 4)
        XCTAssertEqual(draft?.turboEnabled, true)
        XCTAssertEqual(draft?.turboRate, 142)
    }

    func testMouseTurboBlockMapsToTurboMouseKind() {
        let block: [UInt8] = [0x0E, 0x03, 0x02, 0x00, 0x40, 0x00, 0x00]
        let draft = AppState.buttonBindingDraftFromUSBFunctionBlock(slot: 4, functionBlock: block)
        XCTAssertEqual(draft?.kind, .rightClick)
        XCTAssertEqual(draft?.turboEnabled, true)
        XCTAssertEqual(draft?.turboRate, 64)
    }

    func testDisabledBlockMapsToDisabledKind() {
        let block: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let draft = AppState.buttonBindingDraftFromUSBFunctionBlock(slot: 4, functionBlock: block)
        XCTAssertEqual(draft?.kind, .clearLayer)
        XCTAssertEqual(draft?.turboEnabled, false)
    }
}
