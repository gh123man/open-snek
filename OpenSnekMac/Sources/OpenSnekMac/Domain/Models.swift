import Foundation

struct MouseDevice: Codable, Identifiable, Hashable {
    let id: String
    let vendor_id: Int
    let product_id: Int
    let product_name: String
    let transport: String
    let path_b64: String
    let serial: String?
    let firmware: String?

    var connectionLabel: String {
        transport == "bluetooth" ? "Bluetooth" : "USB"
    }
}

struct DpiPair: Codable, Hashable {
    let x: Int
    let y: Int
}

struct DpiStages: Codable, Hashable {
    let active_stage: Int?
    let values: [Int]?
}

struct DeviceMode: Codable, Hashable {
    let mode: Int
    let param: Int
}

struct Capabilities: Codable, Hashable {
    let dpi_stages: Bool
    let poll_rate: Bool
    let power_management: Bool
    let button_remap: Bool
    let lighting: Bool

    init(dpi_stages: Bool, poll_rate: Bool, power_management: Bool = false, button_remap: Bool, lighting: Bool) {
        self.dpi_stages = dpi_stages
        self.poll_rate = poll_rate
        self.power_management = power_management
        self.button_remap = button_remap
        self.lighting = lighting
    }
}

struct MouseState: Codable, Hashable {
    let device: DeviceSummary
    let connection: String
    let battery_percent: Int?
    let charging: Bool?
    let dpi: DpiPair?
    let dpi_stages: DpiStages
    let poll_rate: Int?
    let sleep_timeout: Int?
    let device_mode: DeviceMode?
    let led_value: Int?
    let capabilities: Capabilities

    init(
        device: DeviceSummary,
        connection: String,
        battery_percent: Int?,
        charging: Bool?,
        dpi: DpiPair?,
        dpi_stages: DpiStages,
        poll_rate: Int?,
        sleep_timeout: Int? = nil,
        device_mode: DeviceMode?,
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
        self.led_value = led_value
        self.capabilities = capabilities
    }
}

extension MouseState {
    func merged(with previous: MouseState?) -> MouseState {
        guard let previous else { return self }
        return MouseState(
            device: device.merged(with: previous.device),
            connection: connection,
            battery_percent: battery_percent ?? previous.battery_percent,
            charging: charging ?? previous.charging,
            dpi: dpi ?? previous.dpi,
            dpi_stages: DpiStages(
                active_stage: dpi_stages.active_stage ?? previous.dpi_stages.active_stage,
                values: dpi_stages.values ?? previous.dpi_stages.values
            ),
            poll_rate: poll_rate ?? previous.poll_rate,
            sleep_timeout: sleep_timeout ?? previous.sleep_timeout,
            device_mode: device_mode ?? previous.device_mode,
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

struct DeviceSummary: Codable, Hashable {
    let id: String?
    let product_name: String?
    let serial: String?
    let transport: String?
    let firmware: String?
}

extension DeviceSummary {
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

struct BridgeEnvelope: Codable {
    let ok: Bool
    let error: String?
    let devices: [MouseDevice]?
    let state: MouseState?
    let before: MouseState?
    let after: MouseState?
}

struct RGBPatch: Sendable {
    let r: Int
    let g: Int
    let b: Int
}

struct ButtonBindingPatch: Sendable {
    let slot: Int
    let kind: ButtonBindingKind
    let hidKey: Int?
}

struct DevicePatch: Sendable {
    var pollRate: Int? = nil
    var sleepTimeout: Int? = nil
    var dpiStages: [Int]? = nil
    var activeStage: Int? = nil
    var ledBrightness: Int? = nil
    var ledRGB: RGBPatch? = nil
    var buttonBinding: ButtonBindingPatch? = nil
}

extension DevicePatch {
    func merged(with newer: DevicePatch) -> DevicePatch {
        DevicePatch(
            pollRate: newer.pollRate ?? pollRate,
            sleepTimeout: newer.sleepTimeout ?? sleepTimeout,
            dpiStages: newer.dpiStages ?? dpiStages,
            activeStage: newer.activeStage ?? activeStage,
            ledBrightness: newer.ledBrightness ?? ledBrightness,
            ledRGB: newer.ledRGB ?? ledRGB,
            buttonBinding: newer.buttonBinding ?? buttonBinding
        )
    }
}

enum ButtonBindingKind: String, CaseIterable, Identifiable {
    case `default`
    case leftClick = "left_click"
    case rightClick = "right_click"
    case middleClick = "middle_click"
    case scrollUp = "scroll_up"
    case scrollDown = "scroll_down"
    case mouseBack = "mouse_back"
    case mouseForward = "mouse_forward"
    case keyboardSimple = "keyboard_simple"
    case clearLayer = "clear_layer"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: return "Default"
        case .leftClick: return "Left Click"
        case .rightClick: return "Right Click"
        case .middleClick: return "Middle Click"
        case .scrollUp: return "Scroll Up"
        case .scrollDown: return "Scroll Down"
        case .mouseBack: return "Mouse Back"
        case .mouseForward: return "Mouse Forward"
        case .keyboardSimple: return "Keyboard Key"
        case .clearLayer: return "Disabled"
        }
    }
}
