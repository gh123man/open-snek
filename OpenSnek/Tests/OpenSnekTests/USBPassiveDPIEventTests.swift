import Foundation
import XCTest
import OpenSnekCore
@testable import OpenSnekHardware
@testable import OpenSnek

final class USBPassiveDPIEventTests: XCTestCase {
    func testPassiveUSBMonitorReplaceTargetsReturnsForEmptyList() async throws {
        let monitor = PassiveDPIEventMonitor()

        let active = try await withAsyncTimeout(seconds: 1.0) {
            await monitor.replaceTargets([])
        }

        XCTAssertTrue(active.isEmpty)
    }

    func testPassiveMonitorReusesRegistrationForStableDeviceIdentity() {
        let descriptor = PassiveDPIInputDescriptor(
            usagePage: 0x01,
            usage: 0x02,
            reportID: 0x05,
            subtype: 0x02,
            heartbeatSubtype: 0x10,
            minInputReportSize: 7,
            maxFeatureReportSize: 1
        )

        XCTAssertTrue(
            PassiveDPIEventMonitor.shouldReuseRegistration(
                existingDescriptor: descriptor,
                existingDeviceIdentityToken: "registry:42",
                targetDescriptor: descriptor,
                targetDeviceIdentityToken: "registry:42"
            )
        )
        XCTAssertFalse(
            PassiveDPIEventMonitor.shouldReuseRegistration(
                existingDescriptor: descriptor,
                existingDeviceIdentityToken: "registry:42",
                targetDescriptor: descriptor,
                targetDeviceIdentityToken: "registry:99"
            )
        )
    }

    func testPassiveDpiFastPollingFallsBackUntilRealEventIsObserved() {
        let usbDevice = makePassiveTestDevice(id: "usb-passive-gating", transport: .usb)
        let bluetoothDevice = makePassiveTestDevice(id: "bt-passive-gating", transport: .bluetooth)

        XCTAssertTrue(
            BridgeClient.shouldUseFastDPIPolling(
                device: usbDevice,
                armedPassiveDpiDeviceIDs: [],
                observedPassiveDpiDeviceIDs: []
            )
        )
        XCTAssertTrue(
            BridgeClient.shouldUseFastDPIPolling(
                device: usbDevice,
                armedPassiveDpiDeviceIDs: [usbDevice.id],
                observedPassiveDpiDeviceIDs: []
            )
        )
        XCTAssertFalse(
            BridgeClient.shouldUseFastDPIPolling(
                device: usbDevice,
                armedPassiveDpiDeviceIDs: [usbDevice.id],
                observedPassiveDpiDeviceIDs: [usbDevice.id]
            )
        )
        XCTAssertFalse(
            BridgeClient.shouldUseFastDPIPolling(
                device: bluetoothDevice,
                armedPassiveDpiDeviceIDs: [bluetoothDevice.id],
                observedPassiveDpiDeviceIDs: [bluetoothDevice.id]
            )
        )
    }

    func testPassiveDpiUpgradeRetriesOnlyForHealthyUnobservedUSBTargets() {
        let now = Date(timeIntervalSince1970: 1_773_500_000)
        let usbDevice = makePassiveTestDevice(id: "usb-passive-upgrade", transport: .usb)
        let bluetoothDevice = makePassiveTestDevice(id: "bt-passive-upgrade", transport: .bluetooth)

        XCTAssertTrue(
            BridgeClient.shouldAttemptPassiveDpiUpgrade(
                device: usbDevice,
                targetAvailable: true,
                observedPassiveDpiDeviceIDs: [],
                retryNotBefore: nil,
                now: now
            )
        )
        XCTAssertFalse(
            BridgeClient.shouldAttemptPassiveDpiUpgrade(
                device: usbDevice,
                targetAvailable: false,
                observedPassiveDpiDeviceIDs: [],
                retryNotBefore: nil,
                now: now
            )
        )
        XCTAssertFalse(
            BridgeClient.shouldAttemptPassiveDpiUpgrade(
                device: usbDevice,
                targetAvailable: true,
                observedPassiveDpiDeviceIDs: [usbDevice.id],
                retryNotBefore: nil,
                now: now
            )
        )
        XCTAssertFalse(
            BridgeClient.shouldAttemptPassiveDpiUpgrade(
                device: usbDevice,
                targetAvailable: true,
                observedPassiveDpiDeviceIDs: [],
                retryNotBefore: now.addingTimeInterval(1.0),
                now: now
            )
        )
        XCTAssertFalse(
            BridgeClient.shouldAttemptPassiveDpiUpgrade(
                device: bluetoothDevice,
                targetAvailable: true,
                observedPassiveDpiDeviceIDs: [],
                retryNotBefore: nil,
                now: now
            )
        )
    }

    func testPassiveDpiObservedStateResetsWhenRegistrationChanges() {
        let unchanged = BridgeClient.reconciledObservedPassiveDpiDeviceIDs(
            observedDeviceIDs: ["bt-device:bluetooth", "usb-device"],
            previousTargetIDsByDeviceID: [
                "bt-device:bluetooth": ["bt-a"],
                "usb-device": ["usb-a", "usb-b"],
            ],
            nextTargetIDsByDeviceID: [
                "bt-device:bluetooth": ["bt-b"],
                "usb-device": ["usb-c", "usb-d"],
            ]
        )
        let removed = BridgeClient.reconciledObservedPassiveDpiDeviceIDs(
            observedDeviceIDs: ["bt-device:bluetooth"],
            previousTargetIDsByDeviceID: [
                "bt-device:bluetooth": ["bt-a"],
            ],
            nextTargetIDsByDeviceID: [:]
        )

        XCTAssertEqual(unchanged, ["bt-device:bluetooth"])
        XCTAssertTrue(removed.isEmpty)
    }

    func testBluetoothReadStateBypassesRecentCacheWhenPassiveRealtimeDpiIsActive() {
        let device = makePassiveTestDevice(id: "bt-passive-cache", transport: .bluetooth)
        let now = Date(timeIntervalSince1970: 1_773_600_000)

        let shouldReuse = LocalBridgeBackend.shouldReuseCachedStateForRead(
            device: device,
            cachedAt: now.addingTimeInterval(-0.2),
            now: now,
            shouldUseFastDPIPolling: false
        )

        XCTAssertFalse(shouldReuse)
    }

    func testBluetoothReadStateStillUsesRecentCacheBeforePassiveRealtimeDpiIsObserved() {
        let device = makePassiveTestDevice(id: "bt-fast-cache", transport: .bluetooth)
        let now = Date(timeIntervalSince1970: 1_773_600_010)

        let shouldReuse = LocalBridgeBackend.shouldReuseCachedStateForRead(
            device: device,
            cachedAt: now.addingTimeInterval(-0.2),
            now: now,
            shouldUseFastDPIPolling: true
        )

        XCTAssertTrue(shouldReuse)
    }

    func testBluetoothRealtimeFastReadReusesRecentPassiveSnapshot() {
        let device = makePassiveTestDevice(id: "bt-fast-snapshot-cache", transport: .bluetooth)
        let now = Date(timeIntervalSince1970: 1_773_600_010)

        let shouldReuse = LocalBridgeBackend.shouldReuseCachedFastSnapshot(
            device: device,
            cachedAt: now.addingTimeInterval(-0.5),
            now: now,
            shouldUseFastDPIPolling: false
        )

        XCTAssertTrue(shouldReuse)
    }

    func testBluetoothPollingFallbackFastReadKeepsShortCacheWindow() {
        let device = makePassiveTestDevice(id: "bt-fast-fallback-cache", transport: .bluetooth)
        let now = Date(timeIntervalSince1970: 1_773_600_010)

        let shouldReuse = LocalBridgeBackend.shouldReuseCachedFastSnapshot(
            device: device,
            cachedAt: now.addingTimeInterval(-0.5),
            now: now,
            shouldUseFastDPIPolling: true
        )

        XCTAssertFalse(shouldReuse)
    }

    func testBluetoothRealtimeCorrectionDefersWhileHeartbeatIsFresh() {
        let now = Date(timeIntervalSince1970: 1_773_600_012)

        XCTAssertTrue(
            AppStateDeviceController.shouldDelayBluetoothRealtimeCorrection(
                lastHeartbeatAt: now.addingTimeInterval(-0.2),
                now: now
            )
        )
        XCTAssertFalse(
            AppStateDeviceController.shouldDelayBluetoothRealtimeCorrection(
                lastHeartbeatAt: now.addingTimeInterval(-0.5),
                now: now
            )
        )
        XCTAssertFalse(
            AppStateDeviceController.shouldDelayBluetoothRealtimeCorrection(
                lastHeartbeatAt: nil,
                now: now
            )
        )
    }

    func testBluetoothRealtimeStateRefreshDefersWhileHeartbeatIsFresh() {
        let now = Date(timeIntervalSince1970: 1_773_600_013)

        XCTAssertTrue(
            AppStateDeviceController.shouldDelayBluetoothRealtimeStateRefresh(
                transport: .bluetooth,
                transportStatus: .realTimeHID,
                lastHeartbeatAt: now.addingTimeInterval(-0.2),
                lastFullStateRefreshStartedAt: now.addingTimeInterval(-1.9),
                minimumRefreshInterval: PollingProfile.serviceInteractive.refreshStateInterval,
                now: now
            )
        )
        XCTAssertTrue(
            AppStateDeviceController.shouldDelayBluetoothRealtimeStateRefresh(
                transport: .bluetooth,
                transportStatus: .streamActive,
                lastHeartbeatAt: now.addingTimeInterval(-0.2),
                lastFullStateRefreshStartedAt: now.addingTimeInterval(-1.9),
                minimumRefreshInterval: PollingProfile.serviceInteractive.refreshStateInterval,
                now: now
            )
        )
        XCTAssertFalse(
            AppStateDeviceController.shouldDelayBluetoothRealtimeStateRefresh(
                transport: .bluetooth,
                transportStatus: .realTimeHID,
                lastHeartbeatAt: now.addingTimeInterval(-1.0),
                lastFullStateRefreshStartedAt: now.addingTimeInterval(-1.9),
                minimumRefreshInterval: PollingProfile.serviceInteractive.refreshStateInterval,
                now: now
            )
        )
        XCTAssertFalse(
            AppStateDeviceController.shouldDelayBluetoothRealtimeStateRefresh(
                transport: .bluetooth,
                transportStatus: .realTimeHID,
                lastHeartbeatAt: now.addingTimeInterval(-0.2),
                lastFullStateRefreshStartedAt: now.addingTimeInterval(-2.0),
                minimumRefreshInterval: PollingProfile.serviceInteractive.refreshStateInterval,
                now: now
            )
        )
        XCTAssertFalse(
            AppStateDeviceController.shouldDelayBluetoothRealtimeStateRefresh(
                transport: .bluetooth,
                transportStatus: .pollingFallback,
                lastHeartbeatAt: now.addingTimeInterval(-0.2),
                lastFullStateRefreshStartedAt: now.addingTimeInterval(-1.9),
                minimumRefreshInterval: PollingProfile.serviceInteractive.refreshStateInterval,
                now: now
            )
        )
        XCTAssertFalse(
            AppStateDeviceController.shouldDelayBluetoothRealtimeStateRefresh(
                transport: .usb,
                transportStatus: .realTimeHID,
                lastHeartbeatAt: now.addingTimeInterval(-0.2),
                lastFullStateRefreshStartedAt: now.addingTimeInterval(-1.9),
                minimumRefreshInterval: PollingProfile.serviceInteractive.refreshStateInterval,
                now: now
            )
        )
    }

    func testRealtimeCorrectionMinimumIntervalIsLowerInServiceMode() {
        XCTAssertEqual(
            AppStateDeviceController.realtimeCorrectionMinimumInterval(isService: true),
            0.45,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AppStateDeviceController.realtimeCorrectionMinimumInterval(isService: false),
            1.0,
            accuracy: 0.001
        )
    }

    func testBluetoothPassiveObservationResetsAfterWatchdogDetectsMissedChange() {
        let device = makePassiveTestDevice(id: "bt-watchdog", transport: .bluetooth)
        let now = Date(timeIntervalSince1970: 1_773_600_011)

        let shouldReset = BridgeClient.shouldResetBluetoothPassiveObservation(
            previousState: makePassiveTestState(
                device: device,
                dpiValues: [800, 900, 1000, 1100, 1200],
                activeStage: 1,
                dpiValue: 900
            ),
            active: 3,
            values: [800, 900, 1000, 1100, 1200],
            lastHeartbeatAt: now.addingTimeInterval(-1.6),
            lastObservedAt: now.addingTimeInterval(-1.2),
            now: now
        )
        let shouldKeepRealtime = BridgeClient.shouldResetBluetoothPassiveObservation(
            previousState: makePassiveTestState(
                device: device,
                dpiValues: [800, 900, 1000, 1100, 1200],
                activeStage: 1,
                dpiValue: 900
            ),
            active: 3,
            values: [800, 900, 1000, 1100, 1200],
            lastHeartbeatAt: now.addingTimeInterval(-0.1),
            lastObservedAt: now.addingTimeInterval(-0.1),
            now: now
        )
        let shouldKeepRealtimeOnHeartbeat = BridgeClient.shouldResetBluetoothPassiveObservation(
            previousState: makePassiveTestState(
                device: device,
                dpiValues: [800, 900, 1000, 1100, 1200],
                activeStage: 1,
                dpiValue: 900
            ),
            active: 3,
            values: [800, 900, 1000, 1100, 1200],
            lastHeartbeatAt: now.addingTimeInterval(-0.1),
            lastObservedAt: now.addingTimeInterval(-0.6),
            now: now
        )
        let shouldKeepRealtimeDuringRecentSilence = BridgeClient.shouldResetBluetoothPassiveObservation(
            previousState: makePassiveTestState(
                device: device,
                dpiValues: [800, 900, 1000, 1100, 1200],
                activeStage: 1,
                dpiValue: 900
            ),
            active: 3,
            values: [800, 900, 1000, 1100, 1200],
            lastHeartbeatAt: nil,
            lastObservedAt: now.addingTimeInterval(-0.6),
            now: now
        )

        XCTAssertTrue(shouldReset)
        XCTAssertFalse(shouldKeepRealtime)
        XCTAssertFalse(shouldKeepRealtimeOnHeartbeat)
        XCTAssertFalse(shouldKeepRealtimeDuringRecentSilence)
    }

    func testBluetoothHeartbeatHealthDisablesWatchdogResetEvenWithMissedDpiChange() {
        let device = makePassiveTestDevice(id: "bt-watchdog-heartbeat-healthy", transport: .bluetooth)
        let now = Date(timeIntervalSince1970: 1_773_600_014)

        XCTAssertTrue(
            BridgeClient.isBluetoothPassiveHeartbeatHealthy(
                lastHeartbeatAt: now.addingTimeInterval(-1.4),
                now: now
            )
        )
        XCTAssertFalse(
            BridgeClient.shouldResetBluetoothPassiveObservation(
                previousState: makePassiveTestState(
                    device: device,
                    dpiValues: [800, 900, 1000, 1100, 1200],
                    activeStage: 1,
                    dpiValue: 900
                ),
                active: 4,
                values: [800, 900, 1000, 1100, 1200],
                lastHeartbeatAt: now.addingTimeInterval(-1.4),
                lastObservedAt: now.addingTimeInterval(-1.4),
                now: now
            )
        )
        XCTAssertFalse(
            BridgeClient.isBluetoothPassiveHeartbeatHealthy(
                lastHeartbeatAt: now.addingTimeInterval(-1.6),
                now: now
            )
        )
    }

    func testBluetoothExpectedReadMasksOnlyMatchingPreviousState() {
        let expected: BridgeClient.BluetoothExpectedDpiState = (
            active: 3,
            values: [800, 900, 1000, 1100, 1200],
            pairs: [800, 900, 1000, 1100, 1200].map { DpiPair(x: $0, y: $0) },
            previousActive: 1,
            previousValues: [800, 900, 1000, 1100, 1200],
            previousPairs: [800, 900, 1000, 1100, 1200].map { DpiPair(x: $0, y: $0) },
            expiresAt: Date(timeIntervalSince1970: 1_773_600_020),
            remainingMasks: 4
        )

        XCTAssertTrue(
            BridgeClient.shouldMaskBluetoothExpectedRead(
                parsedActive: 1,
                parsedValues: [800, 900, 1000, 1100, 1200],
                parsedPairs: [800, 900, 1000, 1100, 1200].map { DpiPair(x: $0, y: $0) },
                expected: expected
            )
        )
        XCTAssertFalse(
            BridgeClient.shouldMaskBluetoothExpectedRead(
                parsedActive: 4,
                parsedValues: [800, 900, 1000, 1100, 1200],
                parsedPairs: [800, 900, 1000, 1100, 1200].map { DpiPair(x: $0, y: $0) },
                expected: expected
            )
        )
    }

    func testBluetoothExpectedReadDoesNotMaskWhenPreviousStateIsUnknown() {
        let expected: BridgeClient.BluetoothExpectedDpiState = (
            active: 2,
            values: [800, 900, 1000, 1100, 1200],
            pairs: [800, 900, 1000, 1100, 1200].map { DpiPair(x: $0, y: $0) },
            previousActive: nil,
            previousValues: nil,
            previousPairs: nil,
            expiresAt: Date(timeIntervalSince1970: 1_773_600_021),
            remainingMasks: 4
        )

        XCTAssertFalse(
            BridgeClient.shouldMaskBluetoothExpectedRead(
                parsedActive: 1,
                parsedValues: [800, 900, 1000, 1100, 1200],
                parsedPairs: [800, 900, 1000, 1100, 1200].map { DpiPair(x: $0, y: $0) },
                expected: expected
            )
        )
    }

    func testCompletedPollingReadIsMaskedWhenNewerCachedStateLandsDuringRead() {
        let start = Date(timeIntervalSince1970: 1_773_600_020)

        XCTAssertTrue(
            LocalBridgeBackend.completedReadWasSuperseded(
                startedAt: start,
                latestCachedAt: start.addingTimeInterval(0.05)
            )
        )
        XCTAssertFalse(
            LocalBridgeBackend.completedReadWasSuperseded(
                startedAt: start,
                latestCachedAt: start.addingTimeInterval(-0.05)
            )
        )
    }

    func testBluetoothHIDDiscoveryRequiresMatchingConnectedPeripheralWhenKnown() {
        XCTAssertTrue(
            BridgeClient.shouldIncludeBluetoothHIDDevice(
                hidDeviceName: "Basilisk V3 X HyperSpeed",
                connectedPeripheralNames: nil
            )
        )
        XCTAssertFalse(
            BridgeClient.shouldIncludeBluetoothHIDDevice(
                hidDeviceName: "Basilisk V3 X HyperSpeed",
                connectedPeripheralNames: []
            )
        )
        XCTAssertTrue(
            BridgeClient.shouldIncludeBluetoothHIDDevice(
                hidDeviceName: "Basilisk V3 X HyperSpeed",
                connectedPeripheralNames: ["Razer Basilisk V3 X HyperSpeed"]
            )
        )
        XCTAssertFalse(
            BridgeClient.shouldIncludeBluetoothHIDDevice(
                hidDeviceName: "Basilisk V3 X HyperSpeed",
                connectedPeripheralNames: ["DeathAdder V2 X HyperSpeed"]
            )
        )
    }

    func testPassiveDPIParserAcceptsObservedUSBAndBluetoothFrames() {
        let v3XUSBDescriptor = try! XCTUnwrap(
            DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x00B9, transport: .usb)?.passiveDPIInput
        )
        let v3XUSBObserved800 = PassiveDPIParser.parse(
            report: [0x05, 0x02, 0x03, 0x20, 0x03, 0x20, 0x00, 0x00],
            descriptor: v3XUSBDescriptor
        )
        let descriptor = try! XCTUnwrap(
            DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x00AB, transport: .usb)?.passiveDPIInput
        )

        let staged800 = PassiveDPIParser.parse(
            report: [0x05, 0x02, 0x03, 0x20, 0x03, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            descriptor: descriptor
        )
        let staged2000 = PassiveDPIParser.parse(
            report: [0x05, 0x02, 0x07, 0xD0, 0x07, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            descriptor: descriptor
        )
        let staged1100 = PassiveDPIParser.parse(
            report: [0x02, 0x04, 0x4C, 0x04, 0x4C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            descriptor: descriptor
        )
        let shortObservedFrame = PassiveDPIParser.parse(
            report: [0x05, 0x02, 0x04, 0x4C, 0x04, 0x4C, 0x00, 0x00],
            descriptor: descriptor
        )
        let usb35KDescriptor = try! XCTUnwrap(
            DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x00CB, transport: .usb)?.passiveDPIInput
        )
        let usb35KObserved1600 = PassiveDPIParser.parse(
            report: [0x05, 0x02, 0x06, 0x40, 0x06, 0x40, 0x00, 0x00],
            descriptor: usb35KDescriptor
        )
        let bluetoothDescriptor = try! XCTUnwrap(
            DeviceProfiles.resolve(vendorID: 0x068E, productID: 0x00BA, transport: .bluetooth)?.passiveDPIInput
        )
        let bluetoothDuplicatedReportID = PassiveDPIParser.parse(
            report: [0x05, 0x05, 0x02, 0x07, 0xD0, 0x07, 0xD0, 0x00, 0x00],
            descriptor: bluetoothDescriptor
        )
        let bluetoothSingleReportID = PassiveDPIParser.parse(
            report: [0x05, 0x02, 0x03, 0x20, 0x03, 0x20, 0x00, 0x00, 0x00],
            descriptor: bluetoothDescriptor
        )
        let bluetoothV3ProDescriptor = try! XCTUnwrap(
            DeviceProfiles.resolve(vendorID: 0x068E, productID: 0x00AC, transport: .bluetooth)?.passiveDPIInput
        )
        let bluetoothV3ProObserved900 = PassiveDPIParser.parse(
            report: [0x05, 0x05, 0x02, 0x03, 0x84, 0x03, 0x84, 0x00, 0x00],
            descriptor: bluetoothV3ProDescriptor
        )
        let bluetoothV3ProObserved1100 = PassiveDPIParser.parse(
            report: [0x05, 0x05, 0x02, 0x04, 0x4C, 0x04, 0x4C, 0x00, 0x00],
            descriptor: bluetoothV3ProDescriptor
        )

        XCTAssertEqual(v3XUSBObserved800, PassiveDPIReading(dpiX: 800, dpiY: 800))
        XCTAssertEqual(staged800, PassiveDPIReading(dpiX: 800, dpiY: 800))
        XCTAssertEqual(staged2000, PassiveDPIReading(dpiX: 2000, dpiY: 2000))
        XCTAssertEqual(staged1100, PassiveDPIReading(dpiX: 1100, dpiY: 1100))
        XCTAssertEqual(shortObservedFrame, PassiveDPIReading(dpiX: 1100, dpiY: 1100))
        XCTAssertEqual(usb35KObserved1600, PassiveDPIReading(dpiX: 1600, dpiY: 1600))
        XCTAssertEqual(bluetoothDuplicatedReportID, PassiveDPIReading(dpiX: 2000, dpiY: 2000))
        XCTAssertEqual(bluetoothSingleReportID, PassiveDPIReading(dpiX: 800, dpiY: 800))
        XCTAssertEqual(bluetoothV3ProObserved900, PassiveDPIReading(dpiX: 900, dpiY: 900))
        XCTAssertEqual(bluetoothV3ProObserved1100, PassiveDPIReading(dpiX: 1100, dpiY: 1100))
    }

    func testPassiveUSBParserRejectsInvalidSubtypeAndOutOfRangeValues() {
        let descriptor = try! XCTUnwrap(
            DeviceProfiles.resolve(vendorID: 0x1532, productID: 0x00AB, transport: .usb)?.passiveDPIInput
        )

        let wrongSubtype = PassiveDPIParser.parse(
            report: [0x05, 0x03, 0x03, 0x20, 0x03, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            descriptor: descriptor
        )
        let outOfRange = PassiveDPIParser.parse(
            report: [0x05, 0x02, 0x00, 0x32, 0x00, 0x32, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            descriptor: descriptor
        )

        XCTAssertNil(wrongSubtype)
        XCTAssertNil(outOfRange)
    }

    func testPassiveBluetoothParserClassifiesHeartbeatFramesSeparatelyFromDpiFrames() {
        let descriptor = try! XCTUnwrap(
            DeviceProfiles.resolve(vendorID: 0x068E, productID: 0x00BA, transport: .bluetooth)?.passiveDPIInput
        )

        let heartbeat = PassiveDPIParser.classify(
            report: [0x05, 0x05, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            descriptor: descriptor
        )
        let dpi = PassiveDPIParser.classify(
            report: [0x05, 0x05, 0x02, 0x04, 0x4C, 0x04, 0x4C, 0x00, 0x00],
            descriptor: descriptor
        )
        let other = PassiveDPIParser.classify(
            report: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00],
            descriptor: descriptor
        )

        XCTAssertEqual(heartbeat, .heartbeat)
        XCTAssertEqual(dpi, .dpi(PassiveDPIReading(dpiX: 1100, dpiY: 1100)))
        XCTAssertEqual(other, .other)
    }

    func testPassiveUSBMergeUpdatesActiveStageOnlyForUniqueMatch() {
        let device = makePassiveTestDevice(id: "usb-passive-merge", transport: .usb)
        let uniqueMatch = mergedStateFromPassiveDpiEvent(
            previous: makePassiveTestState(
                device: device,
                dpiValues: [800, 900, 2000, 1100, 1200],
                activeStage: 0,
                dpiValue: 800
            ),
            event: PassiveDPIEvent(deviceID: device.id, dpiX: 2000, dpiY: 2000, observedAt: Date())
        )
        let duplicateMatch = mergedStateFromPassiveDpiEvent(
            previous: makePassiveTestState(
                device: device,
                dpiValues: [800, 2000, 2000],
                activeStage: 0,
                dpiValue: 800
            ),
            event: PassiveDPIEvent(deviceID: device.id, dpiX: 2000, dpiY: 2000, observedAt: Date())
        )

        XCTAssertEqual(uniqueMatch?.dpi?.x, 2000)
        XCTAssertEqual(uniqueMatch?.dpi_stages.active_stage, 2)
        XCTAssertEqual(duplicateMatch?.dpi?.x, 2000)
        XCTAssertEqual(duplicateMatch?.dpi_stages.active_stage, 0)
    }

    func testPassiveUSBMergeDropsEventWithoutSeededState() {
        let merged = mergedStateFromPassiveDpiEvent(
            previous: nil,
            event: PassiveDPIEvent(deviceID: "missing", dpiX: 1100, dpiY: 1100, observedAt: Date())
        )

        XCTAssertNil(merged)
    }

    func testPassiveUSBFallbackSeedStateBootstrapsHidOnlyMonitoring() {
        let device = makePassiveTestDevice(id: "usb-passive-seed", transport: .usb)
        let event = PassiveDPIEvent(deviceID: device.id, dpiX: 1100, dpiY: 1100, observedAt: Date())

        let seeded = LocalBridgeBackend.seededStateForPassiveDpiEvent(device: device, event: event)

        XCTAssertEqual(seeded.device.id, device.id)
        XCTAssertEqual(seeded.connection, "USB")
        XCTAssertEqual(seeded.dpi?.x, 1100)
        XCTAssertEqual(seeded.dpi_stages.active_stage, 0)
        XCTAssertEqual(seeded.dpi_stages.values, [1100])
        XCTAssertEqual(seeded.onboard_profile_count, device.onboard_profile_count)
        XCTAssertTrue(seeded.capabilities.dpi_stages)
        XCTAssertTrue(seeded.capabilities.poll_rate)
    }

    func testPassiveUSBFallbackSeedStateKeepsSingleObservedStageFreshAcrossHidOnlyEvents() {
        let device = makePassiveTestDevice(id: "usb-passive-seed-refresh", transport: .usb)
        let firstEvent = PassiveDPIEvent(deviceID: device.id, dpiX: 1100, dpiY: 1100, observedAt: Date())
        let seeded = LocalBridgeBackend.seededStateForPassiveDpiEvent(device: device, event: firstEvent)

        let merged = mergedStateFromPassiveDpiEvent(
            previous: seeded,
            event: PassiveDPIEvent(deviceID: device.id, dpiX: 1600, dpiY: 1600, observedAt: Date())
        )

        XCTAssertEqual(merged?.dpi?.x, 1600)
        XCTAssertEqual(merged?.dpi_stages.active_stage, 0)
        XCTAssertEqual(merged?.dpi_stages.values, [1600])
    }

    func testBluetoothPassiveDpiExpectationUsesUniqueMatchedStage() {
        let device = makePassiveTestDevice(id: "bt-passive-expected", transport: .bluetooth)
        let event = PassiveDPIEvent(deviceID: device.id, dpiX: 1100, dpiY: 1100, observedAt: Date())
        let expectationFromSnapshot = BridgeClient.bluetoothPassiveDpiExpectation(
            event: event,
            snapshot: (
                active: 0,
                count: 5,
                slots: [800, 900, 1000, 1100, 1500],
                pairs: [800, 900, 1000, 1100, 1500].map { DpiPair(x: $0, y: $0) },
                stageIDs: [1, 2, 3, 4, 5],
                marker: 0x03
            ),
            state: nil
        )
        let expectationFromState = BridgeClient.bluetoothPassiveDpiExpectation(
            event: event,
            snapshot: nil,
            state: makePassiveTestState(
                device: device,
                dpiValues: [800, 900, 1000, 1100, 1500],
                activeStage: 0,
                dpiValue: 800
            )
        )
        let duplicateMatch = BridgeClient.bluetoothPassiveDpiExpectation(
            event: PassiveDPIEvent(deviceID: device.id, dpiX: 2000, dpiY: 2000, observedAt: Date()),
            snapshot: nil,
            state: makePassiveTestState(
                device: device,
                dpiValues: [800, 2000, 2000],
                activeStage: 0,
                dpiValue: 800
            )
        )

        XCTAssertEqual(expectationFromSnapshot?.active, 3)
        XCTAssertEqual(expectationFromSnapshot?.values, [800, 900, 1000, 1100, 1500])
        XCTAssertEqual(expectationFromState?.active, 3)
        XCTAssertNil(duplicateMatch)
    }

    func testAppStateAppliesBackendStateUpdatesWithoutWaitingForPolling() async {
        let device = makePassiveTestDevice(id: "usb-passive-live", transport: .usb)
        let backend = PassiveUpdateStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makePassiveTestState(
                    device: device,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 0,
                    dpiValue: 800
                )
            ],
            shouldUseFastPolling: false
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await Task.yield()
        await appState.deviceStore.refreshDevices()
        await backend.emitStateUpdate(
            deviceID: device.id,
            state: makePassiveTestState(
                device: device,
                dpiValues: [800, 1600, 3200],
                activeStage: 2,
                dpiValue: 3200
            )
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        let liveDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }
        let activeStage = await MainActor.run { appState.editorStore.editableActiveStage }

        XCTAssertEqual(liveDpi, 3200)
        XCTAssertEqual(activeStage, 3)
    }

    func testServiceAppStateShowsTransientStatusItemDpiAfterLiveUpdate() async {
        let device = makePassiveTestDevice(id: "usb-passive-service-badge", transport: .usb)
        let backend = PassiveUpdateStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makePassiveTestState(
                    device: device,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 0,
                    dpiValue: 800
                )
            ],
            shouldUseFastPolling: false
        )
        let appState = await MainActor.run {
            AppState(
                launchRole: .service,
                backend: backend,
                autoStart: false,
                statusItemDpiDisplayDuration: 0.05
            )
        }

        await Task.yield()
        await appState.deviceStore.refreshDevices()
        let initialTransientDpi = await MainActor.run { appState.runtimeStore.statusItemTransientDpi }
        XCTAssertNil(initialTransientDpi)

        await backend.emitStateUpdate(
            deviceID: device.id,
            state: makePassiveTestState(
                device: device,
                dpiValues: [800, 1600, 3200],
                activeStage: 2,
                dpiValue: 3200
            )
        )
        let transientDpi = try? await withAsyncTimeout(seconds: 1.0) {
            while true {
                let transientDpi = await MainActor.run { appState.runtimeStore.statusItemTransientDpi }
                if transientDpi == 3200 {
                    return transientDpi
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        XCTAssertEqual(transientDpi, 3200)

        let clearedTransientDpi = try? await withAsyncTimeout(seconds: 1.0) {
            while true {
                let transientDpi = await MainActor.run { appState.runtimeStore.statusItemTransientDpi }
                if transientDpi == nil {
                    return transientDpi
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        XCTAssertNil(clearedTransientDpi)
    }

    func testAppStateKeepsLowRateCorrectionPollingWhenPassiveUSBUpdatesAreAvailable() async {
        let device = makePassiveTestDevice(id: "usb-passive-correct", transport: .usb)
        let backend = PassiveUpdateStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makePassiveTestState(
                    device: device,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600
                )
            ],
            shouldUseFastPolling: false
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await Task.yield()
        await appState.deviceStore.refreshDevices()
        await appState.deviceStore.refreshDpiFast()

        let fastReadCount = await backend.fastReadCount()
        XCTAssertEqual(fastReadCount, 1)
    }

    func testAppStateDefersBluetoothFullStateRefreshWhileRealtimeHeartbeatIsFresh() async {
        let device = makePassiveTestDevice(id: "bt-passive-defer-state", transport: .bluetooth)
        let backend = PassiveUpdateStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makePassiveTestState(
                    device: device,
                    dpiValues: [800, 900, 1000, 1100, 1200],
                    activeStage: 1,
                    dpiValue: 900
                )
            ],
            shouldUseFastPolling: false
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await Task.yield()
        await appState.deviceStore.refreshDevices()
        let baselineReadCount = await backend.readStateCount()

        await backend.emitTransportStatusUpdate(deviceID: device.id, status: .realTimeHID)
        await backend.emitTransportStatusUpdate(deviceID: device.id, status: .streamActive, updatedAt: Date())
        try? await Task.sleep(nanoseconds: 50_000_000)
        await appState.deviceStore.refreshState()

        let readCountAfterDeferredRefresh = await backend.readStateCount()
        XCTAssertEqual(readCountAfterDeferredRefresh, baselineReadCount)
    }

    func testAppStateFallsBackToFastPollingWhenPassiveUSBUpdatesAreUnavailable() async {
        let device = makePassiveTestDevice(id: "usb-passive-fallback", transport: .usb)
        let backend = PassiveUpdateStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makePassiveTestState(
                    device: device,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600
                )
            ],
            shouldUseFastPolling: true
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await Task.yield()
        await appState.deviceStore.refreshDevices()
        await appState.deviceStore.refreshDpiFast()

        let fastReadCount = await backend.fastReadCount()
        XCTAssertEqual(fastReadCount, 1)
    }

    func testRefreshDpiFastPreservesLastStableUpdateTimestamp() async {
        let device = makePassiveTestDevice(id: "usb-fast-last-updated", transport: .usb)
        let backend = PassiveUpdateStubBackend(
            devices: [device],
            stateByDeviceID: [
                device.id: makePassiveTestState(
                    device: device,
                    dpiValues: [800, 1600, 3200],
                    activeStage: 1,
                    dpiValue: 1600
                )
            ],
            shouldUseFastPolling: true
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await Task.yield()
        await appState.deviceStore.refreshDevices()
        let initialLastUpdated = await MainActor.run { appState.deviceStore.lastUpdated }
        XCTAssertNotNil(initialLastUpdated)

        try? await Task.sleep(nanoseconds: 50_000_000)
        await appState.deviceStore.refreshDpiFast()

        let refreshedLastUpdated = await MainActor.run { appState.deviceStore.lastUpdated }
        let fastReadCount = await backend.fastReadCount()
        guard let initialLastUpdated else {
            XCTFail("Expected initial selected-state timestamp")
            return
        }
        guard let refreshedLastUpdated else {
            XCTFail("Expected selected-state timestamp after fast refresh")
            return
        }
        let initialTimestamp = initialLastUpdated.timeIntervalSince1970
        let refreshedTimestamp = refreshedLastUpdated.timeIntervalSince1970

        XCTAssertEqual(fastReadCount, 1)
        XCTAssertEqual(refreshedTimestamp, initialTimestamp, accuracy: 0.001)
    }

    func testRefreshStateDoesNotOverwriteNewerPassiveBluetoothUpdateWithStaleRead() async {
        let device = makePassiveTestDevice(id: "bt-passive-race", transport: .bluetooth)
        let staleState = makePassiveTestState(
            device: device,
            dpiValues: [800, 900, 1000, 1100, 1200],
            activeStage: 1,
            dpiValue: 900
        )
        let passiveState = makePassiveTestState(
            device: device,
            dpiValues: [800, 900, 1000, 1100, 1200],
            activeStage: 4,
            dpiValue: 1200
        )
        let backend = RacingPassiveUpdateStubBackend(
            devices: [device],
            staleStateByDeviceID: [device.id: staleState]
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let refreshTask = Task {
            await appState.deviceStore.refreshDevices()
        }

        await backend.waitForReadStateStart()
        let passiveObservedAt = Date()
        await backend.emitStateUpdate(
            deviceID: device.id,
            state: passiveState,
            updatedAt: passiveObservedAt
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        await backend.resumeReadState()
        await refreshTask.value

        let liveDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }
        let activeStage = await MainActor.run { appState.editorStore.editableActiveStage }
        let lastUpdated = await MainActor.run { appState.deviceStore.lastUpdated }

        XCTAssertEqual(liveDpi, 1200)
        XCTAssertEqual(activeStage, 5)
        XCTAssertNotNil(lastUpdated)
        XCTAssertEqual(lastUpdated!.timeIntervalSince1970, passiveObservedAt.timeIntervalSince1970, accuracy: 0.2)
    }

    func testRefreshStateDoesNotOverwriteNewerFastDpiUpdateWithStaleRead() async {
        let device = makePassiveTestDevice(id: "usb-fast-race", transport: .usb)
        let staleState = makePassiveTestState(
            device: device,
            dpiValues: [800, 900, 1000, 1100, 1200],
            activeStage: 4,
            dpiValue: 1200
        )
        let backend = RacingPassiveUpdateStubBackend(
            devices: [device],
            staleStateByDeviceID: [device.id: staleState],
            fastSnapshotByDeviceID: [device.id: DpiFastSnapshot(active: 4, values: [800, 900, 1000, 1100, 1200])],
            shouldUseFastPolling: true,
            blockReadState: false
        )
        let appState = await MainActor.run {
            AppState(launchRole: .app, backend: backend, autoStart: false)
        }

        await appState.deviceStore.refreshDevices()
        await backend.setFastSnapshot(
            DpiFastSnapshot(active: 2, values: [800, 900, 1000, 1100, 1200]),
            for: device.id
        )
        await appState.deviceStore.refreshDpiFast()
        await appState.deviceStore.refreshState()

        let liveDpi = await MainActor.run { appState.deviceStore.state?.dpi?.x }
        let activeStage = await MainActor.run { appState.editorStore.editableActiveStage }

        XCTAssertEqual(liveDpi, 1000)
        XCTAssertEqual(activeStage, 3)
    }
}

private struct AsyncTimeoutError: Error {}

private func withAsyncTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AsyncTimeoutError()
        }

        let result = try await group.next()
        group.cancelAll()
        return try XCTUnwrap(result)
    }
}

private actor PassiveUpdateStubBackend: DeviceBackend {
    nonisolated var usesRemoteServiceTransport: Bool { false }

    private let devices: [MouseDevice]
    private let shouldUseFastPollingValue: Bool
    private var stateByDeviceID: [String: MouseState]
    private var fastReadCounter = 0
    private var readStateCounter = 0
    private let stateUpdateStreamPair = AsyncStream.makeStream(of: BackendStateUpdate.self)

    init(
        devices: [MouseDevice],
        stateByDeviceID: [String: MouseState],
        shouldUseFastPolling: Bool
    ) {
        self.devices = devices
        self.stateByDeviceID = stateByDeviceID
        self.shouldUseFastPollingValue = shouldUseFastPolling
    }

    func listDevices() async throws -> [MouseDevice] {
        devices
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        readStateCounter += 1
        guard let state = stateByDeviceID[device.id] else {
            throw NSError(domain: "USBPassiveDPIEventTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing state for \(device.id)"
            ])
        }
        return state
    }

    func readDpiStagesFast(device: MouseDevice) async throws -> DpiFastSnapshot? {
        fastReadCounter += 1
        guard let state = stateByDeviceID[device.id],
              let active = state.dpi_stages.active_stage,
              let values = state.dpi_stages.values else {
            return nil
        }
        return DpiFastSnapshot(active: active, values: values)
    }

    func shouldUseFastDPIPolling(device _: MouseDevice) async -> Bool {
        shouldUseFastPollingValue
    }

    func hidAccessStatus() async -> HIDAccessStatus {
        HIDAccessStatus(
            authorization: .granted,
            hostLabel: "Test Host (io.opensnek.OpenSnek)",
            bundleIdentifier: "io.opensnek.OpenSnek",
            detail: nil
        )
    }

    func stateUpdates() async -> AsyncStream<BackendStateUpdate> {
        stateUpdateStreamPair.stream
    }

    func apply(device _: MouseDevice, patch _: DevicePatch) async throws -> MouseState {
        throw NSError(domain: "USBPassiveDPIEventTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "apply not implemented"
        ])
    }

    func readLightingColor(device _: MouseDevice) async throws -> RGBPatch? {
        nil
    }

    func debugUSBReadButtonBinding(device _: MouseDevice, slot _: Int, profile _: Int) async throws -> [UInt8]? {
        nil
    }

    func emitStateUpdate(deviceID: String, state: MouseState, updatedAt: Date = Date()) {
        stateByDeviceID[deviceID] = state
        stateUpdateStreamPair.continuation.yield(.deviceState(deviceID: deviceID, state: state, updatedAt: updatedAt))
    }

    func fastReadCount() -> Int {
        fastReadCounter
    }

    func readStateCount() -> Int {
        readStateCounter
    }

    func emitTransportStatusUpdate(
        deviceID: String,
        status: DpiUpdateTransportStatus,
        updatedAt: Date = Date()
    ) {
        stateUpdateStreamPair.continuation.yield(
            .dpiTransportStatus(deviceID: deviceID, status: status, updatedAt: updatedAt)
        )
    }
}

private actor RacingPassiveUpdateStubBackend: DeviceBackend {
    nonisolated var usesRemoteServiceTransport: Bool { false }

    private let devices: [MouseDevice]
    private var staleStateByDeviceID: [String: MouseState]
    private var fastSnapshotByDeviceID: [String: DpiFastSnapshot]
    private let shouldUseFastPollingValue: Bool
    private let stateUpdateStreamPair = AsyncStream.makeStream(of: BackendStateUpdate.self)
    private var readStateStarted = false
    private var readStateStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var readStateResumeContinuation: CheckedContinuation<Void, Never>?

    init(
        devices: [MouseDevice],
        staleStateByDeviceID: [String: MouseState],
        fastSnapshotByDeviceID: [String: DpiFastSnapshot] = [:],
        shouldUseFastPolling: Bool = false,
        blockReadState: Bool = true
    ) {
        self.devices = devices
        self.staleStateByDeviceID = staleStateByDeviceID
        self.fastSnapshotByDeviceID = fastSnapshotByDeviceID
        self.shouldUseFastPollingValue = shouldUseFastPolling
        self.blockReadState = blockReadState
    }

    private let blockReadState: Bool

    func listDevices() async throws -> [MouseDevice] {
        devices
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        readStateStarted = true
        let continuations = readStateStartedContinuations
        readStateStartedContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }

        if blockReadState {
            await withCheckedContinuation { continuation in
                readStateResumeContinuation = continuation
            }
        }

        guard let state = staleStateByDeviceID[device.id] else {
            throw NSError(domain: "USBPassiveDPIEventTests", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Missing stale state for \(device.id)"
            ])
        }
        return state
    }

    func readDpiStagesFast(device: MouseDevice) async throws -> DpiFastSnapshot? {
        fastSnapshotByDeviceID[device.id]
    }

    func shouldUseFastDPIPolling(device _: MouseDevice) async -> Bool {
        shouldUseFastPollingValue
    }

    func hidAccessStatus() async -> HIDAccessStatus {
        HIDAccessStatus(
            authorization: .granted,
            hostLabel: "Test Host (io.opensnek.OpenSnek)",
            bundleIdentifier: "io.opensnek.OpenSnek",
            detail: nil
        )
    }

    func stateUpdates() async -> AsyncStream<BackendStateUpdate> {
        stateUpdateStreamPair.stream
    }

    func apply(device _: MouseDevice, patch _: DevicePatch) async throws -> MouseState {
        throw NSError(domain: "USBPassiveDPIEventTests", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "apply not implemented"
        ])
    }

    func readLightingColor(device _: MouseDevice) async throws -> RGBPatch? {
        nil
    }

    func debugUSBReadButtonBinding(device _: MouseDevice, slot _: Int, profile _: Int) async throws -> [UInt8]? {
        nil
    }

    func waitForReadStateStart() async {
        if readStateStarted {
            return
        }

        await withCheckedContinuation { continuation in
            readStateStartedContinuations.append(continuation)
        }
    }

    func resumeReadState() {
        readStateResumeContinuation?.resume()
        readStateResumeContinuation = nil
    }

    func setFastSnapshot(_ snapshot: DpiFastSnapshot, for deviceID: String) {
        fastSnapshotByDeviceID[deviceID] = snapshot
    }

    func emitStateUpdate(deviceID: String, state: MouseState, updatedAt: Date) {
        stateUpdateStreamPair.continuation.yield(.deviceState(deviceID: deviceID, state: state, updatedAt: updatedAt))
    }
}

private func makePassiveTestDevice(id: String, transport: DeviceTransportKind) -> MouseDevice {
    MouseDevice(
        id: id,
        vendor_id: transport == .bluetooth ? 0x068E : 0x1532,
        product_id: transport == .bluetooth ? 0x00BA : 0x00AB,
        product_name: "Passive Test Mouse",
        transport: transport,
        path_b64: "",
        serial: "PASSIVE-\(id)",
        firmware: "1.0.0",
        location_id: abs(id.hashValue),
        profile_id: transport == .bluetooth ? .basiliskV3XHyperspeed : .basiliskV3Pro,
        supports_advanced_lighting_effects: transport != .bluetooth,
        onboard_profile_count: transport == .bluetooth ? 1 : 3
    )
}

private func makePassiveTestState(
    device: MouseDevice,
    dpiValues: [Int],
    activeStage: Int,
    dpiValue: Int
) -> MouseState {
    MouseState(
        device: DeviceSummary(
            id: device.id,
            product_name: device.product_name,
            serial: device.serial,
            transport: device.transport,
            firmware: device.firmware
        ),
        connection: device.transport.connectionLabel,
        battery_percent: 82,
        charging: false,
        dpi: DpiPair(x: dpiValue, y: dpiValue),
        dpi_stages: DpiStages(active_stage: activeStage, values: dpiValues),
        poll_rate: 1000,
        sleep_timeout: 300,
        device_mode: DeviceMode(mode: 0x00, param: 0x00),
        led_value: 64,
        capabilities: Capabilities(
            dpi_stages: true,
            poll_rate: true,
            power_management: true,
            button_remap: true,
            lighting: true
        )
    )
}
