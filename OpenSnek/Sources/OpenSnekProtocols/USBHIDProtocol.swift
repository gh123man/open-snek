import Foundation

public enum USBHIDProtocol {
    public static func createReport(txn: UInt8, classID: UInt8, cmdID: UInt8, size: UInt8, args: [UInt8]) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 90)
        report[0] = 0x00
        report[1] = txn
        report[5] = size
        report[6] = classID
        report[7] = cmdID
        for (idx, value) in args.prefix(80).enumerated() {
            report[8 + idx] = value
        }
        report[88] = crc(for: report)
        return report
    }

    public static func crc(for report: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        guard report.count >= 88 else { return crc }
        for i in 2..<88 {
            crc ^= report[i]
        }
        return crc
    }

    public static func normalizeResponseBytes(_ raw: [UInt8]) -> [UInt8]? {
        if raw.count == 91 {
            return Array(raw.dropFirst())
        }
        if raw.count == 90 {
            return raw
        }
        if raw.count > 90 {
            return Array(raw.suffix(90))
        }
        return nil
    }

    public static func isValidResponse(_ response: [UInt8], classID: UInt8, cmdID: UInt8) -> Bool {
        guard response.count >= 90 else { return false }
        guard response[6] == classID else { return false }
        guard (response[7] & 0x7F) == (cmdID & 0x7F) else { return false }
        return response[88] == crc(for: response)
    }
}
