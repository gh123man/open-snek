#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/App/Resources/Assets.xcassets/AppIcon.appiconset"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      cat <<'USAGE'
Generate Open Snek macOS AppIcon.appiconset PNGs.

Usage:
  generate_appiconset.sh [--output /path/to/AppIcon.appiconset]
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v sips >/dev/null 2>&1; then
  echo "sips is required" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
BASE_ICON="$(mktemp /tmp/opensnek-icon-XXXXXX.png)"

swift - "$BASE_ICON" <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let width = 1024
let height = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("Unable to create bitmap context") }

let colors = [
    CGColor(red: 0.04, green: 0.14, blue: 0.30, alpha: 1),
    CGColor(red: 0.00, green: 0.55, blue: 0.45, alpha: 1),
    CGColor(red: 0.93, green: 0.78, blue: 0.10, alpha: 1)
] as CFArray
let locations: [CGFloat] = [0.0, 0.55, 1.0]
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])

ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.22))
let inset: CGFloat = 74
let tileRect = CGRect(x: inset, y: inset, width: 1024 - (inset * 2), height: 1024 - (inset * 2))
ctx.addPath(CGPath(roundedRect: tileRect, cornerWidth: 210, cornerHeight: 210, transform: nil))
ctx.fillPath()

ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.62))
ctx.setLineWidth(52)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 730, y: 812))
ctx.addCurve(to: CGPoint(x: 330, y: 660), control1: CGPoint(x: 560, y: 824), control2: CGPoint(x: 394, y: 780))
ctx.addCurve(to: CGPoint(x: 628, y: 458), control1: CGPoint(x: 272, y: 560), control2: CGPoint(x: 566, y: 560))
ctx.addCurve(to: CGPoint(x: 368, y: 244), control1: CGPoint(x: 688, y: 370), control2: CGPoint(x: 444, y: 332))
ctx.strokePath()

ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
ctx.addEllipse(in: CGRect(x: 690, y: 780, width: 64, height: 64))
ctx.fillPath()

guard let image = ctx.makeImage() else { fatalError("Unable to create image") }
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Unable to create image destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Unable to finalize image destination") }
SWIFT

sips -s format png -z 16 16 "$BASE_ICON" --out "$OUTPUT_DIR/icon_16x16.png" >/dev/null
sips -s format png -z 32 32 "$BASE_ICON" --out "$OUTPUT_DIR/icon_16x16@2x.png" >/dev/null
sips -s format png -z 32 32 "$BASE_ICON" --out "$OUTPUT_DIR/icon_32x32.png" >/dev/null
sips -s format png -z 64 64 "$BASE_ICON" --out "$OUTPUT_DIR/icon_32x32@2x.png" >/dev/null
sips -s format png -z 128 128 "$BASE_ICON" --out "$OUTPUT_DIR/icon_128x128.png" >/dev/null
sips -s format png -z 256 256 "$BASE_ICON" --out "$OUTPUT_DIR/icon_128x128@2x.png" >/dev/null
sips -s format png -z 256 256 "$BASE_ICON" --out "$OUTPUT_DIR/icon_256x256.png" >/dev/null
sips -s format png -z 512 512 "$BASE_ICON" --out "$OUTPUT_DIR/icon_256x256@2x.png" >/dev/null
sips -s format png -z 512 512 "$BASE_ICON" --out "$OUTPUT_DIR/icon_512x512.png" >/dev/null
sips -s format png -z 1024 1024 "$BASE_ICON" --out "$OUTPUT_DIR/icon_512x512@2x.png" >/dev/null

rm -f "$BASE_ICON"
echo "Generated AppIcon set in: $OUTPUT_DIR"
