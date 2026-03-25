import Foundation

public struct ButtonSlotDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let slot: Int
    public let friendlyName: String
    public let defaultKind: ButtonBindingKind

    public init(slot: Int, friendlyName: String, defaultKind: ButtonBindingKind) {
        self.slot = slot
        self.friendlyName = friendlyName
        self.defaultKind = defaultKind
    }

    public var id: Int { slot }

    public static let defaults: [ButtonSlotDescriptor] = [
        ButtonSlotDescriptor(slot: 1, friendlyName: "Left Click", defaultKind: .leftClick),
        ButtonSlotDescriptor(slot: 2, friendlyName: "Right Click", defaultKind: .rightClick),
        ButtonSlotDescriptor(slot: 3, friendlyName: "Middle Click", defaultKind: .middleClick),
        ButtonSlotDescriptor(slot: 4, friendlyName: "Back Button", defaultKind: .mouseBack),
        ButtonSlotDescriptor(slot: 5, friendlyName: "Forward Button", defaultKind: .mouseForward),
        ButtonSlotDescriptor(slot: 9, friendlyName: "Scroll Up", defaultKind: .scrollUp),
        ButtonSlotDescriptor(slot: 10, friendlyName: "Scroll Down", defaultKind: .scrollDown),
        ButtonSlotDescriptor(slot: 96, friendlyName: "DPI Cycle", defaultKind: .default),
    ]
}

public enum ButtonSlotAccess: String, Codable, Hashable, Sendable {
    case editable
    case protocolReadOnly
    case softwareReadOnly

    public var defaultNotice: String? {
        switch self {
        case .editable:
            return nil
        case .protocolReadOnly:
            return "OpenSnek can see this button, but it cannot change it yet."
        case .softwareReadOnly:
            return "OpenSnek can detect this button, but this mouse does not expose remapping for it yet."
        }
    }
}

public struct DocumentedButtonSlot: Identifiable, Hashable, Codable, Sendable {
    public let descriptor: ButtonSlotDescriptor
    public let access: ButtonSlotAccess
    public let note: String?

    public init(descriptor: ButtonSlotDescriptor, access: ButtonSlotAccess, note: String? = nil) {
        self.descriptor = descriptor
        self.access = access
        self.note = note
    }

    public var id: Int { descriptor.slot }
    public var slot: Int { descriptor.slot }
}

public struct ButtonSlotLayout: Codable, Hashable, Sendable {
    public let visibleSlots: [ButtonSlotDescriptor]
    public let writableSlots: [Int]
    public let documentedSlots: [DocumentedButtonSlot]

    public init(
        visibleSlots: [ButtonSlotDescriptor],
        writableSlots: [Int],
        documentedSlots: [DocumentedButtonSlot] = []
    ) {
        self.visibleSlots = visibleSlots
        self.writableSlots = writableSlots.sorted()

        let writable = Set(self.writableSlots)
        var documentedBySlot = Dictionary(uniqueKeysWithValues: visibleSlots.map { descriptor in
            let access: ButtonSlotAccess = writable.contains(descriptor.slot) ? .editable : .protocolReadOnly
            return (
                descriptor.slot,
                DocumentedButtonSlot(descriptor: descriptor, access: access)
            )
        })
        for slot in documentedSlots {
            documentedBySlot[slot.slot] = slot
        }
        self.documentedSlots = documentedBySlot.values.sorted { $0.slot < $1.slot }
    }

    public func isEditable(_ slot: Int) -> Bool {
        writableSlots.contains(slot)
    }

    public func access(for slot: Int) -> ButtonSlotAccess {
        documentedSlots.first(where: { $0.slot == slot })?.access ?? (isEditable(slot) ? .editable : .protocolReadOnly)
    }

    public func documentedSlot(for slot: Int) -> DocumentedButtonSlot? {
        documentedSlots.first(where: { $0.slot == slot })
    }

    public func notice(for slot: Int) -> String? {
        documentedSlot(for: slot)?.note ?? access(for: slot).defaultNotice
    }

    public var softwareReadOnlySlots: [DocumentedButtonSlot] {
        documentedSlots.filter { $0.access == .softwareReadOnly }
    }
}

public struct USBLightingZoneDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let label: String
    public let ledIDs: [UInt8]

    public init(id: String, label: String, ledIDs: [UInt8]) {
        self.id = id
        self.label = label
        self.ledIDs = ledIDs
    }
}

public struct USBLightingTargetDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let zoneID: String
    public let zoneLabel: String
    public let ledID: UInt8

    public init(zoneID: String, zoneLabel: String, ledID: UInt8) {
        self.zoneID = zoneID
        self.zoneLabel = zoneLabel
        self.ledID = ledID
    }

    public var id: String {
        "\(zoneID):\(String(format: "%02X", ledID))"
    }
}

public struct PassiveDPIInputDescriptor: Hashable, Codable, Sendable {
    public let usagePage: Int
    public let usage: Int
    public let reportID: UInt8
    public let subtype: UInt8
    public let heartbeatSubtype: UInt8?
    public let minInputReportSize: Int
    public let maxFeatureReportSize: Int?
    public let maximumDPI: Int

    public init(
        usagePage: Int,
        usage: Int,
        reportID: UInt8,
        subtype: UInt8,
        heartbeatSubtype: UInt8? = nil,
        minInputReportSize: Int,
        maxFeatureReportSize: Int? = nil,
        maximumDPI: Int = 30_000
    ) {
        self.usagePage = usagePage
        self.usage = usage
        self.reportID = reportID
        self.subtype = subtype
        self.heartbeatSubtype = heartbeatSubtype
        self.minInputReportSize = max(1, minInputReportSize)
        self.maxFeatureReportSize = maxFeatureReportSize
        self.maximumDPI = max(100, maximumDPI)
    }
}

public struct ButtonBindingDraft: Hashable, Codable, Sendable {
    public var kind: ButtonBindingKind
    public var hidKey: Int
    public var turboEnabled: Bool
    public var turboRate: Int
    public var clutchDPI: Int?

    public init(kind: ButtonBindingKind, hidKey: Int, turboEnabled: Bool, turboRate: Int, clutchDPI: Int? = nil) {
        self.kind = kind
        self.hidKey = hidKey
        self.turboEnabled = turboEnabled
        self.turboRate = turboRate
        self.clutchDPI = clutchDPI.map { max(100, min(30_000, $0)) }
    }
}

public struct DeviceProfile: Hashable, Sendable {
    public let id: DeviceProfileID
    public let productName: String
    public let transport: DeviceTransportKind
    public let supportedProducts: Set<Int>
    public let buttonLayout: ButtonSlotLayout
    public let supportsAdvancedLightingEffects: Bool
    public let supportedLightingEffects: [LightingEffectKind]
    public let usbLightingLEDIDs: [UInt8]
    public let usbLightingZones: [USBLightingZoneDescriptor]
    public let passiveDPIInput: PassiveDPIInputDescriptor?
    public let supportsIndependentXYDPI: Bool
    public let onboardProfileCount: Int
    public let isLocallyValidated: Bool

    public init(
        id: DeviceProfileID,
        productName: String,
        transport: DeviceTransportKind,
        supportedProducts: Set<Int>,
        buttonLayout: ButtonSlotLayout,
        supportsAdvancedLightingEffects: Bool,
        supportedLightingEffects: [LightingEffectKind] = LightingEffectKind.allCases,
        usbLightingLEDIDs: [UInt8] = [],
        usbLightingZones: [USBLightingZoneDescriptor] = [],
        passiveDPIInput: PassiveDPIInputDescriptor? = nil,
        supportsIndependentXYDPI: Bool = false,
        onboardProfileCount: Int = 1,
        isLocallyValidated: Bool = true
    ) {
        self.id = id
        self.productName = productName
        self.transport = transport
        self.supportedProducts = supportedProducts
        self.buttonLayout = buttonLayout
        self.supportsAdvancedLightingEffects = supportsAdvancedLightingEffects
        self.supportedLightingEffects = supportedLightingEffects
        self.usbLightingLEDIDs = usbLightingLEDIDs
        self.usbLightingZones = usbLightingZones
        self.passiveDPIInput = passiveDPIInput
        self.supportsIndependentXYDPI = supportsIndependentXYDPI
        self.onboardProfileCount = max(1, onboardProfileCount)
        self.isLocallyValidated = isLocallyValidated
    }

    public func matches(vendorID: Int, productID: Int, transport: DeviceTransportKind) -> Bool {
        guard transport == self.transport else { return false }
        let supportedVendor = vendorID == 0x1532 || vendorID == 0x068E
        return supportedVendor && supportedProducts.contains(productID)
    }

    public var allUSBLightingLEDIDs: [UInt8] {
        let ids = usbLightingLEDIDs.isEmpty ? usbLightingZones.flatMap(\.ledIDs) : usbLightingLEDIDs
        return ids.isEmpty ? [0x01] : ids
    }

    public func lightingZone(id zoneID: String) -> USBLightingZoneDescriptor? {
        usbLightingZones.first(where: { $0.id == zoneID })
    }

    public func lightingTargets(for zoneID: String? = nil) -> [USBLightingTargetDescriptor]? {
        let normalizedZoneID = zoneID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalizedZoneID == nil || normalizedZoneID == "" || normalizedZoneID == "all" {
            if !usbLightingZones.isEmpty {
                return usbLightingZones.flatMap { zone in
                    zone.ledIDs.map { ledID in
                        USBLightingTargetDescriptor(zoneID: zone.id, zoneLabel: zone.label, ledID: ledID)
                    }
                }
            }
            return allUSBLightingLEDIDs.map { ledID in
                USBLightingTargetDescriptor(
                    zoneID: String(format: "led_%02x", ledID),
                    zoneLabel: String(format: "LED 0x%02X", ledID),
                    ledID: ledID
                )
            }
        }

        guard let zone = lightingZone(id: normalizedZoneID ?? "") else { return nil }
        return zone.ledIDs.map { ledID in
            USBLightingTargetDescriptor(zoneID: zone.id, zoneLabel: zone.label, ledID: ledID)
        }
    }

    public func lightingLEDIDs(for zoneID: String? = nil) -> [UInt8]? {
        lightingTargets(for: zoneID)?.map(\.ledID)
    }
}

public enum DeviceProfiles {
    public static let minimumDPI = 100
    public static let defaultMaximumDPI = 30_000
    public static let sliderLowAnchorDPI = 2_000
    public static let sliderMidAnchorDPI = 10_000
    public static let sliderHighAnchorDPI = 20_000
    public static let sliderLowAnchorPosition = 0.5
    public static let sliderMidAnchorPosition = 0.75
    public static let sliderHighAnchorPosition = 0.9
    public static let sliderFineStepDPI = 100
    public static let sliderMidStepDPI = 250
    public static let sliderHighStepDPI = 500
    public static let sliderExtremeStepDPI = 1_000

    public static let basiliskV3XUSBLightingEffects: [LightingEffectKind] = [
        .off, .staticColor, .spectrum, .wave, .reactive, .pulseRandom, .pulseSingle, .pulseDual,
    ]

    public static let basiliskV335KUSBLightingEffects: [LightingEffectKind] = [
        .off, .staticColor, .spectrum, .wave,
    ]

    public static let basiliskV3XButtonSlots: [ButtonSlotDescriptor] = [
        ButtonSlotDescriptor(slot: 1, friendlyName: "Left Click", defaultKind: .leftClick),
        ButtonSlotDescriptor(slot: 2, friendlyName: "Right Click", defaultKind: .rightClick),
        ButtonSlotDescriptor(slot: 3, friendlyName: "Middle Click", defaultKind: .middleClick),
        ButtonSlotDescriptor(slot: 4, friendlyName: "Back Button", defaultKind: .mouseBack),
        ButtonSlotDescriptor(slot: 5, friendlyName: "Forward Button", defaultKind: .mouseForward),
        ButtonSlotDescriptor(slot: 9, friendlyName: "Scroll Up", defaultKind: .scrollUp),
        ButtonSlotDescriptor(slot: 10, friendlyName: "Scroll Down", defaultKind: .scrollDown),
        ButtonSlotDescriptor(slot: 96, friendlyName: "DPI Cycle", defaultKind: .default),
    ]

    public static let basiliskV3XUSBLightingZones: [USBLightingZoneDescriptor] = [
        USBLightingZoneDescriptor(id: "scroll_wheel", label: "Scroll Wheel", ledIDs: [0x01]),
    ]

    public static let basiliskV3XBluetoothDocumentedReadOnlySlots: [DocumentedButtonSlot] = [
        DocumentedButtonSlot(
            descriptor: ButtonSlotDescriptor(slot: 6, friendlyName: "Hypershift / Sniper", defaultKind: .default),
            access: .softwareReadOnly,
            note: "This button uses a separate device path, so OpenSnek cannot reassign it yet."
        ),
    ]

    public static let basiliskV3ProBluetoothButtonSlots: [ButtonSlotDescriptor] = [
        ButtonSlotDescriptor(slot: 1, friendlyName: "Left Click", defaultKind: .leftClick),
        ButtonSlotDescriptor(slot: 2, friendlyName: "Right Click", defaultKind: .rightClick),
        ButtonSlotDescriptor(slot: 3, friendlyName: "Middle Click", defaultKind: .middleClick),
        ButtonSlotDescriptor(slot: 4, friendlyName: "Back Button", defaultKind: .mouseBack),
        ButtonSlotDescriptor(slot: 5, friendlyName: "Forward Button", defaultKind: .mouseForward),
        ButtonSlotDescriptor(slot: 9, friendlyName: "Scroll Up", defaultKind: .scrollUp),
        ButtonSlotDescriptor(slot: 10, friendlyName: "Scroll Down", defaultKind: .scrollDown),
        ButtonSlotDescriptor(slot: 15, friendlyName: "Sensitivity Clutch", defaultKind: .default),
        ButtonSlotDescriptor(slot: 52, friendlyName: "Wheel Tilt Left", defaultKind: .scrollLeft),
        ButtonSlotDescriptor(slot: 53, friendlyName: "Wheel Tilt Right", defaultKind: .scrollRight),
    ]

    public static let basiliskV3ProBluetoothDocumentedReadOnlySlots: [DocumentedButtonSlot] = [
        DocumentedButtonSlot(
            descriptor: ButtonSlotDescriptor(slot: 15, friendlyName: "Sensitivity Clutch", defaultKind: .default),
            access: .softwareReadOnly,
            note: "The V3 Pro Bluetooth path needs a capture-backed clutch action block before OpenSnek can remap or restore this button safely."
        ),
        DocumentedButtonSlot(
            descriptor: ButtonSlotDescriptor(slot: 106, friendlyName: "Profile Button", defaultKind: .default),
            access: .softwareReadOnly,
            note: "The V3 Pro Bluetooth path still needs capture-backed profile-button defaults before OpenSnek can expose this control."
        ),
    ]

    public static let basiliskV335KUSBButtonSlots: [ButtonSlotDescriptor] = [
        ButtonSlotDescriptor(slot: 1, friendlyName: "Left Click", defaultKind: .leftClick),
        ButtonSlotDescriptor(slot: 2, friendlyName: "Right Click", defaultKind: .rightClick),
        ButtonSlotDescriptor(slot: 3, friendlyName: "Middle Click", defaultKind: .middleClick),
        ButtonSlotDescriptor(slot: 4, friendlyName: "Back Button", defaultKind: .mouseBack),
        ButtonSlotDescriptor(slot: 5, friendlyName: "Forward Button", defaultKind: .mouseForward),
        ButtonSlotDescriptor(slot: 9, friendlyName: "Scroll Up", defaultKind: .scrollUp),
        ButtonSlotDescriptor(slot: 10, friendlyName: "Scroll Down", defaultKind: .scrollDown),
        ButtonSlotDescriptor(slot: 15, friendlyName: "Sensitivity Clutch", defaultKind: .default),
        ButtonSlotDescriptor(slot: 52, friendlyName: "Wheel Tilt Left", defaultKind: .scrollLeft),
        ButtonSlotDescriptor(slot: 53, friendlyName: "Wheel Tilt Right", defaultKind: .scrollRight),
        ButtonSlotDescriptor(slot: 96, friendlyName: "DPI Button", defaultKind: .default),
    ]

    public static let basiliskV3ProUSBButtonSlots: [ButtonSlotDescriptor] = [
        ButtonSlotDescriptor(slot: 1, friendlyName: "Left Click", defaultKind: .leftClick),
        ButtonSlotDescriptor(slot: 2, friendlyName: "Right Click", defaultKind: .rightClick),
        ButtonSlotDescriptor(slot: 3, friendlyName: "Middle Click", defaultKind: .middleClick),
        ButtonSlotDescriptor(slot: 4, friendlyName: "Back Button", defaultKind: .mouseBack),
        ButtonSlotDescriptor(slot: 5, friendlyName: "Forward Button", defaultKind: .mouseForward),
        ButtonSlotDescriptor(slot: 9, friendlyName: "Scroll Up", defaultKind: .scrollUp),
        ButtonSlotDescriptor(slot: 10, friendlyName: "Scroll Down", defaultKind: .scrollDown),
        ButtonSlotDescriptor(slot: 15, friendlyName: "Sensitivity Clutch", defaultKind: .default),
        ButtonSlotDescriptor(slot: 52, friendlyName: "Wheel Tilt Left", defaultKind: .scrollLeft),
        ButtonSlotDescriptor(slot: 53, friendlyName: "Wheel Tilt Right", defaultKind: .scrollRight),
    ]

    public static let basiliskV335KUSBDocumentedReadOnlySlots: [DocumentedButtonSlot] = [
        DocumentedButtonSlot(
            descriptor: ButtonSlotDescriptor(slot: 14, friendlyName: "Scroll Mode Toggle", defaultKind: .default),
            access: .protocolReadOnly,
            note: "OpenSnek can see this button, but the mouse does not let apps remap it yet."
        ),
        DocumentedButtonSlot(
            descriptor: ButtonSlotDescriptor(slot: 106, friendlyName: "Profile Button", defaultKind: .default),
            access: .softwareReadOnly,
            note: "This button is handled separately by the mouse, so OpenSnek cannot reassign it yet."
        ),
    ]

    public static let basiliskV3USBDocumentedReadOnlySlots: [DocumentedButtonSlot] = [
        DocumentedButtonSlot(
            descriptor: ButtonSlotDescriptor(slot: 14, friendlyName: "Scroll Mode Toggle", defaultKind: .default),
            access: .protocolReadOnly,
            note: "This OpenRazer-backed profile assumes the Basilisk V3 matches the 35K's read-only scroll-mode control, but OpenSnek has not validated that on hardware yet."
        ),
        DocumentedButtonSlot(
            descriptor: ButtonSlotDescriptor(slot: 106, friendlyName: "Profile Button", defaultKind: .default),
            access: .softwareReadOnly,
            note: "This OpenRazer-backed profile assumes the Basilisk V3 matches the 35K's separate profile-button path, but OpenSnek has not validated that on hardware yet."
        ),
    ]

    public static let basiliskV335KUSBLightingZones: [USBLightingZoneDescriptor] = [
        USBLightingZoneDescriptor(id: "scroll_wheel", label: "Scroll Wheel", ledIDs: [0x01]),
        USBLightingZoneDescriptor(id: "logo", label: "Logo", ledIDs: [0x04]),
        USBLightingZoneDescriptor(id: "underglow", label: "Underglow", ledIDs: [0x0A]),
    ]

    public static let basiliskV3ProUSBDocumentedReadOnlySlots: [DocumentedButtonSlot] = [
        DocumentedButtonSlot(
            descriptor: ButtonSlotDescriptor(slot: 106, friendlyName: "Profile Button", defaultKind: .default),
            access: .protocolReadOnly,
            note: "Observed remap writes can land on this button, but the V3 Pro's USB ACK/readback path is not stable enough to ship in OpenSnek yet."
        ),
    ]

    public static let basiliskV3XUSB = DeviceProfile(
        id: .basiliskV3XHyperspeed,
        productName: "Basilisk V3 X HyperSpeed",
        transport: .usb,
        supportedProducts: [0x00B9],
        buttonLayout: ButtonSlotLayout(
            visibleSlots: basiliskV3XButtonSlots,
            writableSlots: basiliskV3XButtonSlots.map(\.slot)
        ),
        supportsAdvancedLightingEffects: true,
        supportedLightingEffects: basiliskV3XUSBLightingEffects,
        usbLightingLEDIDs: [0x01],
        usbLightingZones: basiliskV3XUSBLightingZones,
        passiveDPIInput: PassiveDPIInputDescriptor(
            usagePage: 0x01,
            usage: 0x06,
            reportID: 0x05,
            subtype: 0x02,
            minInputReportSize: 5,
            maximumDPI: 18_000
        ),
        onboardProfileCount: 1
    )

    public static let basiliskV335KUSB = DeviceProfile(
        id: .basiliskV335K,
        productName: "Basilisk V3 35K",
        transport: .usb,
        supportedProducts: [0x00CB],
        buttonLayout: ButtonSlotLayout(
            visibleSlots: basiliskV335KUSBButtonSlots,
            writableSlots: [1, 2, 3, 4, 5, 9, 10, 15, 52, 53, 96],
            documentedSlots: basiliskV335KUSBDocumentedReadOnlySlots
        ),
        supportsAdvancedLightingEffects: true,
        supportedLightingEffects: basiliskV335KUSBLightingEffects,
        usbLightingLEDIDs: [0x01, 0x04, 0x0A],
        usbLightingZones: basiliskV335KUSBLightingZones,
        passiveDPIInput: PassiveDPIInputDescriptor(
            usagePage: 0x01,
            usage: 0x06,
            reportID: 0x05,
            subtype: 0x02,
            minInputReportSize: 5,
            maximumDPI: 35_000
        ),
        supportsIndependentXYDPI: true,
        onboardProfileCount: 5
    )

    public static let basiliskV3USB = DeviceProfile(
        id: .basiliskV3,
        productName: "Basilisk V3",
        transport: .usb,
        supportedProducts: [0x0099],
        buttonLayout: ButtonSlotLayout(
            visibleSlots: basiliskV335KUSBButtonSlots,
            writableSlots: [1, 2, 3, 4, 5, 9, 10, 15, 52, 53, 96],
            documentedSlots: basiliskV3USBDocumentedReadOnlySlots
        ),
        supportsAdvancedLightingEffects: true,
        supportedLightingEffects: basiliskV335KUSBLightingEffects,
        usbLightingLEDIDs: [0x01, 0x04, 0x0A],
        usbLightingZones: basiliskV335KUSBLightingZones,
        passiveDPIInput: PassiveDPIInputDescriptor(
            usagePage: 0x01,
            usage: 0x06,
            reportID: 0x05,
            subtype: 0x02,
            minInputReportSize: 5,
            maximumDPI: 26_000
        ),
        onboardProfileCount: 5,
        isLocallyValidated: false
    )

    public static let basiliskV3ProUSB = DeviceProfile(
        id: .basiliskV3Pro,
        productName: "Basilisk V3 Pro",
        transport: .usb,
        supportedProducts: [0x00AB],
        buttonLayout: ButtonSlotLayout(
            visibleSlots: basiliskV3ProUSBButtonSlots,
            writableSlots: [1, 2, 3, 4, 5, 9, 10, 15, 52, 53],
            documentedSlots: basiliskV3ProUSBDocumentedReadOnlySlots
        ),
        supportsAdvancedLightingEffects: true,
        supportedLightingEffects: basiliskV335KUSBLightingEffects,
        usbLightingLEDIDs: [0x01, 0x04, 0x0A],
        usbLightingZones: basiliskV335KUSBLightingZones,
        passiveDPIInput: PassiveDPIInputDescriptor(
            usagePage: 0x01,
            usage: 0x06,
            reportID: 0x05,
            subtype: 0x02,
            minInputReportSize: 5,
            maximumDPI: 30_000
        ),
        supportsIndependentXYDPI: true,
        onboardProfileCount: 5
    )

    public static let basiliskV3XBluetooth = DeviceProfile(
        id: .basiliskV3XHyperspeed,
        productName: "Basilisk V3 X HyperSpeed",
        transport: .bluetooth,
        supportedProducts: [0x00BA],
        buttonLayout: ButtonSlotLayout(
            visibleSlots: basiliskV3XButtonSlots,
            writableSlots: [1, 2, 3, 4, 5, 9, 10, 96],
            documentedSlots: basiliskV3XBluetoothDocumentedReadOnlySlots
        ),
        supportsAdvancedLightingEffects: false,
        supportedLightingEffects: [.staticColor],
        usbLightingLEDIDs: [0x01],
        usbLightingZones: basiliskV3XUSBLightingZones,
        passiveDPIInput: PassiveDPIInputDescriptor(
            usagePage: 0x01,
            usage: 0x02,
            reportID: 0x05,
            subtype: 0x02,
            heartbeatSubtype: 0x10,
            minInputReportSize: 7,
            maxFeatureReportSize: 1,
            maximumDPI: 18_000
        ),
        onboardProfileCount: 1
    )

    public static let basiliskV3ProBluetooth = DeviceProfile(
        id: .basiliskV3Pro,
        productName: "Basilisk V3 Pro",
        transport: .bluetooth,
        supportedProducts: [0x00AC],
        buttonLayout: ButtonSlotLayout(
            visibleSlots: basiliskV3ProBluetoothButtonSlots,
            writableSlots: [1, 2, 3, 4, 5, 9, 10, 52, 53],
            documentedSlots: basiliskV3ProBluetoothDocumentedReadOnlySlots
        ),
        supportsAdvancedLightingEffects: false,
        supportedLightingEffects: [.staticColor],
        usbLightingLEDIDs: [0x01, 0x04, 0x0A],
        usbLightingZones: basiliskV335KUSBLightingZones,
        passiveDPIInput: PassiveDPIInputDescriptor(
            usagePage: 0x01,
            usage: 0x02,
            reportID: 0x05,
            subtype: 0x02,
            heartbeatSubtype: 0x10,
            minInputReportSize: 7,
            maxFeatureReportSize: 1,
            maximumDPI: 30_000
        ),
        supportsIndependentXYDPI: true,
        onboardProfileCount: 3
    )

    public static let all: [DeviceProfile] = [
        basiliskV3XUSB,
        basiliskV3USB,
        basiliskV3ProUSB,
        basiliskV335KUSB,
        basiliskV3XBluetooth,
        basiliskV3ProBluetooth,
    ]

    public static func resolve(vendorID: Int, productID: Int, transport: DeviceTransportKind) -> DeviceProfile? {
        all.first(where: { $0.matches(vendorID: vendorID, productID: productID, transport: transport) })
    }

    public static func resolveBluetoothFallback(name: String?) -> DeviceProfile? {
        guard let normalizedName = normalizedBluetoothFallbackName(name) else { return nil }
        return all.first { profile in
            guard profile.transport == .bluetooth else { return false }
            let normalizedProduct = normalizedBluetoothFallbackName(profile.productName) ?? ""
            return normalizedName == normalizedProduct ||
                normalizedName.contains(normalizedProduct) ||
                normalizedProduct.contains(normalizedName)
        }
    }

    private static func normalizedBluetoothFallbackName(_ name: String?) -> String? {
        BluetoothNameMatcher.normalized(name)
    }

    public static func maximumDPI(for profileID: DeviceProfileID?) -> Int {
        switch profileID {
        case .basiliskV3XHyperspeed:
            return 18_000
        case .basiliskV3:
            return 26_000
        case .basiliskV3Pro:
            return 30_000
        case .basiliskV335K:
            return 35_000
        case nil:
            return defaultMaximumDPI
        }
    }

    public static func dpiRange(for profileID: DeviceProfileID?) -> ClosedRange<Int> {
        minimumDPI...maximumDPI(for: profileID)
    }

    public static func dpiRange(for device: MouseDevice?) -> ClosedRange<Int> {
        guard let device else { return minimumDPI...defaultMaximumDPI }
        let resolvedProfileID = resolve(
            vendorID: device.vendor_id,
            productID: device.product_id,
            transport: device.transport
        )?.id ?? device.profile_id
        return dpiRange(for: resolvedProfileID)
    }

    public static func sliderMaximumDPI(for profileID: DeviceProfileID?) -> Int {
        maximumDPI(for: profileID)
    }

    public static func sliderDpiRange(for profileID: DeviceProfileID?) -> ClosedRange<Int> {
        minimumDPI...sliderMaximumDPI(for: profileID)
    }

    public static func sliderFineMaximumDPI(for profileID: DeviceProfileID?) -> Int {
        min(maximumDPI(for: profileID), sliderLowAnchorDPI)
    }

    public static func sliderFineDpiRange(for profileID: DeviceProfileID?) -> ClosedRange<Int> {
        minimumDPI...sliderFineMaximumDPI(for: profileID)
    }

    public static func sliderScaleMarkerValues(for profileID: DeviceProfileID?) -> [Int] {
        let segments = sliderSegments(for: profileID)
        guard let first = segments.first else { return [minimumDPI] }

        var markers = [first.dpiRange.lowerBound]
        for segment in segments {
            if markers.last != segment.dpiRange.upperBound {
                markers.append(segment.dpiRange.upperBound)
            }
        }
        return markers
    }

    public static func clampDPI(_ value: Int, profileID: DeviceProfileID?) -> Int {
        let range = dpiRange(for: profileID)
        return max(range.lowerBound, min(range.upperBound, value))
    }

    public static func clampDPI(_ value: Int, device: MouseDevice?) -> Int {
        let range = dpiRange(for: device)
        return max(range.lowerBound, min(range.upperBound, value))
    }

    public static func dpiSliderPosition(for value: Int, profileID: DeviceProfileID?) -> Double {
        let clamped = clampDPI(value, profileID: profileID)
        let segments = sliderSegments(for: profileID)
        guard let segment = segments.first(where: { clamped <= $0.dpiRange.upperBound }) ?? segments.last else { return 0 }
        guard segment.dpiRange.lowerBound < segment.dpiRange.upperBound else { return segment.positionRange.upperBound }

        let localFraction = Double(clamped - segment.dpiRange.lowerBound) / Double(segment.dpiRange.upperBound - segment.dpiRange.lowerBound)
        return segment.positionRange.lowerBound +
            (segment.positionRange.upperBound - segment.positionRange.lowerBound) * localFraction
    }

    public static func dpi(forSliderPosition position: Double, profileID: DeviceProfileID?) -> Int {
        let clampedPosition = max(0, min(1, position))
        let segments = sliderSegments(for: profileID)
        guard let segment = segments.first(where: { clampedPosition <= $0.positionRange.upperBound }) ?? segments.last else {
            return minimumDPI
        }

        guard segment.positionRange.lowerBound < segment.positionRange.upperBound else {
            return segment.dpiRange.upperBound
        }

        let localFraction = (clampedPosition - segment.positionRange.lowerBound) /
            (segment.positionRange.upperBound - segment.positionRange.lowerBound)
        let rawValue = Double(segment.dpiRange.lowerBound) +
            localFraction * Double(segment.dpiRange.upperBound - segment.dpiRange.lowerBound)
        return quantizedSliderDPI(rawValue, step: segment.step, within: segment.dpiRange)
    }

    private static func quantizedSliderDPI(_ value: Double, step: Int, within range: ClosedRange<Int>) -> Int {
        let quantized = Int(round(value / Double(step)) * Double(step))
        return max(range.lowerBound, min(range.upperBound, quantized))
    }

    private static func sliderSegments(for profileID: DeviceProfileID?) -> [DpiSliderSegment] {
        let maximum = sliderMaximumDPI(for: profileID)
        guard maximum > minimumDPI else {
            return [DpiSliderSegment(positionRange: 0...1, dpiRange: minimumDPI...maximum, step: sliderFineStepDPI)]
        }

        let lowUpper = min(maximum, sliderLowAnchorDPI)
        if maximum <= sliderLowAnchorDPI {
            return [DpiSliderSegment(positionRange: 0...1, dpiRange: minimumDPI...maximum, step: sliderFineStepDPI)]
        }

        var segments = [
            DpiSliderSegment(
                positionRange: 0...sliderLowAnchorPosition,
                dpiRange: minimumDPI...lowUpper,
                step: sliderFineStepDPI
            ),
        ]

        let midUpper = min(maximum, sliderMidAnchorDPI)
        if maximum <= sliderMidAnchorDPI {
            segments.append(
                DpiSliderSegment(
                    positionRange: sliderLowAnchorPosition...1,
                    dpiRange: lowUpper...maximum,
                    step: sliderMidStepDPI
                )
            )
            return segments
        }

        segments.append(
            DpiSliderSegment(
                positionRange: sliderLowAnchorPosition...sliderMidAnchorPosition,
                dpiRange: lowUpper...midUpper,
                step: sliderMidStepDPI
            )
        )

        let highUpper = min(maximum, sliderHighAnchorDPI)
        if maximum <= sliderHighAnchorDPI {
            segments.append(
                DpiSliderSegment(
                    positionRange: sliderMidAnchorPosition...1,
                    dpiRange: midUpper...maximum,
                    step: sliderHighStepDPI
                )
            )
            return segments
        }

        segments.append(
            DpiSliderSegment(
                positionRange: sliderMidAnchorPosition...sliderHighAnchorPosition,
                dpiRange: midUpper...highUpper,
                step: sliderHighStepDPI
            )
        )
        segments.append(
            DpiSliderSegment(
                positionRange: sliderHighAnchorPosition...1,
                dpiRange: highUpper...maximum,
                step: sliderExtremeStepDPI
            )
        )
        return segments
    }

    private struct DpiSliderSegment {
        let positionRange: ClosedRange<Double>
        let dpiRange: ClosedRange<Int>
        let step: Int
    }

    public static func supportsIndependentXYDPI(for profileID: DeviceProfileID?) -> Bool {
        switch profileID {
        case .basiliskV3Pro, .basiliskV335K:
            return true
        case .basiliskV3XHyperspeed, .basiliskV3, nil:
            return false
        }
    }

    public static func supportsIndependentXYDPI(for device: MouseDevice?) -> Bool {
        guard let device else { return false }
        return resolve(
            vendorID: device.vendor_id,
            productID: device.product_id,
            transport: device.transport
        )?.supportsIndependentXYDPI ?? supportsIndependentXYDPI(for: device.profile_id)
    }
}
