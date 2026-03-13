import Foundation

public enum BluetoothNameMatcher {
    public static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        let withoutRazerPrefix: String
        if lowered.hasPrefix("razer ") {
            withoutRazerPrefix = String(trimmed.dropFirst(6))
        } else {
            withoutRazerPrefix = trimmed
        }

        let pieces = withoutRazerPrefix
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { token -> String in
                switch token {
                case "bsk":
                    return "basilisk"
                default:
                    return String(token)
                }
            }
        let normalized = pieces.joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    public static func looselyMatches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalized(lhs), let rhs = normalized(rhs) else { return false }
        return lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs)
    }
}
