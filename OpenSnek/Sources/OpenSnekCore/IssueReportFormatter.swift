import Foundation

public struct IssueReportDeviceEntry: Hashable, Sendable {
    public let title: String
    public let summary: String
    public let diagnostics: String

    public init(title: String, summary: String, diagnostics: String) {
        self.title = title
        self.summary = summary
        self.diagnostics = diagnostics
    }
}

public struct IssueReportFormatter {
    public static func format(
        appVersion: String,
        build: String,
        logLevel: String,
        logPath: String,
        selectedDevice: String?,
        warning: String?,
        error: String?,
        generatedAt: Date = Date(),
        devices: [IssueReportDeviceEntry]
    ) -> String {
        var lines: [String] = []
        lines.append("## Open Snek Diagnostics")
        lines.append("")
        lines.append("- Generated: \(iso8601(generatedAt))")
        lines.append("- App version: \(appVersion)")
        lines.append("- Build: \(build)")
        lines.append("- Log level: \(logLevel)")
        lines.append("- Log file: `\(logPath)`")
        lines.append("- Selected device: \(selectedDevice ?? "None")")
        lines.append("- Current warning: \(warning ?? "None")")
        lines.append("- Current error: \(error ?? "None")")
        lines.append("")

        lines.append("### Connected Devices")
        if devices.isEmpty {
            lines.append("_No devices were connected when this payload was generated._")
        } else {
            lines.append(contentsOf: devices.map { "- \($0.summary)" })
        }
        lines.append("")

        for entry in devices {
            lines.append("### Device Dump: \(entry.title)")
            lines.append("")
            lines.append("```text")
            lines.append(entry.diagnostics)
            lines.append("```")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
