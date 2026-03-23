import AppKit
import SwiftUI

struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            configure(window)
        }
    }

    private func configure(_ window: NSWindow) {
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
}
