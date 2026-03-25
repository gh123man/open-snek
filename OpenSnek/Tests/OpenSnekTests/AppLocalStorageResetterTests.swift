import XCTest
import OpenSnekAppSupport
import OpenSnekCore
@testable import OpenSnek

final class AppLocalStorageResetterTests: XCTestCase {
    func testResetClearsDefaultsLaunchAgentAndLogs() async throws {
        let suiteName = "AppLocalStorageResetterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let launchAgentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: launchAgentsDirectory) }
        defer { try? FileManager.default.removeItem(at: logsDirectory) }

        let coordinator = await MainActor.run {
            BackgroundServiceCoordinator(
                defaults: UserDefaults(suiteName: suiteName)!,
                defaultsDomainName: suiteName,
                launchAgentsDirectoryURL: launchAgentsDirectory
            )
        }

        defaults.set(false, forKey: BackgroundServiceCoordinator.backgroundServiceEnabledDefaultsKey)
        defaults.set(true, forKey: BackgroundServiceCoordinator.launchAtStartupDefaultsKey)
        defaults.set(AppLogLevel.debug.rawValue, forKey: AppLog.levelDefaultsKey)
        defaults.set(false, forKey: DeveloperRuntimeOptions.pollingEnabledDefaultsKey)
        defaults.set(false, forKey: DeveloperRuntimeOptions.passiveHIDUpdatesEnabledDefaultsKey)

        let device = makeAppLocalStorageResetterTestDevice()
        let preferenceStore = DevicePreferenceStore(defaults: defaults)
        preferenceStore.persistLightingColor(RGBColor(r: 12, g: 34, b: 56), device: device)
        preferenceStore.persistButtonBinding(
            ButtonBindingPatch(slot: 5, kind: .keyboardSimple, hidKey: 80, turboEnabled: false, turboRate: nil),
            device: device,
            profile: 1
        )

        let launchAgentURL = launchAgentsDirectory.appendingPathComponent("io.opensnek.OpenSnek.service.plist")
        let launchAgentData = try PropertyListSerialization.data(
            fromPropertyList: BackgroundServiceCoordinator.launchAgentPropertyList(
                executablePath: "/Applications/OpenSnek.app/Contents/MacOS/OpenSnek",
                workingDirectoryPath: "/Applications/OpenSnek.app/Contents/MacOS"
            ),
            format: .xml,
            options: 0
        )
        try launchAgentData.write(to: launchAgentURL, options: .atomic)

        _ = FileManager.default.createFile(
            atPath: logsDirectory.appendingPathComponent(AppLog.mainLogFileName).path,
            contents: Data("main log".utf8)
        )
        _ = FileManager.default.createFile(
            atPath: logsDirectory.appendingPathComponent("service.stdout.log").path,
            contents: Data("stdout".utf8)
        )
        _ = FileManager.default.createFile(
            atPath: logsDirectory.appendingPathComponent("service.stderr.log").path,
            contents: Data("stderr".utf8)
        )

        try await MainActor.run {
            try AppLocalStorageResetter(
                backgroundServiceCoordinator: coordinator,
                logsDirectoryURL: logsDirectory
            ).reset()
        }

        let backgroundServiceEnabled = await MainActor.run { coordinator.backgroundServiceEnabled }
        let launchAtStartupEnabled = await MainActor.run { coordinator.launchAtStartupEnabled }

        XCTAssertNil(defaults.persistentDomain(forName: suiteName))
        XCTAssertTrue(backgroundServiceEnabled)
        XCTAssertFalse(launchAtStartupEnabled)
        XCTAssertNil(defaults.string(forKey: AppLog.levelDefaultsKey))
        XCTAssertNil(preferenceStore.loadPersistedLightingColor(device: device))
        XCTAssertTrue(preferenceStore.loadPersistedButtonBindings(device: device, profile: 1).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchAgentURL.path))

        let logFiles = try FileManager.default.contentsOfDirectory(atPath: logsDirectory.path).sorted()
        XCTAssertEqual(logFiles, [AppLog.mainLogFileName])
        let mainLogData = try Data(contentsOf: logsDirectory.appendingPathComponent(AppLog.mainLogFileName))
        XCTAssertTrue(mainLogData.isEmpty)
    }
}

private func makeAppLocalStorageResetterTestDevice() -> MouseDevice {
    MouseDevice(
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
}
