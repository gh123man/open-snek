import Foundation

final class BroadcastStream<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    func makeStream() -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)

        lock.lock()
        continuations[id] = continuation
        lock.unlock()

        continuation.onTermination = { @Sendable [weak self] _ in
            self?.remove(id: id)
        }

        return stream
    }

    func yield(_ value: Element) {
        lock.lock()
        let activeContinuations = Array(continuations.values)
        lock.unlock()

        for continuation in activeContinuations {
            continuation.yield(value)
        }
    }

    private func remove(id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
