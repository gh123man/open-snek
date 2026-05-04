import Foundation
import OpenSnekCore

enum ApplyReadbackPolicy: String, Codable, Sendable {
    case immediateStateReadback
    case skipStateReadback
}

struct ApplyOptions: Codable, Sendable {
    let readbackPolicy: ApplyReadbackPolicy

    init(readbackPolicy: ApplyReadbackPolicy = .immediateStateReadback) {
        self.readbackPolicy = readbackPolicy
    }
}

protocol ApplyOptionsSupportingBackend: DeviceBackend {
    func apply(device: MouseDevice, patch: DevicePatch, options: ApplyOptions) async throws -> MouseState
}

struct ApplyRequest: Codable, Sendable {
    let device: MouseDevice
    let patch: DevicePatch
    let options: ApplyOptions
}

struct ButtonBindingReadRequest: Codable, Sendable {
    let device: MouseDevice
    let slot: Int
    let profile: Int
}

struct StreamSubscriptionRequest: Codable, Sendable {
    let sourceProcessID: Int32
    let selectedDeviceID: String?
}

enum BackgroundServiceStreamClientEvent: String, Codable, Sendable {
    case clientPresence
}

struct BackgroundServiceStreamClientEnvelope: Codable, Sendable {
    let event: BackgroundServiceStreamClientEvent
    let payload: Data?
}

enum BackgroundServiceStreamServerEvent: String, Codable, Sendable {
    case stateUpdate
    case openSettingsRequested
}

struct BackgroundServiceStreamServerEnvelope: Codable, Sendable {
    let event: BackgroundServiceStreamServerEvent
    let payload: Data?
}

enum BackendCodec {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

enum BackgroundServiceMethod: String, Codable, Sendable {
    case ping
    case listDevices
    case readState
    case readDpiStagesFast
    case shouldUseFastDPIPolling
    case dpiUpdateTransportStatus
    case hidAccessStatus
    case apply
    case readLightingColor
    case debugUSBReadButtonBinding
    case subscribeStateUpdates
}

struct BackgroundServiceRequestEnvelope: Codable, Sendable {
    let method: BackgroundServiceMethod
    let payload: Data?
}

struct BackgroundServiceResponseEnvelope: Codable, Sendable {
    let payload: Data?
    let error: String?
}
