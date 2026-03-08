#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build a local macOS .app bundle for OpenSnekMac.

Usage:
  build_macos_app.sh [options]

Options:
  --configuration <debug|release>   Build configuration (default: debug)
  --output <dir>                    Output directory for .app (default: OpenSnekMac/.dist)
  --bundle-id <id>                  CFBundleIdentifier (default: io.opensnek.OpenSnekMac)
  --version <semver>                CFBundleShortVersionString (default: 0.1.0)
  --build-number <value>            CFBundleVersion (default: timestamp)
  --icon <png-or-icns-path>         Optional app icon source
  --open                            Open app after build
  -h, --help                        Show this help

Environment overrides:
  OPEN_SNEK_BUNDLE_ID
  OPEN_SNEK_VERSION
  OPEN_SNEK_BUILD_NUMBER
  OPEN_SNEK_APP_ICON
USAGE
}

CONFIGURATION="debug"
OUTPUT_DIR=""
BUNDLE_ID="${OPEN_SNEK_BUNDLE_ID:-io.opensnek.OpenSnekMac}"
VERSION="${OPEN_SNEK_VERSION:-0.1.0}"
BUILD_NUMBER="${OPEN_SNEK_BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"
ICON_SOURCE="${OPEN_SNEK_APP_ICON:-}"
OPEN_AFTER_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --icon)
      ICON_SOURCE="${2:-}"
      shift 2
      ;;
    --open)
      OPEN_AFTER_BUILD=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  echo "Invalid configuration: $CONFIGURATION" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$PACKAGE_DIR/.dist}"
DEFAULT_ICON_PNG="$PACKAGE_DIR/App/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"

PRODUCT_NAME="OpenSnekMac"
DISPLAY_NAME="Open Snek"
APP_BUNDLE="$OUTPUT_DIR/$DISPLAY_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$OUTPUT_DIR/AppIcon.iconset"
ICON_FILE="$RESOURCES_DIR/AppIcon.icns"
SYSTEM_ICON_ICNS="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"

mkdir -p "$OUTPUT_DIR"

echo "[open-snek] Building $PRODUCT_NAME ($CONFIGURATION)..."
swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" --product "$PRODUCT_NAME"
BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" --show-bin-path)"
BIN_PATH="$BIN_DIR/$PRODUCT_NAME"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Build output missing executable: $BIN_PATH" >&2
  exit 1
fi

build_icns_from_png() {
  local src_png="$1"
  local dest_icns="$2"

  if ! command -v iconutil >/dev/null 2>&1 || ! command -v sips >/dev/null 2>&1; then
    echo "[open-snek] iconutil/sips unavailable; skipping icon generation"
    return 1
  fi

  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  sips -s format png -z 16 16 "$src_png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -s format png -z 32 32 "$src_png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -s format png -z 32 32 "$src_png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -s format png -z 64 64 "$src_png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -s format png -z 128 128 "$src_png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -s format png -z 256 256 "$src_png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -s format png -z 256 256 "$src_png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -s format png -z 512 512 "$src_png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -s format png -z 512 512 "$src_png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -s format png -z 1024 1024 "$src_png" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$ICONSET_DIR" -o "$dest_icns"
  return 0
}

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$PRODUCT_NAME"
chmod +x "$MACOS_DIR/$PRODUCT_NAME"

shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$RESOURCES_DIR/"
done
shopt -u nullglob

ICON_INPUT="$ICON_SOURCE"
if [[ -n "$ICON_INPUT" && ! -f "$ICON_INPUT" ]]; then
  echo "Icon source not found: $ICON_INPUT" >&2
  exit 1
fi

if [[ -z "$ICON_INPUT" ]]; then
  if [[ -f "$DEFAULT_ICON_PNG" ]]; then
    ICON_INPUT="$DEFAULT_ICON_PNG"
  fi
fi

if [[ -z "$ICON_INPUT" ]]; then
  if [[ -f "$SYSTEM_ICON_ICNS" ]]; then
    cp "$SYSTEM_ICON_ICNS" "$ICON_FILE"
  fi
elif [[ "$ICON_INPUT" == *.icns ]]; then
  cp "$ICON_INPUT" "$ICON_FILE"
elif [[ "$ICON_INPUT" == *.png ]]; then
  if ! build_icns_from_png "$ICON_INPUT" "$ICON_FILE"; then
    if [[ -f "$SYSTEM_ICON_ICNS" ]]; then
      cp "$SYSTEM_ICON_ICNS" "$ICON_FILE"
    fi
  fi
else
  echo "Unsupported icon format (use .png or .icns): $ICON_INPUT" >&2
  exit 1
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$PRODUCT_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Open Snek uses Bluetooth to discover and configure compatible Razer devices.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "[open-snek] App bundle ready: $APP_BUNDLE"

if $OPEN_AFTER_BUILD; then
  open "$APP_BUNDLE"
fi
