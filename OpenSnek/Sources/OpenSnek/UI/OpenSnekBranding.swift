import AppKit

enum OpenSnekBranding {
    static var menuBarIconSide: CGFloat {
        max(16, floor(NSStatusBar.system.thickness))
    }

    static var menuIcon: NSImage? {
        makeSizedSourceIcon(size: NSSize(width: menuBarIconSide, height: menuBarIconSide))
    }

    static func menuBarDpiBadge(dpi: Int) -> NSImage {
        let badgeHeight = max(18, floor(NSStatusBar.system.thickness - 2))
        let labelFont = NSFont.systemFont(ofSize: 10, weight: .black)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .black)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]

        let labelText = "DPI" as NSString
        let valueText = "\(dpi)" as NSString
        let labelSize = labelText.size(withAttributes: labelAttributes)
        let valueSize = valueText.size(withAttributes: valueAttributes)
        let badgeWidth = max(24, ceil(max(labelSize.width, valueSize.width)) + 4)
        let totalHeight = labelSize.height + valueSize.height
        let baseY = max(0, floor((badgeHeight - totalHeight) / 2))

        let image = NSImage(size: NSSize(width: badgeWidth, height: badgeHeight))
        image.lockFocus()
        labelText.draw(
            in: NSRect(
                x: 0,
                y: baseY + valueSize.height - 2,
                width: badgeWidth,
                height: labelSize.height
            ),
            withAttributes: labelAttributes
        )
        valueText.draw(
            in: NSRect(
                x: 0,
                y: baseY,
                width: badgeWidth,
                height: valueSize.height
            ),
            withAttributes: valueAttributes
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
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
