import XCTest
@testable import OpenSnekMac

final class DevicePatchMergeTests: XCTestCase {
    func testMergedUsesNewestFieldValues() {
        let older = DevicePatch(
            pollRate: 500,
            sleepTimeout: 300,
            deviceMode: DeviceMode(mode: 0x00, param: 0x00),
            lowBatteryThresholdRaw: 0x26,
            scrollMode: 0,
            scrollAcceleration: false,
            scrollSmartReel: false,
            dpiStages: [800, 1600],
            activeStage: 0,
            ledBrightness: 120,
            ledRGB: RGBPatch(r: 10, g: 20, b: 30),
            lightingEffect: LightingEffectPatch(kind: .spectrum),
            buttonBinding: ButtonBindingPatch(slot: 2, kind: .rightClick, hidKey: nil, turboEnabled: true, turboRate: 142)
        )
        let newer = DevicePatch(
            pollRate: 1000,
            sleepTimeout: 480,
            deviceMode: DeviceMode(mode: 0x03, param: 0x00),
            lowBatteryThresholdRaw: 0x3F,
            scrollMode: 1,
            scrollAcceleration: true,
            scrollSmartReel: true,
            dpiStages: [1200, 6400],
            activeStage: 1,
            ledBrightness: 200,
            ledRGB: RGBPatch(r: 1, g: 2, b: 3),
            lightingEffect: LightingEffectPatch(kind: .reactive, primary: RGBPatch(r: 9, g: 8, b: 7), reactiveSpeed: 4),
            buttonBinding: ButtonBindingPatch(slot: 3, kind: .keyboardSimple, hidKey: 40, turboEnabled: false, turboRate: nil)
        )

        let merged = older.merged(with: newer)
        XCTAssertEqual(merged.pollRate, 1000)
        XCTAssertEqual(merged.sleepTimeout, 480)
        XCTAssertEqual(merged.deviceMode?.mode, 0x03)
        XCTAssertEqual(merged.lowBatteryThresholdRaw, 0x3F)
        XCTAssertEqual(merged.scrollMode, 1)
        XCTAssertEqual(merged.scrollAcceleration, true)
        XCTAssertEqual(merged.scrollSmartReel, true)
        XCTAssertEqual(merged.dpiStages ?? [], [1200, 6400])
        XCTAssertEqual(merged.activeStage, 1)
        XCTAssertEqual(merged.ledBrightness, 200)
        XCTAssertEqual(merged.ledRGB?.r, 1)
        XCTAssertEqual(merged.lightingEffect?.kind, .reactive)
        XCTAssertEqual(merged.lightingEffect?.reactiveSpeed, 4)
        XCTAssertEqual(merged.buttonBinding?.slot, 3)
        XCTAssertEqual(merged.buttonBinding?.kind, .keyboardSimple)
        XCTAssertEqual(merged.buttonBinding?.turboEnabled, false)
    }

    func testMergedKeepsExistingFieldsWhenNewestPatchPartial() {
        let older = DevicePatch(
            pollRate: 1000,
            sleepTimeout: 300,
            deviceMode: DeviceMode(mode: 0x00, param: 0x00),
            lowBatteryThresholdRaw: 0x26,
            scrollMode: 1,
            scrollAcceleration: true,
            scrollSmartReel: false,
            dpiStages: [800, 6400],
            activeStage: 1,
            ledBrightness: 150,
            ledRGB: RGBPatch(r: 100, g: 120, b: 140),
            lightingEffect: LightingEffectPatch(kind: .pulseDual, primary: RGBPatch(r: 1, g: 2, b: 3), secondary: RGBPatch(r: 4, g: 5, b: 6)),
            buttonBinding: ButtonBindingPatch(slot: 4, kind: .mouseBack, hidKey: nil, turboEnabled: true, turboRate: 62)
        )
        let newer = DevicePatch(activeStage: 0)

        let merged = older.merged(with: newer)
        XCTAssertEqual(merged.pollRate, 1000)
        XCTAssertEqual(merged.sleepTimeout, 300)
        XCTAssertEqual(merged.deviceMode?.mode, 0x00)
        XCTAssertEqual(merged.lowBatteryThresholdRaw, 0x26)
        XCTAssertEqual(merged.scrollMode, 1)
        XCTAssertEqual(merged.scrollAcceleration, true)
        XCTAssertEqual(merged.scrollSmartReel, false)
        XCTAssertEqual(merged.dpiStages ?? [], [800, 6400])
        XCTAssertEqual(merged.activeStage, 0)
        XCTAssertEqual(merged.ledBrightness, 150)
        XCTAssertEqual(merged.ledRGB?.g, 120)
        XCTAssertEqual(merged.lightingEffect?.kind, .pulseDual)
        XCTAssertEqual(merged.lightingEffect?.secondary.b, 6)
        XCTAssertEqual(merged.buttonBinding?.kind, .mouseBack)
        XCTAssertEqual(merged.buttonBinding?.turboEnabled, true)
        XCTAssertEqual(merged.buttonBinding?.turboRate, 62)
    }
}
