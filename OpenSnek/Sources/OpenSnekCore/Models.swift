import Foundation

public enum DeviceTransportKind: String, CaseIterable, Codable, Hashable, Sendable {
    case usb
    case bluetooth

    public var connectionLabel: String {
        switch self {
        case .usb: return "USB"
        case .bluetooth: return "Bluetooth"
        }
    }

    public var shortLabel: String {
        switch self {
        case .usb: return "USB"
        case .bluetooth: return "BT"
        }
    }
}

public enum DeviceProfileID: String, Codable, Hashable, Sendable {
    case basiliskV3XHyperspeed = "basilisk_v3_x_hyperspeed"
    case basiliskV3 = "basilisk_v3"
    case basiliskV3Pro = "basilisk_v3_pro"
    case basiliskV335K = "basilisk_v3_35k"
}

public struct DeviceIdentity: Codable, Hashable, Sendable {
    public let vendorID: Int
    public let productID: Int
    public let locationID: Int
    public let transport: DeviceTransportKind

    public init(vendorID: Int, productID: Int, locationID: Int, transport: DeviceTransportKind) {
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.transport = transport
    }
}

public struct MouseDevice: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let vendor_id: Int
    public let product_id: Int
    public let product_name: String
    public let transport: DeviceTransportKind
    public let path_b64: String
    public let serial: String?
    public let firmware: String?
    public let location_id: Int
    public let profile_id: DeviceProfileID?
    public let button_layout: ButtonSlotLayout?
    public let supports_advanced_lighting_effects: Bool
    public let onboard_profile_count: Int

    public init(
        id: String,
        vendor_id: Int,
        product_id: Int,
        product_name: String,
        transport: DeviceTransportKind,
        path_b64: String,
        serial: String?,
        firmware: String?,
        location_id: Int = 0,
        profile_id: DeviceProfileID? = nil,
        button_layout: ButtonSlotLayout? = nil,
        supports_advanced_lighting_effects: Bool = false,
        onboard_profile_count: Int = 1
    ) {
        self.id = id
        self.vendor_id = vendor_id
        self.product_id = product_id
        self.product_name = product_name
        self.transport = transport
        self.path_b64 = path_b64
        self.serial = serial
        self.firmware = firmware
        self.location_id = location_id
        self.profile_id = profile_id
        self.button_layout = button_layout
        self.supports_advanced_lighting_effects = supports_advanced_lighting_effects
        self.onboard_profile_count = max(1, onboard_profile_count)
    }

    public var connectionLabel: String {
        transport.connectionLabel
    }

    public var showsLightingControls: Bool {
        return true
    }

    public var identity: DeviceIdentity {
        DeviceIdentity(
            vendorID: vendor_id,
            productID: product_id,
            locationID: location_id,
            transport: transport
        )
    }
}

public struct DpiPair: Codable, Hashable, Sendable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct DpiStages: Codable, Hashable, Sendable {
    public let active_stage: Int?
    public let values: [Int]?
    public let pairs: [DpiPair]?

    public init(active_stage: Int?, values: [Int]?, pairs: [DpiPair]? = nil) {
        self.active_stage = active_stage
        self.values = values ?? pairs?.map(\.x)
        self.pairs = pairs
    }
}

public struct DeviceMode: Codable, Hashable, Sendable {
    public let mode: Int
    public let param: Int

    public init(mode: Int, param: Int) {
        self.mode = mode
        self.param = param
    }
}

public struct Capabilities: Codable, Hashable, Sendable {
    public let dpi_stages: Bool
    public let poll_rate: Bool
    public let power_management: Bool
    public let button_remap: Bool
    public let lighting: Bool

    public init(dpi_stages: Bool, poll_rate: Bool, power_management: Bool = false, button_remap: Bool, lighting: Bool) {
        self.dpi_stages = dpi_stages
        self.poll_rate = poll_rate
        self.power_management = power_management
        self.button_remap = button_remap
        self.lighting = lighting
    }
}

public struct MouseState: Codable, Hashable, Sendable {
    public let device: DeviceSummary
    public let connection: String
    public let battery_percent: Int?
    public let charging: Bool?
    public let dpi: DpiPair?
    public let dpi_stages: DpiStages
    public let poll_rate: Int?
    public let sleep_timeout: Int?
    public let device_mode: DeviceMode?
    public let low_battery_threshold_raw: Int?
    public let scroll_mode: Int?
    public let scroll_acceleration: Bool?
    public let scroll_smart_reel: Bool?
    public let active_onboard_profile: Int?
    public let onboard_profile_count: Int?
    public let led_value: Int?
    public let capabilities: Capabilities

    public init(
        device: DeviceSummary,
        connection: String,
        battery_percent: Int?,
        charging: Bool?,
        dpi: DpiPair?,
        dpi_stages: DpiStages,
        poll_rate: Int?,
        sleep_timeout: Int? = nil,
        device_mode: DeviceMode?,
        low_battery_threshold_raw: Int? = nil,
        scroll_mode: Int? = nil,
        scroll_acceleration: Bool? = nil,
        scroll_smart_reel: Bool? = nil,
        active_onboard_profile: Int? = nil,
        onboard_profile_count: Int? = nil,
        led_value: Int?,
        capabilities: Capabilities
    ) {
        self.device = device
        self.connection = connection
        self.battery_percent = battery_percent
        self.charging = charging
        self.dpi = dpi
        self.dpi_stages = dpi_stages
        self.poll_rate = poll_rate
        self.sleep_timeout = sleep_timeout
        self.device_mode = device_mode
        self.low_battery_threshold_raw = low_battery_threshold_raw
        self.scroll_mode = scroll_mode
        self.scroll_acceleration = scroll_acceleration
        self.scroll_smart_reel = scroll_smart_reel
        self.active_onboard_profile = active_onboard_profile
        self.onboard_profile_count = onboard_profile_count
        self.led_value = led_value
        self.capabilities = capabilities
    }
}

public extension MouseState {
    func merged(with previous: MouseState?) -> MouseState {
        guard let previous else { return self }
        let mergedBatteryPercent = battery_percent ?? previous.battery_percent
        let mergedCharging: Bool?
        if battery_percent != nil {
            mergedCharging = charging
        } else {
            mergedCharging = charging ?? previous.charging
        }
        return MouseState(
            device: device.merged(with: previous.device),
            connection: connection,
            battery_percent: mergedBatteryPercent,
            charging: mergedCharging,
            dpi: dpi ?? previous.dpi,
            dpi_stages: DpiStages(
                active_stage: dpi_stages.active_stage ?? previous.dpi_stages.active_stage,
                values: dpi_stages.values ?? previous.dpi_stages.values,
                pairs: {
                    if let pairs = dpi_stages.pairs {
                        return pairs
                    }
                    if let values = dpi_stages.values {
                        if let previousPairs = previous.dpi_stages.pairs,
                           previousPairs.count == values.count {
                            return zip(values, previousPairs).map { value, previousPair in
                                DpiPair(x: value, y: previousPair.y)
                            }
                        }
                        return values.map { DpiPair(x: $0, y: $0) }
                    }
                    return previous.dpi_stages.pairs
                }()
            ),
            poll_rate: poll_rate ?? previous.poll_rate,
            sleep_timeout: sleep_timeout ?? previous.sleep_timeout,
            device_mode: device_mode ?? previous.device_mode,
            low_battery_threshold_raw: low_battery_threshold_raw ?? previous.low_battery_threshold_raw,
            scroll_mode: scroll_mode ?? previous.scroll_mode,
            scroll_acceleration: scroll_acceleration ?? previous.scroll_acceleration,
            scroll_smart_reel: scroll_smart_reel ?? previous.scroll_smart_reel,
            active_onboard_profile: active_onboard_profile ?? previous.active_onboard_profile,
            onboard_profile_count: onboard_profile_count ?? previous.onboard_profile_count,
            led_value: led_value ?? previous.led_value,
            capabilities: Capabilities(
                dpi_stages: capabilities.dpi_stages || previous.capabilities.dpi_stages,
                poll_rate: capabilities.poll_rate || previous.capabilities.poll_rate,
                power_management: capabilities.power_management || previous.capabilities.power_management,
                button_remap: capabilities.button_remap || previous.capabilities.button_remap,
                lighting: capabilities.lighting || previous.capabilities.lighting
            )
        )
    }
}

public struct DeviceSummary: Codable, Hashable, Sendable {
    public let id: String?
    public let product_name: String?
    public let serial: String?
    public let transport: DeviceTransportKind?
    public let firmware: String?

    public init(id: String?, product_name: String?, serial: String?, transport: DeviceTransportKind?, firmware: String?) {
        self.id = id
        self.product_name = product_name
        self.serial = serial
        self.transport = transport
        self.firmware = firmware
    }
}

public extension DeviceSummary {
    func merged(with previous: DeviceSummary) -> DeviceSummary {
        DeviceSummary(
            id: id ?? previous.id,
            product_name: product_name ?? previous.product_name,
            serial: serial ?? previous.serial,
            transport: transport ?? previous.transport,
            firmware: firmware ?? previous.firmware
        )
    }
}

public struct BridgeEnvelope: Codable, Sendable {
    public let ok: Bool
    public let error: String?
    public let devices: [MouseDevice]?
    public let state: MouseState?
    public let before: MouseState?
    public let after: MouseState?

    public init(ok: Bool, error: String?, devices: [MouseDevice]?, state: MouseState?, before: MouseState?, after: MouseState?) {
        self.ok = ok
        self.error = error
        self.devices = devices
        self.state = state
        self.before = before
        self.after = after
    }
}

public struct RGBPatch: Sendable, Hashable, Codable {
    public let r: Int
    public let g: Int
    public let b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public struct RGBColor: Equatable, Hashable, Codable, Sendable {
    public var r: Int
    public var g: Int
    public var b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public enum LightingEffectKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case staticColor = "static"
    case spectrum
    case wave
    case reactive
    case pulseRandom = "pulse_random"
    case pulseSingle = "pulse_single"
    case pulseDual = "pulse_dual"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .staticColor: return "Static"
        case .spectrum: return "Spectrum"
        case .wave: return "Wave"
        case .reactive: return "Reactive"
        case .pulseRandom: return "Pulse (Random)"
        case .pulseSingle: return "Pulse (Single)"
        case .pulseDual: return "Pulse (Dual)"
        }
    }

    public var usesPrimaryColor: Bool {
        switch self {
        case .staticColor, .reactive, .pulseSingle, .pulseDual:
            return true
        case .off, .spectrum, .wave, .pulseRandom:
            return false
        }
    }

    public var usesSecondaryColor: Bool {
        self == .pulseDual
    }

    public var usesWaveDirection: Bool {
        self == .wave
    }

    public var usesReactiveSpeed: Bool {
        self == .reactive
    }
}

public enum LightingWaveDirection: Int, CaseIterable, Identifiable, Codable, Sendable {
    case left = 1
    case right = 2

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

public struct LightingEffectPatch: Sendable, Hashable, Codable {
    public let kind: LightingEffectKind
    public let primary: RGBPatch
    public let secondary: RGBPatch
    public let waveDirection: LightingWaveDirection
    public let reactiveSpeed: Int

    public init(
        kind: LightingEffectKind,
        primary: RGBPatch = RGBPatch(r: 0, g: 255, b: 0),
        secondary: RGBPatch = RGBPatch(r: 0, g: 170, b: 255),
        waveDirection: LightingWaveDirection = .left,
        reactiveSpeed: Int = 2
    ) {
        self.kind = kind
        self.primary = primary
        self.secondary = secondary
        self.waveDirection = waveDirection
        self.reactiveSpeed = max(1, min(4, reactiveSpeed))
    }
}

public struct ButtonBindingPatch: Sendable, Hashable, Codable {
    public let slot: Int
    public let kind: ButtonBindingKind
    public let hidKey: Int?
    public let turboEnabled: Bool
    public let turboRate: Int?
    public let clutchDPI: Int?
    public let persistentProfile: Int
    public let writePersistentLayer: Bool
    public let writeDirectLayer: Bool

    public init(
        slot: Int,
        kind: ButtonBindingKind,
        hidKey: Int?,
        turboEnabled: Bool = false,
        turboRate: Int? = nil,
        clutchDPI: Int? = nil,
        persistentProfile: Int = 1,
        writePersistentLayer: Bool = true,
        writeDirectLayer: Bool = true
    ) {
        self.slot = slot
        self.kind = kind
        self.hidKey = hidKey
        self.turboEnabled = turboEnabled
        self.turboRate = turboRate
        self.clutchDPI = clutchDPI.map { max(100, min(30_000, $0)) }
        self.persistentProfile = max(1, min(5, persistentProfile))
        self.writePersistentLayer = writePersistentLayer
        self.writeDirectLayer = writeDirectLayer
    }
}

public enum USBButtonProfileActionKind: String, Codable, Hashable, Sendable {
    case projectToDirectLayer = "project_to_direct_layer"
    case duplicateToPersistentSlot = "duplicate_to_persistent_slot"
    case resetPersistentSlot = "reset_persistent_slot"
}

public struct USBButtonProfileActionPatch: Sendable, Hashable, Codable {
    public let kind: USBButtonProfileActionKind
    public let sourceProfile: Int?
    public let targetProfile: Int

    public init(
        kind: USBButtonProfileActionKind,
        sourceProfile: Int? = nil,
        targetProfile: Int
    ) {
        self.kind = kind
        self.sourceProfile = sourceProfile.map { max(1, min(5, $0)) }
        self.targetProfile = max(1, min(5, targetProfile))
    }
}

public struct DevicePatch: Sendable, Hashable, Codable {
    public var pollRate: Int? = nil
    public var sleepTimeout: Int? = nil
    public var deviceMode: DeviceMode? = nil
    public var lowBatteryThresholdRaw: Int? = nil
    public var scrollMode: Int? = nil
    public var scrollAcceleration: Bool? = nil
    public var scrollSmartReel: Bool? = nil
    public var dpiStages: [Int]? = nil
    public var dpiStagePairs: [DpiPair]? = nil
    public var activeStage: Int? = nil
    public var ledBrightness: Int? = nil
    public var ledRGB: RGBPatch? = nil
    public var lightingEffect: LightingEffectPatch? = nil
    public var usbLightingZoneLEDIDs: [UInt8]? = nil
    public var buttonBinding: ButtonBindingPatch? = nil
    public var usbButtonProfileAction: USBButtonProfileActionPatch? = nil

    public init(
        pollRate: Int? = nil,
        sleepTimeout: Int? = nil,
        deviceMode: DeviceMode? = nil,
        lowBatteryThresholdRaw: Int? = nil,
        scrollMode: Int? = nil,
        scrollAcceleration: Bool? = nil,
        scrollSmartReel: Bool? = nil,
        dpiStages: [Int]? = nil,
        dpiStagePairs: [DpiPair]? = nil,
        activeStage: Int? = nil,
        ledBrightness: Int? = nil,
        ledRGB: RGBPatch? = nil,
        lightingEffect: LightingEffectPatch? = nil,
        usbLightingZoneLEDIDs: [UInt8]? = nil,
        buttonBinding: ButtonBindingPatch? = nil,
        usbButtonProfileAction: USBButtonProfileActionPatch? = nil
    ) {
        self.pollRate = pollRate
        self.sleepTimeout = sleepTimeout
        self.deviceMode = deviceMode
        self.lowBatteryThresholdRaw = lowBatteryThresholdRaw
        self.scrollMode = scrollMode
        self.scrollAcceleration = scrollAcceleration
        self.scrollSmartReel = scrollSmartReel
        self.dpiStages = dpiStages
        self.dpiStagePairs = dpiStagePairs
        self.activeStage = activeStage
        self.ledBrightness = ledBrightness
        self.ledRGB = ledRGB
        self.lightingEffect = lightingEffect
        self.usbLightingZoneLEDIDs = usbLightingZoneLEDIDs
        self.buttonBinding = buttonBinding
        self.usbButtonProfileAction = usbButtonProfileAction
    }
}

public extension DevicePatch {
    func merged(with newer: DevicePatch) -> DevicePatch {
        DevicePatch(
            pollRate: newer.pollRate ?? pollRate,
            sleepTimeout: newer.sleepTimeout ?? sleepTimeout,
            deviceMode: newer.deviceMode ?? deviceMode,
            lowBatteryThresholdRaw: newer.lowBatteryThresholdRaw ?? lowBatteryThresholdRaw,
            scrollMode: newer.scrollMode ?? scrollMode,
            scrollAcceleration: newer.scrollAcceleration ?? scrollAcceleration,
            scrollSmartReel: newer.scrollSmartReel ?? scrollSmartReel,
            dpiStages: newer.dpiStages ?? dpiStages,
            dpiStagePairs: newer.dpiStagePairs ?? dpiStagePairs,
            activeStage: newer.activeStage ?? activeStage,
            ledBrightness: newer.ledBrightness ?? ledBrightness,
            ledRGB: newer.ledRGB ?? ledRGB,
            lightingEffect: newer.lightingEffect ?? lightingEffect,
            usbLightingZoneLEDIDs: newer.usbLightingZoneLEDIDs ?? usbLightingZoneLEDIDs,
            buttonBinding: newer.buttonBinding ?? buttonBinding,
            usbButtonProfileAction: newer.usbButtonProfileAction ?? usbButtonProfileAction
        )
    }
}

public extension DevicePatch {
    var resolvedDpiStagePairs: [DpiPair]? {
        if let dpiStagePairs {
            return dpiStagePairs
        }
        return dpiStages?.map { DpiPair(x: $0, y: $0) }
    }
}

public enum ButtonBindingKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case `default`
    case dpiCycle = "dpi_cycle"
    case dpiClutch = "dpi_clutch"
    case leftClick = "left_click"
    case rightClick = "right_click"
    case middleClick = "middle_click"
    case scrollUp = "scroll_up"
    case scrollDown = "scroll_down"
    case scrollLeft = "scroll_left"
    case scrollRight = "scroll_right"
    case mouseBack = "mouse_back"
    case mouseForward = "mouse_forward"
    case keyboardSimple = "keyboard_simple"
    case clearLayer = "clear_layer"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .default: return "Default"
        case .dpiCycle: return "DPI Cycle"
        case .dpiClutch: return "DPI Clutch"
        case .leftClick: return "Left Click"
        case .rightClick: return "Right Click"
        case .middleClick: return "Middle Click"
        case .scrollUp: return "Scroll Up"
        case .scrollDown: return "Scroll Down"
        case .scrollLeft: return "Scroll Left"
        case .scrollRight: return "Scroll Right"
        case .mouseBack: return "Mouse Back"
        case .mouseForward: return "Mouse Forward"
        case .keyboardSimple: return "Keyboard Key"
        case .clearLayer: return "Disabled"
        }
    }

    public var supportsTurbo: Bool {
        switch self {
        case .leftClick, .rightClick, .middleClick, .scrollUp, .scrollDown, .scrollLeft, .scrollRight, .mouseBack, .mouseForward, .keyboardSimple:
            return true
        case .default, .dpiCycle, .dpiClutch, .clearLayer:
            return false
        }
    }
}
