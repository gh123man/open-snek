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

    static func menuBarLowBatteryBadge() -> NSImage {
        let side = menuBarIconSide
        let image = NSImage(size: NSSize(width: side, height: side))
        let stroke = NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.39, alpha: 1.0)
        let fill = NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.39, alpha: 0.22)
        let symbol = NSColor.white

        image.lockFocus()

        let bodyRect = NSRect(
            x: floor(side * 0.10),
            y: floor(side * 0.24),
            width: floor(side * 0.68),
            height: floor(side * 0.46)
        )
        let tipRect = NSRect(
            x: bodyRect.maxX + 1,
            y: floor(bodyRect.midY - (side * 0.08)),
            width: max(2, floor(side * 0.10)),
            height: max(3, floor(side * 0.16))
        )

        let outline = NSBezierPath(roundedRect: bodyRect, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1.4
        stroke.setStroke()
        outline.stroke()

        let cap = NSBezierPath(roundedRect: tipRect, xRadius: 1, yRadius: 1)
        stroke.setFill()
        cap.fill()

        let chargeRect = NSRect(
            x: bodyRect.minX + 2,
            y: bodyRect.minY + 2,
            width: max(3, floor(bodyRect.width * 0.18)),
            height: max(4, bodyRect.height - 4)
        )
        let charge = NSBezierPath(roundedRect: chargeRect, xRadius: 1.5, yRadius: 1.5)
        fill.setFill()
        charge.fill()
        stroke.setStroke()
        charge.stroke()

        let markWidth = max(1.4, side * 0.08)
        let markHeight = max(5, side * 0.20)
        let markX = bodyRect.midX - (markWidth / 2)
        let markY = bodyRect.midY - (markHeight / 2) + 1
        let exclamation = NSBezierPath(
            roundedRect: NSRect(x: markX, y: markY, width: markWidth, height: markHeight),
            xRadius: 1,
            yRadius: 1
        )
        symbol.setFill()
        exclamation.fill()

        let dotSize = max(1.8, side * 0.09)
        let dotRect = NSRect(x: bodyRect.midX - (dotSize / 2), y: bodyRect.minY + 3, width: dotSize, height: dotSize)
        let dot = NSBezierPath(ovalIn: dotRect)
        dot.fill()

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
