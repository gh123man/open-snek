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

public struct ButtonSlotLayout: Codable, Hashable, Sendable {
    public let visibleSlots: [ButtonSlotDescriptor]
    public let writableSlots: [Int]

    public init(visibleSlots: [ButtonSlotDescriptor], writableSlots: [Int]) {
        self.visibleSlots = visibleSlots
        self.writableSlots = writableSlots.sorted()
    }

    public func isEditable(_ slot: Int) -> Bool {
        writableSlots.contains(slot)
    }

    public func notice(for slot: Int) -> String? {
        isEditable(slot) ? nil : "Not writable over current protocol"
    }
}

public struct ButtonBindingDraft: Hashable, Codable, Sendable {
    public var kind: ButtonBindingKind
    public var hidKey: Int
    public var turboEnabled: Bool
    public var turboRate: Int

    public init(kind: ButtonBindingKind, hidKey: Int, turboEnabled: Bool, turboRate: Int) {
        self.kind = kind
        self.hidKey = hidKey
        self.turboEnabled = turboEnabled
        self.turboRate = turboRate
    }
}

public struct DeviceProfile: Hashable, Sendable {
    public let id: DeviceProfileID
    public let productName: String
    public let transport: DeviceTransportKind
    public let supportedProducts: Set<Int>
    public let buttonLayout: ButtonSlotLayout
    public let supportsAdvancedLightingEffects: Bool

    public init(
        id: DeviceProfileID,
        productName: String,
        transport: DeviceTransportKind,
        supportedProducts: Set<Int>,
        buttonLayout: ButtonSlotLayout,
        supportsAdvancedLightingEffects: Bool
    ) {
        self.id = id
        self.productName = productName
        self.transport = transport
        self.supportedProducts = supportedProducts
        self.buttonLayout = buttonLayout
        self.supportsAdvancedLightingEffects = supportsAdvancedLightingEffects
    }

    public func matches(vendorID: Int, productID: Int, transport: DeviceTransportKind) -> Bool {
        guard transport == self.transport else { return false }
        let supportedVendor = vendorID == 0x1532 || vendorID == 0x068E
        return supportedVendor && supportedProducts.contains(productID)
    }
}

public enum DeviceProfiles {
    public static let basiliskV3XUSB = DeviceProfile(
        id: .basiliskV3XHyperspeed,
        productName: "Basilisk V3 X HyperSpeed",
        transport: .usb,
        supportedProducts: [0x00B9],
        buttonLayout: ButtonSlotLayout(
            visibleSlots: ButtonSlotDescriptor.defaults,
            writableSlots: ButtonSlotDescriptor.defaults.map(\.slot)
        ),
        supportsAdvancedLightingEffects: true
    )

    public static let basiliskV3XBluetooth = DeviceProfile(
        id: .basiliskV3XHyperspeed,
        productName: "Basilisk V3 X HyperSpeed",
        transport: .bluetooth,
        supportedProducts: [0x00BA],
        buttonLayout: ButtonSlotLayout(
            visibleSlots: ButtonSlotDescriptor.defaults,
            writableSlots: [1, 2, 3, 4, 5, 9, 10, 96]
        ),
        supportsAdvancedLightingEffects: false
    )

    public static let all: [DeviceProfile] = [
        basiliskV3XUSB,
        basiliskV3XBluetooth,
    ]

    public static func resolve(vendorID: Int, productID: Int, transport: DeviceTransportKind) -> DeviceProfile? {
        all.first(where: { $0.matches(vendorID: vendorID, productID: productID, transport: transport) })
    }
}
