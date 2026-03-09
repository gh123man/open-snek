import Foundation
import OSLog

final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "open.snek.log", qos: .utility)
    private let logger = Logger(subsystem: "open.snek.mac", category: "runtime")
    private let fileURL: URL
    private let maxBytes: Int64 = 2_000_000

    private init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OpenSnek", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        fileURL = logsDir.appendingPathComponent("open-snek.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    static func event(_ source: String, _ message: String) {
        shared.write(level: "INFO", source: source, message: message)
    }

    static func error(_ source: String, _ message: String) {
        shared.write(level: "ERROR", source: source, message: message)
    }

    static func debug(_ source: String, _ message: String) {
        shared.write(level: "DEBUG", source: source, message: message)
    }

    static var path: String { shared.fileURL.path }

    private func write(level: String, source: String, message: String) {
        let line = "\(timestamp()) [\(level)] [\(source)] \(message)\n"
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
        try? FileManager.default.removeItem(at: fileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }

    private func timestamp() -> String {
        String(format: "%.3f", Date().timeIntervalSince1970)
    }
}
