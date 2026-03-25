import Foundation
import OSLog

enum AppLogLevel: String, CaseIterable, Identifiable, Comparable {
    case debug
    case info
    case warning
    case error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .debug:
            "Debug"
        case .info:
            "Info"
        case .warning:
            "Warning"
        case .error:
            "Error"
        }
    }

    var shortLabel: String {
        switch self {
        case .debug:
            "DEBUG"
        case .info:
            "INFO"
        case .warning:
            "WARN"
        case .error:
            "ERROR"
        }
    }

    private var rank: Int {
        switch self {
        case .debug:
            0
        case .info:
            1
        case .warning:
            2
        case .error:
            3
        }
    }

    static func < (lhs: AppLogLevel, rhs: AppLogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

final class AppLog: @unchecked Sendable {
    static let shared = AppLog()
    static let levelDefaultsKey = "openSnek.logLevel"
    static let defaultLevel: AppLogLevel = .warning
    static let mainLogFileName = "open-snek.log"

    static var logsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OpenSnek", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "open.snek.log", qos: .utility)
    private let logger = Logger(subsystem: "open.snek.mac", category: "runtime")
    private let fileURL: URL
    private let maxBytes: Int64 = 2_000_000

    private init() {
        let logsDir = Self.logsDirectoryURL
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        fileURL = logsDir.appendingPathComponent(Self.mainLogFileName)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    static var currentLevel: AppLogLevel {
        get {
            guard let raw = UserDefaults.standard.string(forKey: levelDefaultsKey),
                  let level = AppLogLevel(rawValue: raw) else {
                return defaultLevel
            }
            return level
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: levelDefaultsKey)
        }
    }

    static func updateLevel(_ level: AppLogLevel, resetLog: Bool = true) {
        currentLevel = level
        if resetLog {
            shared.resetFileSynchronously()
        }
        shared.write(level: .warning, source: "App", message: "log level changed to \(level.shortLabel)")
    }

    static func clear() {
        shared.resetFileSynchronously()
    }

    static func clearAllFiles(
        fileManager: FileManager = .default,
        logsDirectoryURL: URL = logsDirectoryURL
    ) throws {
        if fileManager.fileExists(atPath: logsDirectoryURL.path) {
            let contents = try fileManager.contentsOfDirectory(
                at: logsDirectoryURL,
                includingPropertiesForKeys: nil
            )
            for entry in contents {
                try fileManager.removeItem(at: entry)
            }
        } else {
            try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
        }

        _ = fileManager.createFile(
            atPath: logsDirectoryURL.appendingPathComponent(mainLogFileName).path,
            contents: nil
        )
    }

    static func event(_ source: String, _ message: String) {
        shared.write(level: .info, source: source, message: message)
    }

    static func info(_ source: String, _ message: String) {
        shared.write(level: .info, source: source, message: message)
    }

    static func warning(_ source: String, _ message: String) {
        shared.write(level: .warning, source: source, message: message)
    }

    static func error(_ source: String, _ message: String) {
        shared.write(level: .error, source: source, message: message)
    }

    static func debug(_ source: String, _ message: String) {
        shared.write(level: .debug, source: source, message: message)
    }

    static var path: String { shared.fileURL.path }

    private func write(level: AppLogLevel, source: String, message: String) {
        guard level >= Self.currentLevel else { return }
        let line = "\(timestamp()) [\(level.shortLabel)] [\(source)] \(message)\n"
        logger.log("\(line, privacy: .public)")

        queue.async {
            self.rotateIfNeeded()
            guard let data = line.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: self.fileURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Ignore logging failures to avoid impacting UX paths.
            }
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let bytes = attrs[.size] as? NSNumber,
              bytes.int64Value >= maxBytes else { return }
        resetFileLocked()
    }

    private func resetFileSynchronously() {
        queue.sync {
            resetFileLocked()
        }
    }

    private func resetFileLocked() {
        try? FileManager.default.removeItem(at: fileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }

    private func timestamp() -> String {
        String(format: "%.3f", Date().timeIntervalSince1970)
    }
}
