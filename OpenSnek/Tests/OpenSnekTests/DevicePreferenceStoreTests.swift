import XCTest
import OpenSnekAppSupport
import OpenSnekCore

final class DevicePreferenceStoreTests: XCTestCase {
    func testOpenSnekButtonProfileLibrarySupportsSaveUpdateAndDelete() {
        let suiteName = "DevicePreferenceStoreTests.Library.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DevicePreferenceStore(defaults: defaults)
        let saved = store.saveOpenSnekButtonProfile(
            name: "Travel",
            bindings: [
                4: ButtonBindingDraft(kind: .keyboardSimple, hidKey: 9, turboEnabled: false, turboRate: 0x8E)
            ]
        )

        XCTAssertEqual(store.loadOpenSnekButtonProfiles().map(\.name), ["Travel"])
        XCTAssertEqual(store.loadOpenSnekButtonProfiles().first?.bindings[4]?.hidKey, 9)

        let updated = store.updateOpenSnekButtonProfile(
            id: saved.id,
            name: "Travel 2",
            bindings: [
                4: ButtonBindingDraft(kind: .mouseForward, hidKey: 4, turboEnabled: false, turboRate: 0x8E)
            ]
        )

        XCTAssertEqual(updated?.name, "Travel 2")
        XCTAssertEqual(store.loadOpenSnekButtonProfiles().first?.bindings[4]?.kind, .mouseForward)

        store.deleteOpenSnekButtonProfile(id: saved.id)
        XCTAssertTrue(store.loadOpenSnekButtonProfiles().isEmpty)
    }

    func testButtonBindingPersistencePreservesNonTextKeyboardHidKeys() {
        let suiteName = "DevicePreferenceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DevicePreferenceStore(defaults: defaults)
        let device = MouseDevice(
            id: "bt-device",
            vendor_id: 0x068E,
            product_id: 0x00BA,
            product_name: "Basilisk V3 X HyperSpeed",
            transport: .bluetooth,
            path_b64: "",
            serial: nil,
            firmware: nil,
            profile_id: .basiliskV3XHyperspeed,
            button_layout: ButtonSlotLayout(
                visibleSlots: DeviceProfiles.basiliskV3XButtonSlots,
                writableSlots: DeviceProfiles.basiliskV3XButtonSlots.map(\.slot),
                documentedSlots: DeviceProfiles.basiliskV3XBluetoothDocumentedReadOnlySlots
            )
        )

        store.persistButtonBinding(
            ButtonBindingPatch(slot: 5, kind: .keyboardSimple, hidKey: 80, turboEnabled: false, turboRate: nil),
            device: device,
            profile: 1
        )
        store.persistButtonBinding(
            ButtonBindingPatch(slot: 4, kind: .keyboardSimple, hidKey: 224, turboEnabled: true, turboRate: 75),
            device: device,
            profile: 1
        )

        let loaded = store.loadPersistedButtonBindings(device: device, profile: 1)
        XCTAssertEqual(loaded[5]?.kind, .keyboardSimple)
        XCTAssertEqual(loaded[5]?.hidKey, 80)
        XCTAssertEqual(loaded[4]?.kind, .keyboardSimple)
        XCTAssertEqual(loaded[4]?.hidKey, 224)
        XCTAssertEqual(loaded[4]?.turboEnabled, true)
        XCTAssertEqual(loaded[4]?.turboRate, 75)
    }

    func test35KTopDPIButtonPersistsSemanticDefaultAsDefaultKind() {
        let suiteName = "DevicePreferenceStoreTests.35KDefault.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DevicePreferenceStore(defaults: defaults)
        let device = MouseDevice(
            id: "usb-35k",
            vendor_id: 0x1532,
            product_id: 0x00CB,
            product_name: "Basilisk V3 35K",
            transport: .usb,
            path_b64: "",
            serial: nil,
            firmware: nil,
            profile_id: .basiliskV335K,
            button_layout: DeviceProfiles.resolve(
                vendorID: 0x1532,
                productID: 0x00CB,
                transport: .usb
            )?.buttonLayout
        )

        store.persistButtonBinding(
            ButtonBindingPatch(slot: 96, kind: .dpiCycle, hidKey: nil, turboEnabled: false, turboRate: nil),
            device: device,
            profile: 1
        )

        let loaded = store.loadPersistedButtonBindings(device: device, profile: 1)
        XCTAssertEqual(loaded[96]?.kind, .default)
    }

    func testConnectBehaviorPersistsPerDevice() {
        let suiteName = "DevicePreferenceStoreTests.ConnectBehavior.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DevicePreferenceStore(defaults: defaults)
        let device = MouseDevice(
            id: "usb-connect-behavior",
            vendor_id: 0x1532,
            product_id: 0x00AB,
            product_name: "Basilisk V3 Pro",
            transport: .usb,
            path_b64: "",
            serial: "CONNECT-BEHAVIOR",
            firmware: nil,
            profile_id: .basiliskV3Pro
        )

        store.persistConnectBehavior(.restoreOpenSnekSettings, device: device)

        XCTAssertEqual(store.loadConnectBehavior(device: device), .restoreOpenSnekSettings)
    }

    func testDeviceSettingsSnapshotRoundTrips() {
        let suiteName = "DevicePreferenceStoreTests.SettingsSnapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DevicePreferenceStore(defaults: defaults)
        let device = MouseDevice(
            id: "usb-settings-snapshot",
            vendor_id: 0x1532,
            product_id: 0x00AB,
            product_name: "Basilisk V3 Pro",
            transport: .usb,
            path_b64: "",
            serial: "SETTINGS-SNAPSHOT",
            firmware: nil,
            profile_id: .basiliskV3Pro
        )
        let snapshot = PersistedDeviceSettingsSnapshot(
            stageCount: 3,
            stageValues: [800, 1600, 3200],
            stagePairs: [DpiPair(x: 800, y: 800), DpiPair(x: 1600, y: 1600), DpiPair(x: 3200, y: 3200)],
            activeStage: 2,
            pollRate: 500,
            sleepTimeout: 420,
            lowBatteryThresholdRaw: 0x24,
            scrollMode: 1,
            scrollAcceleration: true,
            scrollSmartReel: false,
            ledBrightness: 77,
            primaryLightingColor: RGBColor(r: 10, g: 20, b: 30),
            lightingEffect: LightingEffectPatch(kind: .wave, primary: RGBPatch(r: 10, g: 20, b: 30), waveDirection: .right),
            usbLightingZoneID: "logo",
            buttonBindings: [
                5: ButtonBindingDraft(kind: .keyboardSimple, hidKey: 80, turboEnabled: false, turboRate: 0x8E, clutchDPI: nil)
            ]
        )

        store.persistDeviceSettingsSnapshot(snapshot, device: device)

        XCTAssertEqual(store.loadPersistedDeviceSettingsSnapshot(device: device), snapshot)
    }

    func testDisabledSettingStoragePreservesPreviouslyStoredDeviceState() {
        let suiteName = "DevicePreferenceStoreTests.SettingStorageDisabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DevicePreferenceStore(defaults: defaults)
        let device = MouseDevice(
            id: "usb-storage-gated-device",
            vendor_id: 0x1532,
            product_id: 0x00AB,
            product_name: "Basilisk V3 Pro",
            transport: .usb,
            path_b64: "",
            serial: "STORAGE-GATED",
            firmware: nil,
            profile_id: .basiliskV3Pro,
            button_layout: DeviceProfiles.resolve(
                vendorID: 0x1532,
                productID: 0x00AB,
                transport: .usb
            )?.buttonLayout
        )

        let storedSnapshot = PersistedDeviceSettingsSnapshot(
            stageCount: 3,
            stageValues: [800, 1600, 3200],
            stagePairs: [DpiPair(x: 800, y: 800), DpiPair(x: 1600, y: 1600), DpiPair(x: 3200, y: 3200)],
            activeStage: 2,
            pollRate: 500,
            sleepTimeout: 420,
            lowBatteryThresholdRaw: 0x24,
            scrollMode: 1,
            scrollAcceleration: true,
            scrollSmartReel: false,
            ledBrightness: 77,
            primaryLightingColor: RGBColor(r: 10, g: 20, b: 30),
            lightingEffect: nil,
            usbLightingZoneID: "logo",
            buttonBindings: [
                5: ButtonBindingDraft(kind: .keyboardSimple, hidKey: 80, turboEnabled: false, turboRate: 0x8E, clutchDPI: nil)
            ]
        )
        store.persistDeviceSettingsSnapshot(storedSnapshot, device: device)
        store.persistLightingColor(RGBColor(r: 12, g: 34, b: 56), device: device, zoneID: "logo")
        store.savePersistedButtonBindings(
            device: device,
            bindings: [
                5: ButtonBindingDraft(kind: .keyboardSimple, hidKey: 80, turboEnabled: false, turboRate: 0x8E, clutchDPI: nil)
            ],
            profile: 1
        )

        defaults.set(false, forKey: DeveloperRuntimeOptions.settingStorageEnabledDefaultsKey)

        let newSnapshot = PersistedDeviceSettingsSnapshot(
            stageCount: 2,
            stageValues: [400, 6400],
            stagePairs: [DpiPair(x: 400, y: 400), DpiPair(x: 6400, y: 6400)],
            activeStage: 1,
            pollRate: 1000,
            sleepTimeout: 300,
            lowBatteryThresholdRaw: 0x18,
            scrollMode: 0,
            scrollAcceleration: false,
            scrollSmartReel: true,
            ledBrightness: 20,
            primaryLightingColor: RGBColor(r: 200, g: 210, b: 220),
            lightingEffect: LightingEffectPatch(
                kind: .wave,
                primary: RGBPatch(r: 200, g: 210, b: 220),
                waveDirection: .right
            ),
            usbLightingZoneID: "scroll_wheel",
            buttonBindings: [
                5: ButtonBindingDraft(kind: .mouseForward, hidKey: 4, turboEnabled: false, turboRate: 0x8E, clutchDPI: nil)
            ]
        )
        store.persistDeviceSettingsSnapshot(newSnapshot, device: device)
        store.persistLightingColor(RGBColor(r: 99, g: 88, b: 77), device: device, zoneID: "logo")
        store.savePersistedButtonBindings(
            device: device,
            bindings: [
                5: ButtonBindingDraft(kind: .mouseForward, hidKey: 4, turboEnabled: false, turboRate: 0x8E, clutchDPI: nil)
            ],
            profile: 1
        )

        XCTAssertEqual(store.loadPersistedDeviceSettingsSnapshot(device: device), storedSnapshot)
        XCTAssertEqual(store.loadPersistedLightingColor(device: device, zoneID: "logo"), RGBColor(r: 12, g: 34, b: 56))
        XCTAssertEqual(store.loadPersistedButtonBindings(device: device, profile: 1)[5]?.kind, .keyboardSimple)
    }
}
