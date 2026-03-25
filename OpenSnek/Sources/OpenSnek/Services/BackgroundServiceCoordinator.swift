import AppKit
import Darwin
import Foundation
import Network

@MainActor
final class BackgroundServiceCoordinator {
    static let shared = BackgroundServiceCoordinator()

    nonisolated static let backgroundServiceEnabledDefaultsKey = "backgroundServiceEnabled"
    nonisolated static let launchAtStartupDefaultsKey = "launchServiceAtStartup"
    nonisolated static let endpointDefaultsKey = "backgroundServiceEndpoint"
    nonisolated static let portDefaultsKey = "backgroundServicePort"
    nonisolated static let pidDefaultsKey = "backgroundServicePID"
    struct RunningAppSnapshot: Equatable {
        let processIdentifier: pid_t
        let activationPolicy: NSApplication.ActivationPolicy
        let isActive: Bool
        let isTerminated: Bool
    }

    private let defaults: UserDefaults
    private let defaultsDomainName: String?
    private let fileManager: FileManager
    private let launchAgentsDirectoryURL: URL?
    private var serviceHost: BackgroundServiceHost?

    init(
        defaults: UserDefaults = .standard,
        defaultsDomainName: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default,
        launchAgentsDirectoryURL: URL? = nil
    ) {
        self.defaults = defaults
        self.defaultsDomainName = defaultsDomainName
        self.fileManager = fileManager
        self.launchAgentsDirectoryURL = launchAgentsDirectoryURL
        self.defaults.register(defaults: [
            Self.backgroundServiceEnabledDefaultsKey: true,
            Self.launchAtStartupDefaultsKey: false,
        ])
    }

    var backgroundServiceEnabled: Bool {
        defaults.bool(forKey: Self.backgroundServiceEnabledDefaultsKey)
    }

    var launchAtStartupEnabled: Bool {
        defaults.bool(forKey: Self.launchAtStartupDefaultsKey)
    }

    var isCurrentProcessService: Bool {
        OpenSnekProcessRole.current.isService
    }

    var serviceProcessIdentifier: Int32? {
        let pid = defaults.integer(forKey: Self.pidDefaultsKey)
        guard pid > 0 else { return nil }
        return Int32(pid)
    }

    func registerServiceHostIfNeeded(
        backend: LocalBridgeBackend,
        remoteClientPresenceHandler: @escaping @Sendable (CrossProcessClientPresence) async -> Void,
        remoteClientDisconnectHandler: @escaping @Sendable (Int32) async -> Void
    ) async throws {
        guard isCurrentProcessService else { return }
        guard serviceHost == nil else { return }
        let host = try BackgroundServiceHost(
            backend: backend,
            defaults: defaults,
            remoteClientPresenceHandler: remoteClientPresenceHandler,
            remoteClientDisconnectHandler: remoteClientDisconnectHandler
        )
        try await host.start()
        serviceHost = host
    }

    func stopCurrentServiceHostIfNeeded() {
        serviceHost?.stop()
        serviceHost = nil
    }

    func requestOpenSettingsForConnectedClients() async -> Bool {
        guard let serviceHost else { return false }
        return await serviceHost.requestOpenSettingsForConnectedClients()
    }

    func setBackgroundServiceEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.backgroundServiceEnabledDefaultsKey)
    }

    func setLaunchAtStartupEnabled(_ enabled: Bool) throws {
        defaults.set(enabled, forKey: Self.launchAtStartupDefaultsKey)
        if enabled {
            try installLaunchAgent()
        } else {
            try removeLaunchAgent()
        }
    }

    func synchronizeLaunchAgentIfNeeded() throws {
        guard launchAtStartupEnabled else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        try synchronizeLaunchAgentIfNeeded(
            executablePath: executableURL.path,
            workingDirectoryPath: Bundle.main.bundleURL.deletingLastPathComponent().path
        )
    }

    func synchronizeLaunchAgentIfNeeded(
        executablePath: String,
        workingDirectoryPath: String
    ) throws {
        guard launchAtStartupEnabled else { return }

        let expectedPlist = Self.launchAgentPropertyList(
            executablePath: executablePath,
            workingDirectoryPath: workingDirectoryPath
        )
        if let currentPlist = currentLaunchAgentPropertyList(),
           NSDictionary(dictionary: currentPlist).isEqual(to: expectedPlist) {
            return
        }

        try installLaunchAgent(
            executablePath: executablePath,
            workingDirectoryPath: workingDirectoryPath
        )
    }

    func makeBackendForCurrentMode() async throws -> any DeviceBackend {
        if isCurrentProcessService {
            AppLog.info("Service", "using local bridge backend in service process")
            return LocalBridgeBackend.shared
        }
        if let backend = try await connectToRunningService() {
            AppLog.info("Service", "using background service backend from running service")
            return backend
        }
        guard backgroundServiceEnabled else {
            AppLog.info("Service", "using local bridge backend because background service is disabled")
            return LocalBridgeBackend.shared
        }
        AppLog.info("Service", "launching background service backend")
        return try await connectOrLaunchService()
    }

    func connectOrLaunchService() async throws -> any DeviceBackend {
        if let backend = try await connectToRunningService() {
            return backend
        }
        try launchServiceProcess()
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if let backend = try await connectToRunningService() {
                return backend
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        throw NSError(domain: "OpenSnek.Service", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Background service did not start in time"
        ])
    }

    func connectToRunningService() async throws -> IPCDeviceBackend? {
        guard isServiceProcessAlive else {
            defaults.removeObject(forKey: Self.endpointDefaultsKey)
            defaults.removeObject(forKey: Self.portDefaultsKey)
            defaults.removeObject(forKey: Self.pidDefaultsKey)
            return nil
        }
        let portValue = defaults.integer(forKey: Self.portDefaultsKey)
        guard let port = NWEndpoint.Port(rawValue: UInt16(portValue)), portValue > 0 else {
            return nil
        }
        let backend = IPCDeviceBackend(port: port)
        guard await backend.ping() else {
            AppLog.warning("Service", "background service ping failed pid=\(serviceProcessIdentifier ?? 0) port=\(portValue)")
            return nil
        }
        AppLog.debug("Service", "background service ping ok pid=\(serviceProcessIdentifier ?? 0) port=\(portValue)")
        return backend
    }

    func launchServiceProcess() throws {
        guard !isCurrentProcessService else { return }
        if isServiceProcessAlive {
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--service-mode"]
        process.currentDirectoryURL = Bundle.main.bundleURL.deletingLastPathComponent()
        try process.run()
    }

    func launchFullAppProcess(arguments: [String] = []) {
        if let existingApp = existingForegroundAppInstance() {
            _ = existingApp.unhide()
            _ = existingApp.activate(options: [.activateAllWindows])
            return
        }

        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            configuration.arguments = arguments
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
                if let error {
                    AppLog.error("Service", "launchFullAppProcess failed: \(error.localizedDescription)")
                }
            }
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = Bundle.main.bundleURL.deletingLastPathComponent()
        do {
            try process.run()
        } catch {
            AppLog.error("Service", "launchFullAppProcess failed: \(error.localizedDescription)")
        }
    }

    func terminateOtherRunningApplicationInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let runningApplications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let targets = Self.otherRunningApplicationsToTerminate(
            in: runningApplications.map {
                RunningAppSnapshot(
                    processIdentifier: $0.processIdentifier,
                    activationPolicy: $0.activationPolicy,
                    isActive: $0.isActive,
                    isTerminated: $0.isTerminated
                )
            },
            excluding: ProcessInfo.processInfo.processIdentifier
        )

        for target in targets {
            guard let application = runningApplications.first(where: { $0.processIdentifier == target.processIdentifier }) else {
                continue
            }
            if !application.terminate() {
                AppLog.warning("Service", "terminate() declined by pid=\(application.processIdentifier); force terminating")
                _ = application.forceTerminate()
            }
        }
    }

    func stopServiceProcess() {
        guard let pid = serviceProcessIdentifier else { return }
        kill(pid, SIGTERM)
        defaults.removeObject(forKey: Self.endpointDefaultsKey)
        defaults.removeObject(forKey: Self.portDefaultsKey)
        defaults.removeObject(forKey: Self.pidDefaultsKey)
    }

    func resetPersistentState() throws {
        if isCurrentProcessService {
            stopCurrentServiceHostIfNeeded()
            defaults.removeObject(forKey: Self.endpointDefaultsKey)
            defaults.removeObject(forKey: Self.portDefaultsKey)
            defaults.removeObject(forKey: Self.pidDefaultsKey)
        } else {
            stopServiceProcess()
        }

        try removeLaunchAgent()

        if let defaultsDomainName, !defaultsDomainName.isEmpty {
            defaults.removePersistentDomain(forName: defaultsDomainName)
        } else {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.synchronize()
    }

    var isServiceProcessAlive: Bool {
        guard let pid = serviceProcessIdentifier else { return false }
        return kill(pid, 0) == 0
    }

    private var executableURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
    }

    private func existingForegroundAppInstance() -> NSRunningApplication? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        let runningApplications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard let preferred = Self.preferredReusableApplication(
            in: runningApplications.map {
                RunningAppSnapshot(
                    processIdentifier: $0.processIdentifier,
                    activationPolicy: $0.activationPolicy,
                    isActive: $0.isActive,
                    isTerminated: $0.isTerminated
                )
            },
            excluding: ProcessInfo.processInfo.processIdentifier
        ) else {
            return nil
        }
        return runningApplications.first { $0.processIdentifier == preferred.processIdentifier }
    }

    nonisolated static func preferredReusableApplication(
        in runningApplications: [RunningAppSnapshot],
        excluding currentProcessIdentifier: pid_t
    ) -> RunningAppSnapshot? {
        runningApplications
            .filter {
                $0.processIdentifier != currentProcessIdentifier &&
                    !$0.isTerminated &&
                    $0.activationPolicy == .regular
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive {
                    return lhs.isActive && !rhs.isActive
                }
                return lhs.processIdentifier < rhs.processIdentifier
            }
            .first
    }

    nonisolated static func otherRunningApplicationsToTerminate(
        in runningApplications: [RunningAppSnapshot],
        excluding currentProcessIdentifier: pid_t
    ) -> [RunningAppSnapshot] {
        runningApplications
            .filter {
                $0.processIdentifier != currentProcessIdentifier &&
                    !$0.isTerminated
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive {
                    return lhs.isActive && !rhs.isActive
                }
                if lhs.activationPolicy != rhs.activationPolicy {
                    return lhs.activationPolicy == .regular && rhs.activationPolicy != .regular
                }
                return lhs.processIdentifier < rhs.processIdentifier
            }
    }

    private var launchAgentURL: URL {
        let libraryURL = launchAgentsDirectoryURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        return libraryURL.appendingPathComponent("io.opensnek.OpenSnek.service.plist")
    }

    private func installLaunchAgent() throws {
        try installLaunchAgent(
            executablePath: executableURL.path,
            workingDirectoryPath: Bundle.main.bundleURL.deletingLastPathComponent().path
        )
    }

    private func installLaunchAgent(
        executablePath: String,
        workingDirectoryPath: String
    ) throws {
        let launchAgentsDirectory = launchAgentURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true, attributes: nil)

        let plist = Self.launchAgentPropertyList(
            executablePath: executablePath,
            workingDirectoryPath: workingDirectoryPath
        )
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private func currentLaunchAgentPropertyList() -> [String: Any]? {
        guard fileManager.fileExists(atPath: launchAgentURL.path) else { return nil }
        guard let data = try? Data(contentsOf: launchAgentURL) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    private func removeLaunchAgent() throws {
        if fileManager.fileExists(atPath: launchAgentURL.path) {
            try fileManager.removeItem(at: launchAgentURL)
        }
    }

    nonisolated static func launchAgentPropertyList(
        executablePath: String,
        workingDirectoryPath: String
    ) -> [String: Any] {
        [
            "Label": "io.opensnek.OpenSnek.service",
            "ProgramArguments": [executablePath, "--service-mode", "--login-start"],
            "RunAtLoad": true,
            "KeepAlive": false,
            "WorkingDirectory": workingDirectoryPath,
            "StandardOutPath": ("~/Library/Logs/OpenSnek/service.stdout.log" as NSString).expandingTildeInPath,
            "StandardErrorPath": ("~/Library/Logs/OpenSnek/service.stderr.log" as NSString).expandingTildeInPath,
        ]
    }
}
