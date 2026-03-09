import Foundation

public enum DevicePersistenceKeys {
    public static func key(for device: MouseDevice) -> String {
        if let serial = device.serial?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !serial.isEmpty {
            return "serial:\(serial.lowercased())"
        }
        return String(
            format: "vp:%04x:%04x:%@",
            device.vendor_id,
            device.product_id,
            device.transport.rawValue
        )
    }

    public static func legacyKey(for device: MouseDevice) -> String {
        device.id
    }
}
