@MainActor
final class AppEnvironment {
    let launchRole: OpenSnekProcessRole
    let serviceCoordinator: BackgroundServiceCoordinator
    let releaseUpdateChecker = ReleaseUpdateChecker()
    var backend: any DeviceBackend
    var hasCheckedForUpdates = false

    init(
        launchRole: OpenSnekProcessRole,
        backend: any DeviceBackend,
        serviceCoordinator: BackgroundServiceCoordinator
    ) {
        self.launchRole = launchRole
        self.backend = backend
        self.serviceCoordinator = serviceCoordinator
    }

    var usesRemoteServiceTransport: Bool {
        !launchRole.isService && backend.usesRemoteServiceTransport
    }
}
