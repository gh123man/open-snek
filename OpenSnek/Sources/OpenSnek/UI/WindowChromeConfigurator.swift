import AppKit
import OpenSnekAppSupport
import SwiftUI

struct WindowChromeConfigurator: NSViewRepresentable {
    nonisolated static let mainWindowFrameAutosaveName = "OpenSnekMainWindow"
    nonisolated static let framePersistenceKeyPrefix = "windowFrame."

    nonisolated static func shouldUseCompatibilityChrome(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        osVersion.majorVersion == 15
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView(frame: .zero)
        view.coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            MainActor.assumeIsolated {
                context.coordinator.attach(to: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.coordinator = context.coordinator
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            MainActor.assumeIsolated {
                context.coordinator.attach(to: window)
            }
        }
    }

    @MainActor
    static func configure(
        _ window: NSWindow,
        autosaveName: String = mainWindowFrameAutosaveName,
        defaults: UserDefaults = .standard,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        if DeveloperRuntimeOptions.rememberWindowSizeEnabled(defaults: defaults) {
            restorePersistedFrameIfNeeded(window, autosaveName: autosaveName, defaults: defaults)
            constrainFrameToVisibleScreensIfNeeded(window)
        }
        window.title = ""
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        if shouldUseCompatibilityChrome(osVersion: osVersion) {
            return
        }

        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
    }

    nonisolated static func framePersistenceKey(
        for autosaveName: String = mainWindowFrameAutosaveName
    ) -> String {
        "\(framePersistenceKeyPrefix)\(autosaveName)"
    }

    @MainActor
    @discardableResult
    static func restorePersistedFrameIfNeeded(
        _ window: NSWindow,
        autosaveName: String = mainWindowFrameAutosaveName,
        defaults: UserDefaults = .standard,
        visibleScreenFrames: [NSRect] = currentVisibleScreenFrames()
    ) -> Bool {
        guard
            let encodedFrame = defaults.string(forKey: framePersistenceKey(for: autosaveName))
        else {
            return false
        }

        let frame = NSRectFromString(encodedFrame)
        guard isValidPersistedFrame(frame) else { return false }
        let normalizedFrame = normalizedPersistedFrame(frame, visibleScreenFrames: visibleScreenFrames)
        window.setFrame(normalizedFrame, display: false)
        return true
    }

    @MainActor
    static func persistFrame(
        _ window: NSWindow,
        autosaveName: String = mainWindowFrameAutosaveName,
        defaults: UserDefaults = .standard
    ) {
        guard DeveloperRuntimeOptions.rememberWindowSizeEnabled(defaults: defaults) else { return }
        let frame = window.frame
        guard isValidPersistedFrame(frame) else { return }
        defaults.set(NSStringFromRect(frame), forKey: framePersistenceKey(for: autosaveName))
        defaults.synchronize()
    }

    nonisolated static func isValidPersistedFrame(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite &&
        frame.origin.y.isFinite &&
        frame.size.width.isFinite &&
        frame.size.height.isFinite &&
        frame.size.width > 0 &&
        frame.size.height > 0
    }

    @MainActor
    static func constrainFrameToVisibleScreensIfNeeded(
        _ window: NSWindow,
        visibleScreenFrames: [NSRect] = currentVisibleScreenFrames()
    ) {
        let normalizedFrame = normalizedPersistedFrame(window.frame, visibleScreenFrames: visibleScreenFrames)
        guard normalizedFrame != window.frame else { return }
        window.setFrame(normalizedFrame, display: false)
    }

    nonisolated static func normalizedPersistedFrame(
        _ frame: NSRect,
        visibleScreenFrames: [NSRect]
    ) -> NSRect {
        guard isValidPersistedFrame(frame) else { return frame }
        guard let targetVisibleFrame = preferredVisibleScreenFrame(for: frame, visibleScreenFrames: visibleScreenFrames) else {
            return frame
        }

        let width = min(frame.width, targetVisibleFrame.width)
        let height = min(frame.height, targetVisibleFrame.height)
        let x = min(max(frame.minX, targetVisibleFrame.minX), targetVisibleFrame.maxX - width)
        let y = min(max(frame.minY, targetVisibleFrame.minY), targetVisibleFrame.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    nonisolated static func preferredVisibleScreenFrame(
        for frame: NSRect,
        visibleScreenFrames: [NSRect]
    ) -> NSRect? {
        visibleScreenFrames.max { lhs, rhs in
            intersectionArea(frame, visibleFrame: lhs) < intersectionArea(frame, visibleFrame: rhs)
        } ?? visibleScreenFrames.first
    }

    nonisolated static func intersectionArea(
        _ frame: NSRect,
        visibleFrame: NSRect
    ) -> CGFloat {
        let intersection = frame.intersection(visibleFrame)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    nonisolated static func currentVisibleScreenFrames() -> [NSRect] {
        NSScreen.screens.map(\.visibleFrame)
    }

    final class Coordinator: @unchecked Sendable {
        private weak var window: NSWindow?
        private var observerTokens: [NSObjectProtocol] = []
        private var hasShownWindow = false
        private var lastStableFrame: NSRect?

        deinit {
            observerTokens.forEach(NotificationCenter.default.removeObserver)
        }

        @MainActor
        func attach(to window: NSWindow) {
            guard self.window !== window else { return }

            detach()
            self.window = window
            hasShownWindow = window.isVisible
            lastStableFrame = nil
            MainActor.assumeIsolated {
                WindowChromeConfigurator.configure(window)
            }

            let center = NotificationCenter.default
            observerTokens = [
                center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.markWindowShown()
                    }
                },
                center.addObserver(
                    forName: NSWindow.didBecomeMainNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.markWindowShown()
                    }
                },
                center.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.captureAndPersistStableFrame()
                    }
                },
                center.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.captureStableFrameDuringLiveResize()
                    }
                },
                center.addObserver(
                    forName: NSWindow.didEndLiveResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.captureAndPersistStableFrame()
                    }
                },
                center.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.persistLastStableFrame()
                        self?.detach()
                    }
                }
            ]
        }

        @MainActor
        func detach() {
            observerTokens.forEach(NotificationCenter.default.removeObserver)
            observerTokens.removeAll()
            hasShownWindow = false
            lastStableFrame = nil
            window = nil
        }

        @MainActor
        private func markWindowShown() {
            guard let window else { return }
            hasShownWindow = true
            if WindowChromeConfigurator.isValidPersistedFrame(window.frame) {
                lastStableFrame = window.frame
            }
        }

        @MainActor
        private func captureStableFrameDuringLiveResize() {
            guard hasShownWindow, let window, window.inLiveResize else { return }
            guard WindowChromeConfigurator.isValidPersistedFrame(window.frame) else { return }
            lastStableFrame = window.frame
        }

        @MainActor
        private func captureAndPersistStableFrame() {
            guard hasShownWindow, let window else { return }
            guard WindowChromeConfigurator.isValidPersistedFrame(window.frame) else { return }
            lastStableFrame = window.frame
            persistFrame(window)
        }

        @MainActor
        private func persistLastStableFrame() {
            guard hasShownWindow, let window else { return }
            let frameToPersist = lastStableFrame ?? window.frame
            guard WindowChromeConfigurator.isValidPersistedFrame(frameToPersist) else { return }
            window.setFrame(frameToPersist, display: false)
            WindowChromeConfigurator.persistFrame(window)
        }

        @MainActor
        private func persistFrame(_ window: NSWindow) {
            WindowChromeConfigurator.persistFrame(window)
        }
    }

    final class TrackingView: NSView {
        weak var coordinator: Coordinator?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)

            guard let coordinator else { return }
            guard let newWindow else {
                MainActor.assumeIsolated {
                    coordinator.detach()
                }
                return
            }

            MainActor.assumeIsolated {
                coordinator.attach(to: newWindow)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            guard let coordinator, let window else { return }
            MainActor.assumeIsolated {
                coordinator.attach(to: window)
            }
        }
    }
}
