import Foundation
import OpenSnekCore

struct SharedServiceSnapshot: Codable, Sendable {
    let devices: [MouseDevice]
    let stateByDeviceID: [String: MouseState]
    let lastUpdatedByDeviceID: [String: Date]
}

struct CrossProcessClientPresence: Sendable {
    let sourceProcessID: Int32
    let selectedDeviceID: String?
}

enum CrossProcessStateSync {
    static let snapshotNotificationName = Notification.Name("io.opensnek.OpenSnek.serviceSnapshot")
    static let clientPresenceNotificationName = Notification.Name("io.opensnek.OpenSnek.clientPresence")

    private static let payloadKey = "payload"
    private static let sourceProcessIDKey = "sourceProcessID"
    private static let selectedDeviceIDKey = "selectedDeviceID"

    static func post(snapshot: SharedServiceSnapshot) {
        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            snapshotNotificationName,
            object: nil,
            userInfo: [
                payloadKey: encoded.base64EncodedString(),
                sourceProcessIDKey: Int(ProcessInfo.processInfo.processIdentifier),
            ],
            deliverImmediately: true
        )
    }

    static func observeSnapshots(
        using handler: @escaping @Sendable (SharedServiceSnapshot) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: snapshotNotificationName,
            object: nil,
            queue: nil
        ) { notification in
            guard let snapshot = snapshot(from: notification) else { return }
            handler(snapshot)
        }
    }

    static func postClientPresence(selectedDeviceID: String? = nil) {
        var userInfo: [String: Any] = [sourceProcessIDKey: Int(ProcessInfo.processInfo.processIdentifier)]
        if let selectedDeviceID, !selectedDeviceID.isEmpty {
            userInfo[selectedDeviceIDKey] = selectedDeviceID
        }
        DistributedNotificationCenter.default().postNotificationName(
            clientPresenceNotificationName,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    static func observeClientPresence(
        using handler: @escaping @Sendable (CrossProcessClientPresence) -> Void
    ) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: clientPresenceNotificationName,
            object: nil,
            queue: nil
        ) { notification in
            guard let presence = clientPresence(from: notification) else { return }
            guard presence.sourceProcessID != ProcessInfo.processInfo.processIdentifier else { return }
            handler(presence)
        }
    }

    static func removeObserver(_ observer: NSObjectProtocol) {
        DistributedNotificationCenter.default().removeObserver(observer)
    }

    private static func snapshot(from notification: Notification) -> SharedServiceSnapshot? {
        guard let userInfo = notification.userInfo,
              let payload = userInfo[payloadKey] as? String,
              let payloadData = Data(base64Encoded: payload) else {
            return nil
        }
        return try? JSONDecoder().decode(SharedServiceSnapshot.self, from: payloadData)
    }

    private static func clientPresence(from notification: Notification) -> CrossProcessClientPresence? {
        guard let userInfo = notification.userInfo else { return nil }

        if let intValue = userInfo[sourceProcessIDKey] as? Int {
            return CrossProcessClientPresence(
                sourceProcessID: Int32(intValue),
                selectedDeviceID: userInfo[selectedDeviceIDKey] as? String
            )
        }
        if let numberValue = userInfo[sourceProcessIDKey] as? NSNumber {
            return CrossProcessClientPresence(
                sourceProcessID: numberValue.int32Value,
                selectedDeviceID: userInfo[selectedDeviceIDKey] as? String
            )
        }
        return nil
    }
}
