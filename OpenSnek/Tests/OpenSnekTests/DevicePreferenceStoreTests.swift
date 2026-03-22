import XCTest
import OpenSnekAppSupport
import OpenSnekCore

final class DevicePreferenceStoreTests: XCTestCase {
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
}
