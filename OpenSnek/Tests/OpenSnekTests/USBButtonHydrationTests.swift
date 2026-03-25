import XCTest
import OpenSnekCore

final class USBButtonHydrationTests: XCTestCase {
    func testDefaultBlockMapsToDefaultKind() {
        let block: [UInt8] = [0x01, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(slot: 4, functionBlock: block)
        XCTAssertEqual(draft?.kind, .default)
        XCTAssertEqual(draft?.turboEnabled, false)
    }

    func testMouseBlockMapsToMouseKind() {
        let block: [UInt8] = [0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(slot: 4, functionBlock: block)
        XCTAssertEqual(draft?.kind, .rightClick)
        XCTAssertEqual(draft?.turboEnabled, false)
    }

    func testKeyboardSimpleBlockMapsToKeyboardKind() {
        let block: [UInt8] = [0x02, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(slot: 4, functionBlock: block)
        XCTAssertEqual(draft?.kind, .keyboardSimple)
        XCTAssertEqual(draft?.hidKey, 4)
        XCTAssertEqual(draft?.turboEnabled, false)
    }

    func testKeyboardTurboBlockMapsToTurboKeyboardKind() {
        let block: [UInt8] = [0x0D, 0x04, 0x00, 0x04, 0x00, 0x8E, 0x00]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(slot: 4, functionBlock: block)
        XCTAssertEqual(draft?.kind, .keyboardSimple)
        XCTAssertEqual(draft?.hidKey, 4)
        XCTAssertEqual(draft?.turboEnabled, true)
        XCTAssertEqual(draft?.turboRate, 142)
    }

    func testMouseTurboBlockMapsToTurboMouseKind() {
        let block: [UInt8] = [0x0E, 0x03, 0x02, 0x00, 0x40, 0x00, 0x00]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(slot: 4, functionBlock: block)
        XCTAssertEqual(draft?.kind, .rightClick)
        XCTAssertEqual(draft?.turboEnabled, true)
        XCTAssertEqual(draft?.turboRate, 64)
    }

    func testDisabledBlockMapsToDisabledKind() {
        let block: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(slot: 4, functionBlock: block)
        XCTAssertEqual(draft?.kind, .clearLayer)
        XCTAssertEqual(draft?.turboEnabled, false)
    }

    func testBasiliskV335KDefaultDPIButtonBlockMapsToDefaultKind() {
        let block: [UInt8] = [0x04, 0x02, 0x0F, 0x7B, 0x00, 0x00, 0x00]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(
            slot: 96,
            functionBlock: block,
            profileID: .basiliskV335K
        )
        XCTAssertEqual(draft?.kind, .default)
    }

    func testBasiliskV335KDefaultDPIButtonBlockIsPreservedForRestore() {
        let block = ButtonBindingSupport.defaultUSBFunctionBlock(for: 96, profileID: .basiliskV335K)
        XCTAssertEqual(block, [0x04, 0x02, 0x0F, 0x7B, 0x00, 0x00, 0x00])
    }

    func testBasiliskV3DefaultDPIButtonBlockMatches35KRestorePayload() {
        let block = ButtonBindingSupport.defaultUSBFunctionBlock(for: 96, profileID: .basiliskV3)
        XCTAssertEqual(block, [0x04, 0x02, 0x0F, 0x7B, 0x00, 0x00, 0x00])
    }

    func testExtractUSBFunctionBlockHandlesBasiliskV335KStandardSlotLayout() {
        let response: [UInt8] = [
            0x02, 0x1F, 0x00, 0x00, 0x00, 0x0A, 0x02, 0x8C,
            0x01, 0x04, 0x00, 0x01, 0x01, 0x04, 0x00, 0x00, 0x00,
        ] + Array(repeating: 0x00, count: 73)

        let block = ButtonBindingSupport.extractUSBFunctionBlock(
            response: response,
            profile: 0x01,
            slot: 0x04,
            hypershift: 0x00,
            profileID: .basiliskV335K
        )
        XCTAssertEqual(block, [0x01, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00])
    }

    func testExtractUSBFunctionBlockHandlesBasiliskV335KClutchSlotLayout() {
        let response: [UInt8] = [
            0x02, 0x1F, 0x00, 0x00, 0x00, 0x0A, 0x02, 0x8C,
            0x01, 0x60, 0x00, 0x04, 0x02, 0x0F, 0x7B, 0x00, 0x00,
        ] + Array(repeating: 0x00, count: 73)

        let block = ButtonBindingSupport.extractUSBFunctionBlock(
            response: response,
            profile: 0x01,
            slot: 0x60,
            hypershift: 0x00,
            profileID: .basiliskV335K
        )
        XCTAssertEqual(block, [0x04, 0x02, 0x0F, 0x7B, 0x00, 0x00, 0x00])
    }

    func testExtractUSBFunctionBlockHandlesBasiliskV3ExtendedSlotLayout() {
        let response: [UInt8] = [
            0x02, 0x1F, 0x00, 0x00, 0x00, 0x0A, 0x02, 0x8C,
            0x01, 0x60, 0x00, 0x04, 0x02, 0x0F, 0x7B, 0x00, 0x00,
        ] + Array(repeating: 0x00, count: 73)

        let block = ButtonBindingSupport.extractUSBFunctionBlock(
            response: response,
            profile: 0x01,
            slot: 0x60,
            hypershift: 0x00,
            profileID: .basiliskV3
        )
        XCTAssertEqual(block, [0x04, 0x02, 0x0F, 0x7B, 0x00, 0x00, 0x00])
    }

    func testExtractUSBFunctionBlockHandlesBasiliskV3ProExtendedSlotLayout() {
        let response: [UInt8] = [
            0x02, 0x1F, 0x00, 0x00, 0x00, 0x0A, 0x02, 0x8C,
            0x01, 0x34, 0x01, 0x0E, 0x03, 0x68, 0x00, 0x14, 0x00,
        ] + Array(repeating: 0x00, count: 73)

        let block = ButtonBindingSupport.extractUSBFunctionBlock(
            response: response,
            profile: 0x01,
            slot: 0x34,
            hypershift: 0x00,
            profileID: .basiliskV3Pro
        )
        XCTAssertEqual(block, [0x0E, 0x03, 0x68, 0x00, 0x14, 0x00, 0x00])
    }

    func testBasiliskV335KWheelTiltDefaultBlockMapsToDefaultKind() {
        let block: [UInt8] = [0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(
            slot: 52,
            functionBlock: block,
            profileID: .basiliskV335K
        )
        XCTAssertEqual(draft?.kind, .default)
    }

    func testBasiliskV3ProWheelTiltDefaultBlockMapsToDefaultKind() {
        let block: [UInt8] = [0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(
            slot: 52,
            functionBlock: block,
            profileID: .basiliskV3Pro
        )
        XCTAssertEqual(draft?.kind, .default)
    }

    func testBasiliskV3ProClutchDefaultBlockMapsToDefaultKind() {
        let block: [UInt8] = [0x06, 0x05, 0x05, 0x01, 0x90, 0x01, 0x90]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(
            slot: 15,
            functionBlock: block,
            profileID: .basiliskV3Pro
        )
        XCTAssertEqual(draft?.kind, .default)
    }

    func testBasiliskV335KClutchDefaultBlockMapsToDefaultKind() {
        let block: [UInt8] = [0x06, 0x01, 0x05, 0x01, 0x90, 0x01, 0x90]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(
            slot: 15,
            functionBlock: block,
            profileID: .basiliskV335K
        )
        XCTAssertEqual(draft?.kind, .default)
    }

    func testBasiliskV3ClutchDefaultBlockMapsToDefaultKind() {
        let block: [UInt8] = [0x06, 0x01, 0x05, 0x01, 0x90, 0x01, 0x90]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(
            slot: 15,
            functionBlock: block,
            profileID: .basiliskV3
        )
        XCTAssertEqual(draft?.kind, .default)
    }

    func testBasiliskV3ProClutchBlockMapsToDPIClutchOnOtherSlots() {
        let block: [UInt8] = [0x06, 0x05, 0x05, 0x01, 0x90, 0x01, 0x90]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(
            slot: 4,
            functionBlock: block,
            profileID: .basiliskV3Pro
        )
        XCTAssertEqual(draft?.kind, .dpiClutch)
    }

    func testBasiliskV3ClutchBlockMapsToDPIClutchOnOtherSlots() {
        let block: [UInt8] = [0x06, 0x05, 0x05, 0x01, 0x90, 0x01, 0x90]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(
            slot: 4,
            functionBlock: block,
            profileID: .basiliskV3
        )
        XCTAssertEqual(draft?.kind, .dpiClutch)
    }

    func testBasiliskV335KClutchBlockMapsToDPIClutchOnOtherSlots() {
        let block: [UInt8] = [0x06, 0x05, 0x05, 0x01, 0x90, 0x01, 0x90]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(
            slot: 4,
            functionBlock: block,
            profileID: .basiliskV335K
        )
        XCTAssertEqual(draft?.kind, .dpiClutch)
    }

    func testBasiliskV3ProClutchBlockPreservesConfiguredDPI() {
        let block: [UInt8] = [0x06, 0x05, 0x05, 0x03, 0x20, 0x03, 0x20]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(
            slot: 4,
            functionBlock: block,
            profileID: .basiliskV3Pro
        )
        XCTAssertEqual(draft?.kind, .dpiClutch)
        XCTAssertEqual(draft?.clutchDPI, 800)
    }

    func testBuildUSBFunctionBlockSupportsV3ProDPIClutchBinding() {
        let block = ButtonBindingSupport.buildUSBFunctionBlock(
            slot: 4,
            kind: .dpiClutch,
            hidKey: 4,
            turboEnabled: false,
            turboRate: 0x8E,
            clutchDPI: 400,
            profileID: .basiliskV3Pro
        )
        XCTAssertEqual(block, [0x06, 0x05, 0x05, 0x01, 0x90, 0x01, 0x90])
    }

    func testBuildUSBFunctionBlockSupportsCustomV3ProDPIClutchValue() {
        let block = ButtonBindingSupport.buildUSBFunctionBlock(
            slot: 4,
            kind: .dpiClutch,
            hidKey: 4,
            turboEnabled: false,
            turboRate: 0x8E,
            clutchDPI: 800,
            profileID: .basiliskV3Pro
        )
        XCTAssertEqual(block, [0x06, 0x05, 0x05, 0x03, 0x20, 0x03, 0x20])
    }

    func testBuildUSBFunctionBlockSupports35KDPIClutchValue() {
        let block = ButtonBindingSupport.buildUSBFunctionBlock(
            slot: 4,
            kind: .dpiClutch,
            hidKey: 4,
            turboEnabled: false,
            turboRate: 0x8E,
            clutchDPI: 800,
            profileID: .basiliskV335K
        )
        XCTAssertEqual(block, [0x06, 0x05, 0x05, 0x03, 0x20, 0x03, 0x20])
    }

    func testBasiliskV335KDefaultClutchFunctionBlockIsPreserved() {
        let block = ButtonBindingSupport.defaultUSBFunctionBlock(for: 15, profileID: .basiliskV335K)
        XCTAssertEqual(block, [0x06, 0x01, 0x05, 0x01, 0x90, 0x01, 0x90])
    }

    func testBasiliskV3ProDoesNotExpose35KTopDPIButtonDefault() {
        let block = ButtonBindingSupport.defaultUSBFunctionBlock(for: 96, profileID: .basiliskV3Pro)
        XCTAssertNil(block)
    }

    func testExtractUSBFunctionBlockRejectsMismatchedEchoedSlot() {
        let response: [UInt8] = [
            0x02, 0x1F, 0x00, 0x00, 0x00, 0x0A, 0x02, 0x8C,
            0x01, 0x35, 0x00, 0x01, 0x01, 0x02, 0x00, 0x00, 0x00,
        ] + Array(repeating: 0x00, count: 73)

        let block = ButtonBindingSupport.extractUSBFunctionBlock(
            response: response,
            profile: 0x01,
            slot: 0x60,
            hypershift: 0x00,
            profileID: .basiliskV335K
        )
        XCTAssertNil(block)
    }

    func testDPICycleBlockMapsToDPICycleKind() {
        let block: [UInt8] = [0x06, 0x01, 0x06, 0x00, 0x00, 0x00, 0x00]
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(
            slot: 4,
            functionBlock: block
        )
        XCTAssertEqual(draft?.kind, .dpiCycle)
    }

    func testSemanticDefaultBindingResolves35KDPIButtonToDPICycle() {
        let draft = ButtonBindingSupport.semanticDefaultButtonBinding(
            for: 96,
            profileID: .basiliskV335K
        )
        XCTAssertEqual(draft?.kind, .dpiCycle)
    }

    func test35KGenericDPICycleBlockOnTopButtonStillMapsToDefaultKind() {
        let draft = ButtonBindingSupport.buttonBindingDraftFromUSBFunctionBlock(
            slot: 96,
            functionBlock: [0x06, 0x01, 0x06, 0x00, 0x00, 0x00, 0x00],
            profileID: .basiliskV335K
        )
        XCTAssertEqual(draft?.kind, .default)
    }

    func testSemanticDefaultBindingResolvesV3ProClutchToDPIClutch() {
        let draft = ButtonBindingSupport.semanticDefaultButtonBinding(
            for: 15,
            profileID: .basiliskV3Pro
        )
        XCTAssertEqual(draft?.kind, .dpiClutch)
        XCTAssertEqual(draft?.clutchDPI, ButtonBindingSupport.defaultDPIClutchDPI(for: .basiliskV3Pro))
    }
}
