import Foundation
import OpenSnekCore

public final class ApplyCoordinator: @unchecked Sendable {
    private var pendingPatch: DevicePatch?
    public private(set) var stateRevision: UInt64 = 0

    public init() {}

    @discardableResult
    public func enqueue(_ patch: DevicePatch) -> Bool {
        if let pendingPatch {
            self.pendingPatch = pendingPatch.merged(with: patch)
        } else {
            pendingPatch = patch
        }
        stateRevision &+= 1
        return true
    }

    public func dequeue() -> DevicePatch? {
        let patch = pendingPatch
        pendingPatch = nil
        return patch
    }

    public var hasPending: Bool {
        pendingPatch != nil
    }

    public func clearPending() {
        pendingPatch = nil
        stateRevision &+= 1
    }

    public func bumpRevision() {
        stateRevision &+= 1
    }
}
