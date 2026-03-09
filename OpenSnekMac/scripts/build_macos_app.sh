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
  --build-number <value>            CFBundleVersion (default: 1)
  --icon <png-or-icns-path>         Optional app icon source
  --sign-identity <value>           Signing identity: auto|preserve|adhoc|none|<codesign identity>
  --open                            Open app after build
  -h, --help                        Show this help

Environment overrides:
  OPEN_SNEK_BUNDLE_ID
  OPEN_SNEK_VERSION
  OPEN_SNEK_BUILD_NUMBER
  OPEN_SNEK_APP_ICON
  OPEN_SNEK_SIGN_IDENTITY
USAGE
}

CONFIGURATION="debug"
OUTPUT_DIR=""
BUNDLE_ID="${OPEN_SNEK_BUNDLE_ID:-io.opensnek.OpenSnekMac}"
VERSION="${OPEN_SNEK_VERSION:-0.1.0}"
BUILD_NUMBER="${OPEN_SNEK_BUILD_NUMBER:-1}"
ICON_SOURCE="${OPEN_SNEK_APP_ICON:-}"
SIGN_IDENTITY="${OPEN_SNEK_SIGN_IDENTITY:-auto}"
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
    --sign-identity)
      SIGN_IDENTITY="${2:-}"
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

detect_preferred_sign_identity() {
  if ! command -v security >/dev/null 2>&1; then
    return 1
  fi

  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if [[ -z "$identities" ]]; then
    return 1
  fi

  local preferred
  preferred="$(printf '%s\n' "$identities" | awk -F'"' '/"Apple Development:/{print $2; exit}')"
  if [[ -z "$preferred" ]]; then
    preferred="$(printf '%s\n' "$identities" | awk -F'"' '/"Developer ID Application:/{print $2; exit}')"
  fi
  if [[ -z "$preferred" ]]; then
    return 1
  fi

  printf '%s\n' "$preferred"
  return 0
}

detect_existing_sign_identity() {
  local app_bundle="$1"
  [[ -d "$app_bundle" ]] || return 1
  local details
  details="$(codesign -dv --verbose=4 "$app_bundle" 2>&1 || true)"
  [[ -n "$details" ]] || return 1

  if printf '%s\n' "$details" | grep -q '^Signature=adhoc$'; then
    printf '%s\n' "adhoc"
    return 0
  fi

  local authority
  authority="$(printf '%s\n' "$details" | awk -F= '/^Authority=/{print $2; exit}')"
  [[ -n "$authority" ]] || return 1
  printf '%s\n' "$authority"
  return 0
}

resolve_sign_identity() {
  local requested="$1"
  local existing="$2"

  case "$requested" in
    preserve)
      if [[ -n "$existing" ]]; then
        printf '%s\n' "$existing"
      else
        printf '%s\n' "auto"
      fi
      ;;
    auto)
      if [[ -n "$existing" && "$existing" != "adhoc" ]]; then
        printf '%s\n' "$existing"
      else
        printf '%s\n' "auto"
      fi
      ;;
    *)
      printf '%s\n' "$requested"
      ;;
  esac
}

EXISTING_SIGN_IDENTITY=""
if [[ -d "$APP_BUNDLE" ]]; then
  EXISTING_SIGN_IDENTITY="$(detect_existing_sign_identity "$APP_BUNDLE" || true)"
fi
RESOLVED_SIGN_IDENTITY="$(resolve_sign_identity "$SIGN_IDENTITY" "$EXISTING_SIGN_IDENTITY")"
if [[ "$SIGN_IDENTITY" == "preserve" ]]; then
  if [[ -n "$EXISTING_SIGN_IDENTITY" ]]; then
    echo "[open-snek] Reusing existing signing identity: $EXISTING_SIGN_IDENTITY"
  else
    echo "[open-snek] No prior app signature found; falling back to auto signing"
  fi
fi
if [[ "$SIGN_IDENTITY" == "auto" && -n "$EXISTING_SIGN_IDENTITY" && "$EXISTING_SIGN_IDENTITY" != "adhoc" ]]; then
  echo "[open-snek] Auto mode reusing existing signing identity: $EXISTING_SIGN_IDENTITY"
fi
if [[ "$SIGN_IDENTITY" == "auto" && "$EXISTING_SIGN_IDENTITY" == "adhoc" ]]; then
  echo "[open-snek] Existing app is ad-hoc signed; auto mode will try a real signing identity for stable TCC grants"
fi

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
  ADHOC_REQ="=designated => identifier \"$BUNDLE_ID\""
  sign_adhoc() {
    if codesign --force --deep --sign - --requirements "$ADHOC_REQ" "$APP_BUNDLE" >/dev/null 2>&1; then
      echo "[open-snek] Signed app with ad-hoc identity (stable designated requirement: identifier \"$BUNDLE_ID\")"
      echo "[open-snek] If HID remains blocked after this build, run once: tccutil reset ListenEvent $BUNDLE_ID"
      return 0
    fi
    if codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1; then
      echo "[open-snek] Signed app with ad-hoc identity"
      echo "[open-snek] Warning: stable designated requirement could not be applied; Input Monitoring grants may not survive rebuilds."
      echo "[open-snek] If HID remains blocked, run: tccutil reset ListenEvent $BUNDLE_ID"
      return 0
    fi
    return 1
  }

  case "$RESOLVED_SIGN_IDENTITY" in
    none)
      echo "[open-snek] Skipping codesign (sign identity: none)"
      ;;
    adhoc|-)
      if sign_adhoc; then
        :
      else
        echo "[open-snek] Warning: ad-hoc codesign failed"
      fi
      ;;
    auto)
      if detected_identity="$(detect_preferred_sign_identity)"; then
        if codesign --force --deep --sign "$detected_identity" "$APP_BUNDLE" >/dev/null 2>&1; then
          echo "[open-snek] Signed app with detected identity: $detected_identity"
        else
          echo "[open-snek] Warning: signing with detected identity failed; falling back to ad-hoc"
          if sign_adhoc; then
            :
          else
            echo "[open-snek] Warning: ad-hoc codesign failed"
          fi
        fi
      else
        echo "[open-snek] No signing identity detected; using ad-hoc signature"
        if sign_adhoc; then
          :
        else
          echo "[open-snek] Warning: ad-hoc codesign failed"
        fi
      fi
      ;;
    *)
      if codesign --force --deep --sign "$RESOLVED_SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null 2>&1; then
        echo "[open-snek] Signed app with requested identity: $RESOLVED_SIGN_IDENTITY"
      else
        echo "[open-snek] Error: codesign failed for identity: $RESOLVED_SIGN_IDENTITY" >&2
        exit 1
      fi
      ;;
  esac
fi

echo "[open-snek] App bundle ready: $APP_BUNDLE"

if $OPEN_AFTER_BUILD; then
  open "$APP_BUNDLE"
fi
