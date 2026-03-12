import SwiftUI
import AppKit

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
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
        window.isMovableByWindowBackground = true
        installTitlebarIconIfNeeded(window)
    }

    private func installTitlebarIconIfNeeded(_ window: NSWindow) {
        guard !window.titlebarAccessoryViewControllers.contains(where: {
            $0.identifier == OpenSnekBranding.titlebarAccessoryIdentifier
        }) else {
            return
        }
        guard let titlebarIcon = OpenSnekBranding.titlebarIcon else { return }

        let imageView = NSImageView(image: titlebarIcon)
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14),
            container.widthAnchor.constraint(equalToConstant: 14),
            container.heightAnchor.constraint(equalToConstant: 14),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = OpenSnekBranding.titlebarAccessoryIdentifier
        accessory.layoutAttribute = .left
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)
    }
}
