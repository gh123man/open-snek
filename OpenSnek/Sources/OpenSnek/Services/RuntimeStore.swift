import Foundation
import Observation
import OpenSnekAppSupport

@MainActor
@Observable
final class RuntimeStore {
    let environment: AppEnvironment
    var backgroundServiceEnabled: Bool
    var launchAtStartupEnabled: Bool
    var serviceStatusMessage: String?
    var hidAccessStatus: HIDAccessStatus = .unknown()
    var permissionStatusMessage: String?
    var isResettingPermissions = false
    var statusItemTransientDpi: Int?
    var openSettingsRequestCount = 0
    @ObservationIgnored let statusItemDpiDisplayDuration: TimeInterval

    @ObservationIgnored private weak var runtimeControllerStorage: AppStateRuntimeController?

    init(
        environment: AppEnvironment,
        backgroundServiceEnabled: Bool,
        launchAtStartupEnabled: Bool,
        statusItemDpiDisplayDuration: TimeInterval = 3.0
    ) {
        self.environment = environment
        self.backgroundServiceEnabled = backgroundServiceEnabled
        self.launchAtStartupEnabled = launchAtStartupEnabled
        self.statusItemDpiDisplayDuration = statusItemDpiDisplayDuration
    }

    func bind(runtimeController: AppStateRuntimeController) {
        self.runtimeControllerStorage = runtimeController
    }

    private var runtimeController: AppStateRuntimeController {
        guard let runtimeControllerStorage else {
            preconditionFailure("RuntimeStore accessed before runtimeController was bound")
        }
        return runtimeControllerStorage
    }

    var isServiceProcess: Bool {
        environment.launchRole.isService
    }

    var compactStatusMessage: String? {
        runtimeController.compactStatusMessage
    }

    var currentPollingProfile: PollingProfile {
        runtimeController.currentPollingProfile
    }

    func start() async {
        await runtimeController.start()
    }

    func setCompactMenuPresented(_ isPresented: Bool) {
        runtimeController.setCompactMenuPresented(isPresented)
    }

    func setBackgroundServiceEnabled(_ enabled: Bool) async {
        await runtimeController.setBackgroundServiceEnabled(enabled)
    }

    func setLaunchAtStartupEnabled(_ enabled: Bool) {
        runtimeController.setLaunchAtStartupEnabled(enabled)
    }

    func sendRemoteClientPresence() {
        runtimeController.sendRemoteClientPresence()
    }

    func recordRemoteClientPresence(_ presence: CrossProcessClientPresence, now: Date = Date()) {
        runtimeController.recordRemoteClientPresence(presence, now: now)
    }

    func pollingProfile(at now: Date) -> PollingProfile {
        runtimeController.pollingProfile(at: now)
    }

    func activeFastPollingDeviceIDs(at now: Date) -> [String] {
        runtimeController.activeFastPollingDeviceIDs(at: now)
    }

    func refreshHIDAccessStatus(forceRefresh: Bool = false) async {
        await runtimeController.refreshHIDAccessStatus(forceRefresh: forceRefresh)
    }

    func resetAllPermissions() async {
        await runtimeController.resetAllPermissions()
    }

    func openFullAppFromService() {
        runtimeController.openFullAppFromService()
    }

    func openSettingsFromService() {
        Task {
            await runtimeController.openSettingsFromService()
        }
    }

    func prepareForCurrentServiceProcessTermination() {
        runtimeController.prepareForCurrentServiceProcessTermination()
    }

    func terminateServiceProcess() {
        runtimeController.terminateServiceProcess()
    }

    func developerTransportSettingsDidChange() {
        Task {
            await runtimeController.developerTransportSettingsDidChange()
        }
    }
}
