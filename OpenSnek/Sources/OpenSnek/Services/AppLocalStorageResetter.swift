import Foundation

@MainActor
struct AppLocalStorageResetter {
    private let backgroundServiceCoordinator: BackgroundServiceCoordinator
    private let fileManager: FileManager
    private let logsDirectoryURL: URL

    init(
        backgroundServiceCoordinator: BackgroundServiceCoordinator,
        fileManager: FileManager = .default,
        logsDirectoryURL: URL = AppLog.logsDirectoryURL
    ) {
        self.backgroundServiceCoordinator = backgroundServiceCoordinator
        self.fileManager = fileManager
        self.logsDirectoryURL = logsDirectoryURL
    }

    func reset() throws {
        try backgroundServiceCoordinator.resetPersistentState()
        try AppLog.clearAllFiles(
            fileManager: fileManager,
            logsDirectoryURL: logsDirectoryURL
        )
    }
}
