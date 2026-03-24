import Foundation
import OpenSnekCore

@MainActor
final class AppState {
    let environment: AppEnvironment
    let deviceStore: DeviceStore
    let editorStore: EditorStore
    let runtimeStore: RuntimeStore
    let deviceController: AppStateDeviceController
    let editorController: AppStateEditorController
    let applyController: AppStateApplyController
    let runtimeController: AppStateRuntimeController
    private var autoStartRuntimeTask: Task<Void, Never>?

    init(
        launchRole: OpenSnekProcessRole = .current,
        backend: (any DeviceBackend)? = nil,
        serviceCoordinator: BackgroundServiceCoordinator = .shared,
        autoStart: Bool = true,
        statusItemDpiDisplayDuration: TimeInterval = 3.0
    ) {
        let initialBackend = backend ?? Self.initialBackend(
            launchRole: launchRole,
            serviceCoordinator: serviceCoordinator
        )
        let environment = AppEnvironment(
            launchRole: launchRole,
            backend: initialBackend,
            serviceCoordinator: serviceCoordinator
        )
        let buttonSlots = ButtonSlotDescriptor.defaults
        self.environment = environment
        self.deviceStore = DeviceStore(environment: environment)
        self.editorStore = EditorStore(deviceStore: deviceStore)
        self.runtimeStore = RuntimeStore(
            environment: environment,
            backgroundServiceEnabled: serviceCoordinator.backgroundServiceEnabled,
            launchAtStartupEnabled: serviceCoordinator.launchAtStartupEnabled,
            statusItemDpiDisplayDuration: statusItemDpiDisplayDuration
        )
        self.deviceController = AppStateDeviceController(
            environment: environment,
            deviceStore: deviceStore
        )
        self.editorController = AppStateEditorController(
            environment: environment,
            deviceStore: deviceStore,
            editorStore: editorStore,
            buttonSlots: buttonSlots
        )
        self.applyController = AppStateApplyController(
            environment: environment,
            deviceStore: deviceStore,
            editorStore: editorStore,
            runtimeStore: runtimeStore
        )
        self.runtimeController = AppStateRuntimeController(
            environment: environment,
            deviceStore: deviceStore,
            runtimeStore: runtimeStore
        )

        wireGraph(
            backendWasInjected: backend != nil,
            autoStart: autoStart
        )
    }

    private static func initialBackend(
        launchRole: OpenSnekProcessRole,
        serviceCoordinator: BackgroundServiceCoordinator
    ) -> any DeviceBackend {
        if launchRole.isService || !serviceCoordinator.backgroundServiceEnabled {
            return LocalBridgeBackend.shared
        }
        return BootstrapPendingBackend.shared
    }

    deinit {
        let autoStartRuntimeTask = self.autoStartRuntimeTask
        let deviceController = self.deviceController
        let applyController = self.applyController
        let editorController = self.editorController
        let runtimeController = self.runtimeController

        @MainActor
        func tearDownControllers() {
            autoStartRuntimeTask?.cancel()
            deviceController.tearDown()
            applyController.tearDown()
            editorController.tearDown()
            runtimeController.tearDown()
        }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                tearDownControllers()
            }
        } else {
            let group = DispatchGroup()
            group.enter()
            Task { @MainActor in
                tearDownControllers()
                group.leave()
            }
            group.wait()
        }
    }

    private func wireGraph(backendWasInjected: Bool, autoStart: Bool) {
        deviceController.bind(
            editorController: editorController,
            applyController: applyController,
            runtimeController: runtimeController
        )
        editorController.bind(applyController: applyController)
        applyController.bind(
            deviceController: deviceController,
            editorController: editorController,
            runtimeController: runtimeController
        )
        runtimeController.bind(deviceController: deviceController)

        deviceStore.bind(
            deviceController: deviceController,
            applyController: applyController,
            runtimeController: runtimeController,
            runtimeStore: runtimeStore,
            editorStore: editorStore
        )
        editorStore.bind(
            editorController: editorController,
            applyController: applyController
        )
        runtimeStore.bind(runtimeController: runtimeController)

        runtimeController.setBackendReady(
            environment.launchRole.isService || backendWasInjected || !environment.serviceCoordinator.backgroundServiceEnabled
        )
        runtimeController.scheduleBackendStateUpdatesBootstrap()
        if environment.launchRole.isService, autoStart {
            autoStartRuntimeTask = Task { [weak self] in
                await self?.runtimeController.start()
            }
        }
    }
}
