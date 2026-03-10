#!/usr/bin/env swift

import AppKit
import Foundation

struct Options {
    var outputPath: String = ""
    var width: Int = 780
    var height: Int = 460
    var scale: Int = 1
    var iconPath: String = ""
}

enum RenderError: Error, CustomStringConvertible {
    case usage(String)
    case help(String)
    case invalidImage(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .help(let message):
            return message
        case .invalidImage(let path):
            return "Failed to load image at \(path)"
        case .writeFailed(let path):
            return "Failed to write PNG to \(path)"
        }
    }
}

func parseArguments() throws -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--output":
            guard let value = args.first else { throw RenderError.usage("Missing value for --output") }
            options.outputPath = value
            args.removeFirst()
        case "--width":
            guard let value = args.first, let intValue = Int(value) else { throw RenderError.usage("Missing or invalid value for --width") }
            options.width = intValue
            args.removeFirst()
        case "--height":
            guard let value = args.first, let intValue = Int(value) else { throw RenderError.usage("Missing or invalid value for --height") }
            options.height = intValue
            args.removeFirst()
        case "--scale":
            guard let value = args.first, let intValue = Int(value), intValue > 0 else { throw RenderError.usage("Missing or invalid value for --scale") }
            options.scale = intValue
            args.removeFirst()
        case "--icon":
            guard let value = args.first else { throw RenderError.usage("Missing value for --icon") }
            options.iconPath = value
            args.removeFirst()
        case "-h", "--help":
            throw RenderError.help("""
            Usage:
              render_dmg_background.swift --output <path> [--width <px>] [--height <px>] [--scale <factor>] --icon <path>
            """)
        default:
            throw RenderError.usage("Unknown argument: \(arg)")
        }
    }

    guard !options.outputPath.isEmpty else {
        throw RenderError.usage("Missing required --output path")
    }
    guard !options.iconPath.isEmpty else {
        throw RenderError.usage("Missing required --icon path")
    }
    return options
}

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> NSColor {
    NSColor(calibratedRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
}

func drawGlow(in rect: NSRect, color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: rect).fill()
}

func drawArrow(from start: NSPoint, to end: NSPoint, scale: CGFloat) {
    let arrowPath = NSBezierPath()
    arrowPath.lineWidth = 6 * scale
    arrowPath.lineCapStyle = .round
    arrowPath.lineJoinStyle = .round
    arrowPath.move(to: start)
    let midX = (start.x + end.x) / 2
    arrowPath.curve(
        to: end,
        controlPoint1: NSPoint(x: midX - 34 * scale, y: start.y - 6 * scale),
        controlPoint2: NSPoint(x: midX + 34 * scale, y: end.y + 6 * scale)
    )
    rgba(190, 246, 214, 0.82).setStroke()
    arrowPath.stroke()

    let headPath = NSBezierPath()
    headPath.lineJoinStyle = .round
    headPath.move(to: end)
    headPath.line(to: NSPoint(x: end.x - 18 * scale, y: end.y + 12 * scale))
    headPath.line(to: NSPoint(x: end.x - 14 * scale, y: end.y))
    headPath.line(to: NSPoint(x: end.x - 18 * scale, y: end.y - 12 * scale))
    headPath.close()
    rgba(190, 246, 214, 0.9).setFill()
    headPath.fill()
}

func savePNG(_ image: NSImage, to path: String) throws {
    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        throw RenderError.writeFailed(path)
    }

    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try pngData.write(to: url)
}

do {
    let options = try parseArguments()
    let scale = CGFloat(options.scale)
    let canvasSize = NSSize(width: CGFloat(options.width) * scale, height: CGFloat(options.height) * scale)

    guard NSImage(contentsOfFile: options.iconPath) != nil else {
        throw RenderError.invalidImage(options.iconPath)
    }

    let image = NSImage(size: canvasSize, flipped: false) { bounds in
        let backgroundGradient = NSGradient(colors: [
            rgba(8, 16, 18),
            rgba(12, 28, 26),
            rgba(10, 16, 20)
        ])!
        backgroundGradient.draw(in: bounds, angle: -24)

        drawGlow(in: NSRect(x: bounds.minX - 80 * scale, y: bounds.maxY - 260 * scale, width: 320 * scale, height: 320 * scale), color: rgba(38, 201, 149, 0.18))
        drawGlow(in: NSRect(x: bounds.maxX - 280 * scale, y: bounds.minY - 80 * scale, width: 340 * scale, height: 340 * scale), color: rgba(82, 224, 172, 0.12))

        let panelRect = NSRect(x: 36 * scale, y: 36 * scale, width: bounds.width - 72 * scale, height: bounds.height - 72 * scale)
        let panel = NSBezierPath(roundedRect: panelRect, xRadius: 28 * scale, yRadius: 28 * scale)
        rgba(20, 28, 31, 0.82).setFill()
        panel.fill()
        rgba(120, 171, 145, 0.22).setStroke()
        panel.lineWidth = 2 * scale
        panel.stroke()

        let leftAnchor = NSPoint(x: 330 * scale, y: 252 * scale)
        let rightAnchor = NSPoint(x: 450 * scale, y: 252 * scale)
        drawArrow(from: leftAnchor, to: rightAnchor, scale: scale)

        return true
    }

    try savePNG(image, to: options.outputPath)
} catch {
    if case let RenderError.help(message) = error {
        print(message)
        exit(0)
    }
    fputs("\(error)\n", stderr)
    exit(1)
}
