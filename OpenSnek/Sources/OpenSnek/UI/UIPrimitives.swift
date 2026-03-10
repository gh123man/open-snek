import SwiftUI
import AppKit
import OpenSnekCore

struct Pill: View {
    let text: String
    let color: Color
    var fontSize: CGFloat = 11
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 5

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.78))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(color, in: Capsule())
    }
}

struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15), lineWidth: 1))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.18), lineWidth: 1))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct ColorSwatchButton: View {
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isSelected ? 0.95 : 0.35), lineWidth: isSelected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
    }
}

extension View {
    func hintTextStyle() -> some View {
        modifier(HintTextModifier())
    }
}

struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragBlockingView {
        WindowDragBlockingView(frame: .zero)
    }

    func updateNSView(_ nsView: WindowDragBlockingView, context: Context) {}
}

final class WindowDragBlockingView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
}

private struct HintTextModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.58))
    }
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    init(rgb: OpenSnekCore.RGBColor) {
        self.init(
            red: Double(max(0, min(255, rgb.r))) / 255.0,
            green: Double(max(0, min(255, rgb.g))) / 255.0,
            blue: Double(max(0, min(255, rgb.b))) / 255.0
        )
    }
}

extension OpenSnekCore.RGBColor {
    mutating func assign(color: Color) {
        #if os(macOS)
            let ns = NSColor(color)
            let rgb = ns.usingColorSpace(.sRGB) ?? ns
            r = Int(round(rgb.redComponent * 255))
            g = Int(round(rgb.greenComponent * 255))
            b = Int(round(rgb.blueComponent * 255))
        #endif
    }

    static func fromColor(_ color: Color) -> OpenSnekCore.RGBColor {
        var next = OpenSnekCore.RGBColor(r: 0, g: 0, b: 0)
        next.assign(color: color)
        return next
    }
}
