import Foundation
import Network

enum BackgroundServiceTransportError: LocalizedError {
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

final class BackgroundServiceResumeGate: @unchecked Sendable {
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

enum BackgroundServiceTransport {
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
