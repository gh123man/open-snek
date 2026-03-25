import AppKit
import SwiftUI

struct WindowChromeConfigurator: NSViewRepresentable {
    nonisolated static let mainWindowFrameAutosaveName = "OpenSnekMainWindow"

    nonisolated static func shouldUseCompatibilityChrome(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        osVersion.majorVersion == 15
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            Self.configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            Self.configure(window)
        }
    }

    @MainActor
    static func configure(
        _ window: NSWindow,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        window.setFrameAutosaveName(mainWindowFrameAutosaveName)
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
}
