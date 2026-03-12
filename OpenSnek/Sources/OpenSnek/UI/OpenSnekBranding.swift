import AppKit

enum OpenSnekBranding {
    static var menuBarIconSide: CGFloat {
        max(14, floor(NSStatusBar.system.thickness - 6))
    }

    static var menuIcon: NSImage? {
        makeSizedSourceIcon(size: NSSize(width: menuBarIconSide, height: menuBarIconSide))
    }

    private static func loadSourceIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "snek-menu", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = false
        return image
    }

    private static func makeSizedSourceIcon(size: NSSize) -> NSImage? {
        guard let source = loadSourceIcon(),
              let sized = source.copy() as? NSImage else {
            return nil
        }
        sized.size = size
        sized.isTemplate = false
        return sized
    }
}
