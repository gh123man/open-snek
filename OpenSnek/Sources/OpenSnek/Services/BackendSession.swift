import Foundation
import Network
import OpenSnekCore
import OpenSnekHardware

enum OpenSnekProcessRole: String, Sendable {
    case app
    case service

    static var current: OpenSnekProcessRole {
        ProcessInfo.processInfo.arguments.contains("--service-mode") ? .service : .app
    }

    var isService: Bool {
        self == .service
    }
}

protocol DeviceBackend: AnyObject, Sendable {
    var usesRemoteServiceTransport: Bool { get }
    func listDevices() async throws -> [MouseDevice]
    func readState(device: MouseDevice) async throws -> MouseState
    func readDpiStagesFast(device: MouseDevice) async throws -> DpiFastSnapshot?
    func shouldUseFastDPIPolling(device: MouseDevice) async -> Bool
    func stateUpdates() async -> AsyncStream<BackendStateUpdate>
    func apply(device: MouseDevice, patch: DevicePatch) async throws -> MouseState
    func readLightingColor(device: MouseDevice) async throws -> RGBPatch?
    func debugUSBReadButtonBinding(device: MouseDevice, slot: Int, profile: Int) async throws -> [UInt8]?
}

struct DpiFastSnapshot: Codable, Hashable, Sendable {
    let active: Int
    let values: [Int]
}

enum BackendStateUpdate: Sendable {
    case deviceList([MouseDevice], updatedAt: Date)
    case deviceState(deviceID: String, state: MouseState, updatedAt: Date)
    case snapshot(SharedServiceSnapshot)
}

private final class DistributedObserverToken: @unchecked Sendable {
    let observer: NSObjectProtocol

    init(observer: NSObjectProtocol) {
        self.observer = observer
    }
}

func mergedStateFromPassiveDpiEvent(
    previous: MouseState?,
    event: PassiveDPIEvent
) -> MouseState? {
    guard let previous, let stageValues = previous.dpi_stages.values, !stageValues.isEmpty else { return nil }

    let matchingIndices = stageValues.enumerated().compactMap { index, value in
        value == event.dpiX ? index : nil
    }
    let resolvedActiveStage = matchingIndices.count == 1 ? matchingIndices[0] : previous.dpi_stages.active_stage

    return MouseState(
        device: previous.device,
        connection: previous.connection,
        battery_percent: previous.battery_percent,
        charging: previous.charging,
        dpi: DpiPair(x: event.dpiX, y: event.dpiY),
        dpi_stages: DpiStages(active_stage: resolvedActiveStage, values: stageValues),
        poll_rate: previous.poll_rate,
        sleep_timeout: previous.sleep_timeout,
        device_mode: previous.device_mode,
        low_battery_threshold_raw: previous.low_battery_threshold_raw,
        scroll_mode: previous.scroll_mode,
        scroll_acceleration: previous.scroll_acceleration,
        scroll_smart_reel: previous.scroll_smart_reel,
        active_onboard_profile: previous.active_onboard_profile,
        onboard_profile_count: previous.onboard_profile_count,
        led_value: previous.led_value,
        capabilities: previous.capabilities
    )
}

private struct ApplyRequest: Codable, Sendable {
    let device: MouseDevice
    let patch: DevicePatch
}

private struct ButtonBindingReadRequest: Codable, Sendable {
    let device: MouseDevice
    let slot: Int
    let profile: Int
}

private enum BackendCodec {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

private enum BackgroundServiceMethod: String, Codable, Sendable {
    case ping
    case listDevices
    case readState
    case readDpiStagesFast
    case shouldUseFastDPIPolling
    case apply
    case readLightingColor
    case debugUSBReadButtonBinding
}

private struct BackgroundServiceRequestEnvelope: Codable, Sendable {
    let method: BackgroundServiceMethod
    let payload: Data?
}

private struct BackgroundServiceResponseEnvelope: Codable, Sendable {
    let payload: Data?
    let error: String?
}

private enum BackgroundServiceTransportError: LocalizedError {
    case connectionClosed
    case invalidLength
    case missingPayload
    case listenerUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            return "Background service connection closed unexpectedly"
        case .invalidLength:
            return "Background service returned an invalid message"
        case .missingPayload:
            return "Background service request was missing its payload"
        case .listenerUnavailable:
            return "Background service listener did not publish a port"
        }
    }
}

private final class BackgroundServiceResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return false }
        hasResumed = true
        return true
    }
}

private enum BackgroundServiceTransport {
    static func listenerParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        return parameters
    }

    static func clientParameters() -> NWParameters {
        .tcp
    }

    static func awaitReady(listener: NWListener) async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "io.opensnek.service.listener")
            let gate = BackgroundServiceResumeGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    guard let port = listener.port else {
                        continuation.resume(throwing: BackgroundServiceTransportError.listenerUnavailable)
                        return
                    }
                    continuation.resume(returning: port)
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard gate.claim() else { return }
                    continuation.resume(throwing: BackgroundServiceTransportError.connectionClosed)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    static func awaitReady(connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "io.opensnek.service.client")
            let gate = BackgroundServiceResumeGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard gate.claim() else { return }
                    continuation.resume(throwing: BackgroundServiceTransportError.connectionClosed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    static func sendFrame(_ payload: Data, over connection: NWConnection) async throws {
        var framed = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { header in
            framed.append(contentsOf: header)
        }
        framed.append(payload)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    static func receiveFrame(from connection: NWConnection) async throws -> Data {
        let header = try await receiveExactly(4, from: connection)
        let length = header.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }

        if length == 0 {
            return Data()
        }

        return try await receiveExactly(Int(length), from: connection)
    }

    private static func receiveExactly(_ count: Int, from connection: NWConnection) async throws -> Data {
        guard count >= 0 else {
            throw BackgroundServiceTransportError.invalidLength
        }

        var buffer = Data()
        while buffer.count < count {
            let chunk = try await receiveChunk(maximumLength: count - buffer.count, from: connection)
            buffer.append(chunk)
        }
        return buffer
    }

    private static func receiveChunk(maximumLength: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: BackgroundServiceTransportError.connectionClosed)
                } else {
                    continuation.resume(throwing: BackgroundServiceTransportError.invalidLength)
                }
            }
        }
    }
}

final actor LocalBridgeBackend: DeviceBackend {
    static let shared = LocalBridgeBackend()

    private let client = BridgeClient()
    private var cachedDevices: [MouseDevice] = []
    private var cachedDevicesAt: Date?
    private var cachedStateByDeviceID: [String: MouseState] = [:]
    private var cachedStateAtByDeviceID: [String: Date] = [:]
    private var cachedFastByDeviceID: [String: DpiFastSnapshot] = [:]
    private var cachedFastAtByDeviceID: [String: Date] = [:]
    private var stateUpdateContinuations: [UUID: AsyncStream<BackendStateUpdate>.Continuation] = [:]
    private var devicePresenceRefreshTask: Task<Void, Never>?

    nonisolated var usesRemoteServiceTransport: Bool { false }

    init() {
        Task { [weak self] in
            guard let self else { return }
            let stream = await self.client.passiveDpiEventStream()
            for await event in stream {
                await self.handlePassiveDpiEvent(event)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            let stream = await self.client.devicePresenceEventStream()
            for await event in stream {
                await self.handleDevicePresenceEvent(event)
            }
        }
    }

    func listDevices() async throws -> [MouseDevice] {
        if let cachedDevicesAt,
           Date().timeIntervalSince(cachedDevicesAt) < 1.0,
           !cachedDevices.isEmpty {
            return cachedDevices
        }
        let devices = try await client.listDevices()
        updateCachedDevices(devices, updatedAt: Date(), publishUpdate: false)
        publishSnapshotIfService()
        return devices
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        if let cachedAt = cachedStateAtByDeviceID[device.id],
           let cached = cachedStateByDeviceID[device.id],
           Date().timeIntervalSince(cachedAt) < 1.0 {
            return cached
        }
        let state = try await client.readState(device: device)
        cachedStateByDeviceID[device.id] = state
        cachedStateAtByDeviceID[device.id] = Date()
        publishSnapshotIfService()
        return state
    }

    func readDpiStagesFast(device: MouseDevice) async throws -> DpiFastSnapshot? {
        if let cachedAt = cachedFastAtByDeviceID[device.id],
           let cached = cachedFastByDeviceID[device.id],
           Date().timeIntervalSince(cachedAt) < 0.2 {
            return cached
        }
        guard let snapshot = try await client.readDpiStagesFast(device: device) else { return nil }
        let fast = DpiFastSnapshot(active: snapshot.active, values: snapshot.values)
        cachedFastByDeviceID[device.id] = fast
        cachedFastAtByDeviceID[device.id] = Date()
        updateCachedStateFromFastSnapshot(fast, for: device.id)
        publishSnapshotIfService()
        return fast
    }

    func shouldUseFastDPIPolling(device: MouseDevice) async -> Bool {
        await client.shouldUseFastDPIPolling(device: device)
    }

    func stateUpdates() async -> AsyncStream<BackendStateUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: BackendStateUpdate.self)
        stateUpdateContinuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removeStateUpdateContinuation(id: id)
            }
        }
        return stream
    }

    func apply(device: MouseDevice, patch: DevicePatch) async throws -> MouseState {
        let state = try await client.apply(device: device, patch: patch)
        let now = Date()
        cachedStateByDeviceID[device.id] = state
        cachedStateAtByDeviceID[device.id] = now
        if let values = state.dpi_stages.values,
           let active = state.dpi_stages.active_stage {
            let fast = DpiFastSnapshot(active: active, values: values)
            cachedFastByDeviceID[device.id] = fast
            cachedFastAtByDeviceID[device.id] = now
        }
        publishSnapshotIfService()
        return state
    }

    func readLightingColor(device: MouseDevice) async throws -> RGBPatch? {
        try await client.readLightingColor(device: device)
    }

    func debugUSBReadButtonBinding(device: MouseDevice, slot: Int, profile: Int) async throws -> [UInt8]? {
        try await client.debugUSBReadButtonBinding(device: device, slot: slot, profile: profile)
    }

    private func removeStateUpdateContinuation(id: UUID) {
        stateUpdateContinuations.removeValue(forKey: id)
    }

    private func handleDevicePresenceEvent(_ event: HIDDevicePresenceEvent) {
        invalidateCachedTelemetry(for: event.deviceID)
        devicePresenceRefreshTask?.cancel()
        devicePresenceRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.refreshCachedDevicesAfterPresenceChange(observedAt: event.observedAt)
        }
    }

    private func updateCachedStateFromFastSnapshot(_ snapshot: DpiFastSnapshot, for deviceID: String) {
        guard let previous = cachedStateByDeviceID[deviceID], !snapshot.values.isEmpty else { return }
        let active = max(0, min(snapshot.values.count - 1, snapshot.active))
        let currentDpiValue = snapshot.values[active]
        let updated = MouseState(
            device: previous.device,
            connection: previous.connection,
            battery_percent: previous.battery_percent,
            charging: previous.charging,
            dpi: DpiPair(x: currentDpiValue, y: currentDpiValue),
            dpi_stages: DpiStages(active_stage: active, values: snapshot.values),
            poll_rate: previous.poll_rate,
            sleep_timeout: previous.sleep_timeout,
            device_mode: previous.device_mode,
            low_battery_threshold_raw: previous.low_battery_threshold_raw,
            scroll_mode: previous.scroll_mode,
            scroll_acceleration: previous.scroll_acceleration,
            scroll_smart_reel: previous.scroll_smart_reel,
            active_onboard_profile: previous.active_onboard_profile,
            onboard_profile_count: previous.onboard_profile_count,
            led_value: previous.led_value,
            capabilities: previous.capabilities
        )
        cachedStateByDeviceID[deviceID] = updated
        cachedStateAtByDeviceID[deviceID] = Date()
    }

    private func handlePassiveDpiEvent(_ event: PassiveDPIEvent) {
        guard let updated = mergedStateFromPassiveDpiEvent(
            previous: cachedStateByDeviceID[event.deviceID],
            event: event
        ) else {
            return
        }

        cachedStateByDeviceID[event.deviceID] = updated
        cachedStateAtByDeviceID[event.deviceID] = event.observedAt
        let fastActive = updated.dpi_stages.active_stage ?? cachedFastByDeviceID[event.deviceID]?.active ?? 0
        if let values = updated.dpi_stages.values {
            cachedFastByDeviceID[event.deviceID] = DpiFastSnapshot(active: fastActive, values: values)
            cachedFastAtByDeviceID[event.deviceID] = event.observedAt
        }

        publishStateUpdate(.deviceState(deviceID: event.deviceID, state: updated, updatedAt: event.observedAt))
        publishSnapshotIfService()
    }

    private func publishStateUpdate(_ update: BackendStateUpdate) {
        for continuation in stateUpdateContinuations.values {
            continuation.yield(update)
        }
    }

    private func refreshCachedDevicesAfterPresenceChange(observedAt: Date) async {
        do {
            let devices = try await client.listDevices()
            updateCachedDevices(devices, updatedAt: observedAt, publishUpdate: true)
            publishSnapshotIfService()
        } catch {
            AppLog.warning(
                "Backend",
                "device presence refresh failed: \(error.localizedDescription)"
            )
        }
    }

    private func updateCachedDevices(
        _ devices: [MouseDevice],
        updatedAt: Date,
        publishUpdate: Bool
    ) {
        let previousIDs = Set(cachedDevices.map(\.id))
        let nextIDs = Set(devices.map(\.id))
        purgeCaches(forRemovedDeviceIDs: previousIDs.subtracting(nextIDs))
        cachedDevices = devices
        cachedDevicesAt = updatedAt
        if publishUpdate {
            publishStateUpdate(.deviceList(devices, updatedAt: updatedAt))
        }
    }

    private func invalidateCachedTelemetry(for deviceID: String) {
        cachedDevicesAt = nil
        cachedStateByDeviceID.removeValue(forKey: deviceID)
        cachedStateAtByDeviceID.removeValue(forKey: deviceID)
        cachedFastByDeviceID.removeValue(forKey: deviceID)
        cachedFastAtByDeviceID.removeValue(forKey: deviceID)
    }

    private func purgeCaches(forRemovedDeviceIDs removedDeviceIDs: Set<String>) {
        guard !removedDeviceIDs.isEmpty else { return }
        for deviceID in removedDeviceIDs {
            cachedStateByDeviceID.removeValue(forKey: deviceID)
            cachedStateAtByDeviceID.removeValue(forKey: deviceID)
            cachedFastByDeviceID.removeValue(forKey: deviceID)
            cachedFastAtByDeviceID.removeValue(forKey: deviceID)
        }
    }

    private func publishSnapshotIfService() {
        guard OpenSnekProcessRole.current.isService else { return }
        let liveIDs = Set(cachedDevices.map(\.id))
        CrossProcessStateSync.post(
            snapshot: SharedServiceSnapshot(
                devices: cachedDevices,
                stateByDeviceID: cachedStateByDeviceID.filter { liveIDs.contains($0.key) },
                lastUpdatedByDeviceID: cachedStateAtByDeviceID.filter { liveIDs.contains($0.key) }
            )
        )
    }
}

private actor BackgroundServiceRequestHandler {
    private let backend: any DeviceBackend

    init(backend: any DeviceBackend) {
        self.backend = backend
    }

    func handle(_ requestData: Data) async -> Data {
        let response: BackgroundServiceResponseEnvelope
        do {
            let request = try BackendCodec.decode(BackgroundServiceRequestEnvelope.self, from: requestData)
            response = try await makeResponse(for: request)
        } catch {
            response = BackgroundServiceResponseEnvelope(payload: nil, error: error.localizedDescription)
        }

        return (try? BackendCodec.encode(response)) ?? Data()
    }

    private func makeResponse(for request: BackgroundServiceRequestEnvelope) async throws -> BackgroundServiceResponseEnvelope {
        let payload: Data

        switch request.method {
        case .ping:
            payload = try BackendCodec.encode(true)
        case .listDevices:
            payload = try BackendCodec.encode(try await backend.listDevices())
        case .readState:
            let device = try decodePayload(MouseDevice.self, from: request.payload)
            payload = try BackendCodec.encode(try await backend.readState(device: device))
        case .readDpiStagesFast:
            let device = try decodePayload(MouseDevice.self, from: request.payload)
            payload = try BackendCodec.encode(try await backend.readDpiStagesFast(device: device))
        case .shouldUseFastDPIPolling:
            let device = try decodePayload(MouseDevice.self, from: request.payload)
            payload = try BackendCodec.encode(await backend.shouldUseFastDPIPolling(device: device))
        case .apply:
            let applyRequest = try decodePayload(ApplyRequest.self, from: request.payload)
            payload = try BackendCodec.encode(try await backend.apply(device: applyRequest.device, patch: applyRequest.patch))
        case .readLightingColor:
            let device = try decodePayload(MouseDevice.self, from: request.payload)
            payload = try BackendCodec.encode(try await backend.readLightingColor(device: device))
        case .debugUSBReadButtonBinding:
            let bindingRequest = try decodePayload(ButtonBindingReadRequest.self, from: request.payload)
            payload = try BackendCodec.encode(
                try await backend.debugUSBReadButtonBinding(
                    device: bindingRequest.device,
                    slot: bindingRequest.slot,
                    profile: bindingRequest.profile
                )
            )
        }

        return BackgroundServiceResponseEnvelope(payload: payload, error: nil)
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, from payload: Data?) throws -> T {
        guard let payload else {
            throw BackgroundServiceTransportError.missingPayload
        }
        return try BackendCodec.decode(type, from: payload)
    }
}

final actor IPCDeviceBackend: DeviceBackend {
    private let host: NWEndpoint.Host = .ipv4(.loopback)
    private let port: NWEndpoint.Port

    init(port: NWEndpoint.Port) {
        self.port = port
    }

    nonisolated var usesRemoteServiceTransport: Bool { true }

    func ping() async -> Bool {
        (try? await request(method: .ping, payload: nil, responseType: Bool.self)) ?? false
    }

    func listDevices() async throws -> [MouseDevice] {
        try await request(method: .listDevices, payload: nil, responseType: [MouseDevice].self)
    }

    func readState(device: MouseDevice) async throws -> MouseState {
        try await request(
            method: .readState,
            payload: try BackendCodec.encode(device),
            responseType: MouseState.self
        )
    }

    func readDpiStagesFast(device: MouseDevice) async throws -> DpiFastSnapshot? {
        try await request(
            method: .readDpiStagesFast,
            payload: try BackendCodec.encode(device),
            responseType: DpiFastSnapshot?.self
        )
    }

    func shouldUseFastDPIPolling(device: MouseDevice) async -> Bool {
        (try? await request(
            method: .shouldUseFastDPIPolling,
            payload: try BackendCodec.encode(device),
            responseType: Bool.self
        )) ?? false
    }

    func stateUpdates() async -> AsyncStream<BackendStateUpdate> {
        AsyncStream { continuation in
            let token = DistributedObserverToken(
                observer: CrossProcessStateSync.observeSnapshots { snapshot in
                    continuation.yield(.snapshot(snapshot))
                }
            )
            continuation.onTermination = { @Sendable _ in
                CrossProcessStateSync.removeObserver(token.observer)
            }
        }
    }

    func apply(device: MouseDevice, patch: DevicePatch) async throws -> MouseState {
        try await request(
            method: .apply,
            payload: try BackendCodec.encode(ApplyRequest(device: device, patch: patch)),
            responseType: MouseState.self
        )
    }

    func readLightingColor(device: MouseDevice) async throws -> RGBPatch? {
        try await request(
            method: .readLightingColor,
            payload: try BackendCodec.encode(device),
            responseType: RGBPatch?.self
        )
    }

    func debugUSBReadButtonBinding(device: MouseDevice, slot: Int, profile: Int) async throws -> [UInt8]? {
        try await request(
            method: .debugUSBReadButtonBinding,
            payload: try BackendCodec.encode(ButtonBindingReadRequest(device: device, slot: slot, profile: profile)),
            responseType: [UInt8]?.self
        )
    }

    private func request<T: Decodable & Sendable>(
        method: BackgroundServiceMethod,
        payload: Data?,
        responseType: T.Type
    ) async throws -> T {
        let connection = NWConnection(host: host, port: port, using: BackgroundServiceTransport.clientParameters())
        defer { connection.cancel() }

        try await BackgroundServiceTransport.awaitReady(connection: connection)

        let request = BackgroundServiceRequestEnvelope(method: method, payload: payload)
        try await BackgroundServiceTransport.sendFrame(try BackendCodec.encode(request), over: connection)

        let responseData = try await BackgroundServiceTransport.receiveFrame(from: connection)
        let response = try BackendCodec.decode(BackgroundServiceResponseEnvelope.self, from: responseData)
        if let error = response.error {
            throw NSError(domain: "OpenSnek.Service", code: 2, userInfo: [
                NSLocalizedDescriptionKey: error
            ])
        }
        guard let payload = response.payload else {
            throw NSError(domain: "OpenSnek.Service", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Background service returned no payload"
            ])
        }
        return try BackendCodec.decode(responseType, from: payload)
    }
}

final class BackgroundServiceHost: @unchecked Sendable {
    private let defaults: UserDefaults
    private let pid = ProcessInfo.processInfo.processIdentifier
    private let listener: NWListener
    private let handler: BackgroundServiceRequestHandler
    private let queue = DispatchQueue(label: "io.opensnek.service.host")

    init(backend: any DeviceBackend, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        self.listener = try NWListener(using: BackgroundServiceTransport.listenerParameters())
        self.handler = BackgroundServiceRequestHandler(backend: backend)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let port = try await BackgroundServiceTransport.awaitReady(listener: listener)
        defaults.removeObject(forKey: BackgroundServiceCoordinator.endpointDefaultsKey)
        defaults.set(Int(port.rawValue), forKey: BackgroundServiceCoordinator.portDefaultsKey)
        defaults.set(pid, forKey: BackgroundServiceCoordinator.pidDefaultsKey)
        defaults.synchronize()
        AppLog.info("Service", "background service published pid=\(pid) port=\(port.rawValue)")
    }

    func stop() {
        if defaults.integer(forKey: BackgroundServiceCoordinator.pidDefaultsKey) == pid {
            defaults.removeObject(forKey: BackgroundServiceCoordinator.endpointDefaultsKey)
            defaults.removeObject(forKey: BackgroundServiceCoordinator.portDefaultsKey)
            defaults.removeObject(forKey: BackgroundServiceCoordinator.pidDefaultsKey)
            defaults.synchronize()
        }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.handle(connection)
            case .failed(let error):
                AppLog.warning("Service", "background service connection failed: \(error.localizedDescription)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func handle(_ connection: NWConnection) {
        let handler = self.handler
        Task {
            do {
                let requestData = try await BackgroundServiceTransport.receiveFrame(from: connection)
                let responseData = await handler.handle(requestData)
                try await BackgroundServiceTransport.sendFrame(responseData, over: connection)
            } catch {
                AppLog.warning("Service", "background service request failed: \(error.localizedDescription)")
            }
            connection.cancel()
        }
    }
}
