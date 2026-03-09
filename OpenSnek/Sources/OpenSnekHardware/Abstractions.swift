import Foundation
import OpenSnekCore

public protocol DeviceDriver: Sendable {
    func readState(device: MouseDevice) async throws -> MouseState
    func apply(device: MouseDevice, patch: DevicePatch) async throws -> MouseState
    func readFastDpi(device: MouseDevice) async throws -> (active: Int, values: [Int])?
    func readLightingColor(device: MouseDevice) async throws -> RGBPatch?
}

public protocol DeviceRepository: Sendable {
    func listDevices() async throws -> [MouseDevice]
    func readState(device: MouseDevice) async throws -> MouseState
    func apply(device: MouseDevice, patch: DevicePatch) async throws -> MouseState
    func readDpiStagesFast(device: MouseDevice) async throws -> (active: Int, values: [Int])?
    func readLightingColor(device: MouseDevice) async throws -> RGBPatch?
}

public enum BridgeError: LocalizedError, Sendable {
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let msg): return msg
        }
    }
}
