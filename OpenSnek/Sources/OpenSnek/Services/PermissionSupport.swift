import AppKit
import Foundation

struct PermissionResetResult: Equatable, Sendable {
    let bundleIdentifier: String
    let hostLabel: String
    let command: String
}

enum PermissionSupportError: LocalizedError {
    case resetFailed(String)

    var errorDescription: String? {
        switch self {
        case .resetFailed(let detail):
            return detail
        }
    }
}

enum PermissionSupport {
    static let defaultBundleIdentifier = "io.opensnek.OpenSnek"

    static func resolvedBundleIdentifier(_ bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultBundleIdentifier : trimmed
    }

    static func currentHostLabel(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        let processName = ProcessInfo.processInfo.processName
        return "\(processName) (\(resolvedBundleIdentifier(bundleIdentifier)))"
    }

    static func permissionResetCommand(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        "tccutil reset All \(resolvedBundleIdentifier(bundleIdentifier))"
    }

    static func resetAllPermissions(bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws -> PermissionResetResult {
        let resolvedBundleIdentifier = resolvedBundleIdentifier(bundleIdentifier)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "All", resolvedBundleIdentifier]

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = outputPipe

        try task.run()
        task.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard task.terminationStatus == 0 else {
            let message = output.isEmpty
                ? "Permission reset failed with exit status \(task.terminationStatus)."
                : output
            throw PermissionSupportError.resetFailed(message)
        }

        return PermissionResetResult(
            bundleIdentifier: resolvedBundleIdentifier,
            hostLabel: currentHostLabel(bundleIdentifier: resolvedBundleIdentifier),
            command: permissionResetCommand(bundleIdentifier: resolvedBundleIdentifier)
        )
    }

    static func openInputMonitoringSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_InputMonitoring",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.preference.security",
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
