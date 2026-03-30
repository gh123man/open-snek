import AppKit
import OpenSnekAppSupport
import SwiftUI

struct WindowChromeConfigurator: NSViewRepresentable {
    nonisolated static let mainWindowFrameAutosaveName = "OpenSnekMainWindow"
    nonisolated static let framePersistenceKeyPrefix = "windowFrame."

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView(frame: .zero)
        view.coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.coordinator = context.coordinator
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            context.coordinator.attach(to: window)
        }
    }

    @MainActor
    static func configure(
        _ window: NSWindow,
        autosaveName: String = mainWindowFrameAutosaveName,
        defaults: UserDefaults = .standard
    ) {
        if DeveloperRuntimeOptions.rememberWindowSizeEnabled(defaults: defaults) {
            window.setFrameAutosaveName(autosaveName)
            restorePersistedFrameIfNeeded(window, autosaveName: autosaveName, defaults: defaults)
        }
        window.title = ""
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // Do not set toolbarStyle = .unified — this window has no toolbar,
        // and the unified toolbar style causes AppKit to surface the app icon
        // in the title-bar region on macOS 15 and some earlier versions,
        // producing a spurious status-bar icon even when service mode is off.
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
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard
            let encodedFrame = defaults.string(forKey: framePersistenceKey(for: autosaveName))
        else {
            return false
        }

        let frame = NSRectFromString(encodedFrame)
        guard isValidPersistedFrame(frame) else { return false }
        window.setFrame(frame, display: false)
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
        window.saveFrame(usingName: autosaveName)
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

    final class Coordinator: @unchecked Sendable {
        private weak var window: NSWindow?
        private var observerTokens: [NSObjectProtocol] = []

        deinit {
            observerTokens.forEach(NotificationCenter.default.removeObserver)
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }

            detach()
            self.window = window
            MainActor.assumeIsolated {
                WindowChromeConfigurator.configure(window)
            }

            let center = NotificationCenter.default
            observerTokens = [
                center.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.persistFrame()
                },
                center.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.persistFrame()
                },
                center.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.persistFrame()
                    self?.detach()
                }
            ]
        }

        func detach() {
            observerTokens.forEach(NotificationCenter.default.removeObserver)
            observerTokens.removeAll()
            window = nil
        }

        private func persistFrame() {
            guard let window else { return }
            MainActor.assumeIsolated {
                WindowChromeConfigurator.persistFrame(window)
            }
        }
    }

    final class TrackingView: NSView {
        weak var coordinator: Coordinator?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)

            guard let coordinator else { return }
            guard let newWindow else {
                coordinator.detach()
                return
            }

            coordinator.attach(to: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            guard let coordinator, let window else { return }
            coordinator.attach(to: window)
        }
    }
}
