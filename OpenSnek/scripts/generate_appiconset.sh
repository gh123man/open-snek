#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/App/Resources/Assets.xcassets/AppIcon.appiconset"
SOURCE_PNG="$PROJECT_DIR/Branding/AppIcon-master.png"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --source)
      SOURCE_PNG="${2:-}"
      shift 2
      ;;
    -h|--help)
      cat <<'USAGE'
Generate Open Snek macOS AppIcon.appiconset PNGs.

Usage:
  generate_appiconset.sh [--source /path/to/master.png] [--output /path/to/AppIcon.appiconset]
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

if [[ ! -f "$SOURCE_PNG" ]]; then
  echo "Icon source not found: $SOURCE_PNG" >&2
  exit 1
fi

SOURCE_INFO="$(sips -g pixelWidth -g pixelHeight "$SOURCE_PNG" 2>/dev/null)"
SOURCE_WIDTH="$(printf '%s\n' "$SOURCE_INFO" | awk '/pixelWidth:/{print $2}')"
SOURCE_HEIGHT="$(printf '%s\n' "$SOURCE_INFO" | awk '/pixelHeight:/{print $2}')"
if [[ -z "$SOURCE_WIDTH" || -z "$SOURCE_HEIGHT" ]]; then
  echo "Unable to inspect icon source: $SOURCE_PNG" >&2
  exit 1
fi
if [[ "$SOURCE_WIDTH" != "$SOURCE_HEIGHT" ]]; then
  echo "Icon source must be square: $SOURCE_PNG (${SOURCE_WIDTH}x${SOURCE_HEIGHT})" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
BASE_ICON="$(mktemp /tmp/opensnek-icon-XXXXXX.png)"
trap 'rm -f "$BASE_ICON"' EXIT

sips -s format png -z 1024 1024 "$SOURCE_PNG" --out "$BASE_ICON" >/dev/null

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

echo "Generated AppIcon set in: $OUTPUT_DIR"
