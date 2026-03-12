#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build a signed macOS DMG for OpenSnek using Xcode archive/export.

Usage:
  build_release_dmg.sh [options]

Options:
  --version <semver>              Marketing version. Defaults to git tag without leading v, else 0.1.0.
  --build-number <value>          Bundle build number. Defaults to 1.
  --team-id <id>                  Apple Developer Team ID. Required for signed export.
  --sign-identity <value>         Developer ID Application identity. Defaults to auto-detect.
  --notary-key-path <path>        Path to App Store Connect API key (.p8).
  --notary-key-id <id>            App Store Connect API key ID.
  --notary-issuer-id <id>         App Store Connect issuer ID.
  --output-dir <dir>              Release output directory (default: OpenSnek/.release).
  --skip-notarize                 Skip app/DMG notarization and stapling.
  --skip-sign                     Skip release signing and notarization.
  -h, --help                      Show this help.

Environment overrides:
  OPEN_SNEK_RELEASE_VERSION
  OPEN_SNEK_RELEASE_BUILD_NUMBER
  OPEN_SNEK_APPLE_TEAM_ID
  OPEN_SNEK_RELEASE_SIGN_IDENTITY
  OPEN_SNEK_NOTARY_KEY_PATH
  OPEN_SNEK_NOTARY_KEY_ID
  OPEN_SNEK_NOTARY_ISSUER_ID
  OPEN_SNEK_CODESIGN_KEYCHAIN
USAGE
}

VERSION="${OPEN_SNEK_RELEASE_VERSION:-}"
BUILD_NUMBER="${OPEN_SNEK_RELEASE_BUILD_NUMBER:-1}"
APPLE_TEAM_ID="${OPEN_SNEK_APPLE_TEAM_ID:-}"
SIGN_IDENTITY="${OPEN_SNEK_RELEASE_SIGN_IDENTITY:-auto}"
NOTARY_KEY_PATH="${OPEN_SNEK_NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${OPEN_SNEK_NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${OPEN_SNEK_NOTARY_ISSUER_ID:-}"
OUTPUT_DIR=""
SKIP_NOTARIZE=false
SKIP_SIGN=false
CODE_SIGN_KEYCHAIN="${OPEN_SNEK_CODESIGN_KEYCHAIN:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --team-id)
      APPLE_TEAM_ID="${2:-}"
      shift 2
      ;;
    --sign-identity)
      SIGN_IDENTITY="${2:-}"
      shift 2
      ;;
    --notary-key-path)
      NOTARY_KEY_PATH="${2:-}"
      shift 2
      ;;
    --notary-key-id)
      NOTARY_KEY_ID="${2:-}"
      shift 2
      ;;
    --notary-issuer-id)
      NOTARY_ISSUER_ID="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --skip-notarize)
      SKIP_NOTARIZE=true
      shift
      ;;
    --skip-sign)
      SKIP_SIGN=true
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

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: $name" >&2
    exit 1
  fi
}

detect_version_from_git() {
  local tag
  tag="$(git -C "$PACKAGE_DIR/.." describe --tags --exact-match 2>/dev/null || true)"
  if [[ -n "$tag" ]]; then
    printf '%s\n' "${tag#v}"
  fi
}

detect_sign_identity() {
  local team_id="$1"
  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if [[ -z "$identities" ]]; then
    return 1
  fi

  local preferred=""
  if [[ -n "$team_id" ]]; then
    preferred="$(printf '%s\n' "$identities" | awk -F'"' -v team="($team_id)" '/"Developer ID Application:/{ if ($2 ~ team) { print $2; exit } }')"
  fi
  if [[ -z "$preferred" ]]; then
    preferred="$(printf '%s\n' "$identities" | awk -F'"' '/"Developer ID Application:/{print $2; exit}')"
  fi
  [[ -n "$preferred" ]] || return 1
  printf '%s\n' "$preferred"
}

require_notary_credentials() {
  [[ -n "$NOTARY_KEY_PATH" ]] || { echo "Missing notary key path" >&2; exit 1; }
  [[ -n "$NOTARY_KEY_ID" ]] || { echo "Missing notary key ID" >&2; exit 1; }
  [[ -n "$NOTARY_ISSUER_ID" ]] || { echo "Missing notary issuer ID" >&2; exit 1; }
  [[ -f "$NOTARY_KEY_PATH" ]] || { echo "Notary key not found: $NOTARY_KEY_PATH" >&2; exit 1; }
}

generate_export_options() {
  local template_path="$1"
  local out_path="$2"
  sed "s/__APPLE_TEAM_ID__/$APPLE_TEAM_ID/g" "$template_path" > "$out_path"
}

find_exported_app() {
  local export_dir="$1"
  find "$export_dir" -maxdepth 1 -type d -name '*.app' | head -n 1
}

notarize_path() {
  local target_path="$1"
  local log_path="$2"
  local submission_path="$target_path"
  if [[ -d "$target_path" && "$target_path" == *.app ]]; then
    submission_path="${log_path%.json}.zip"
    rm -f "$submission_path"
    ditto -c -k --sequesterRsrc --keepParent "$target_path" "$submission_path"
  fi

  xcrun notarytool submit "$submission_path" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait \
    --output-format json > "$log_path"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PACKAGE_DIR/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$PACKAGE_DIR/.release}"
VERSION="${VERSION:-$(detect_version_from_git)}"
VERSION="${VERSION:-0.1.0}"

require_cmd xcodebuild
require_cmd xcrun
require_cmd hdiutil
require_cmd codesign
require_cmd spctl
require_cmd xcodegen
require_cmd ditto
require_cmd npx
require_cmd swift

if [[ "$SKIP_SIGN" == true && "$SKIP_NOTARIZE" == false ]]; then
  echo "--skip-sign requires --skip-notarize" >&2
  exit 1
fi

if [[ "$SKIP_SIGN" == false && -z "$APPLE_TEAM_ID" ]]; then
  echo "Apple Team ID is required for release signing" >&2
  exit 1
fi

if [[ "$SKIP_NOTARIZE" == false ]]; then
  require_notary_credentials
fi

if [[ "$SIGN_IDENTITY" == "auto" && "$SKIP_SIGN" == false ]]; then
  if ! SIGN_IDENTITY="$(detect_sign_identity "$APPLE_TEAM_ID")"; then
    echo "Failed to detect a Developer ID Application signing identity" >&2
    exit 1
  fi
fi

ARCHIVE_DIR="$OUTPUT_DIR/archive"
EXPORT_DIR="$OUTPUT_DIR/export"
STAGE_DIR="$OUTPUT_DIR/dmg"
ARTIFACTS_DIR="$OUTPUT_DIR/artifacts"
LOG_DIR="$OUTPUT_DIR/logs"
ARCHIVE_PATH="$ARCHIVE_DIR/OpenSnek.xcarchive"
EXPORT_OPTIONS_TMP="$OUTPUT_DIR/ExportOptions.generated.plist"
APP_NAME="Open Snek.app"
DMG_NAME="OpenSnek-$VERSION.dmg"
DMG_PATH="$ARTIFACTS_DIR/$DMG_NAME"
VOLUME_NAME="OpenSnek"

rm -rf "$ARCHIVE_DIR" "$EXPORT_DIR" "$STAGE_DIR" "$ARTIFACTS_DIR" "$LOG_DIR" "$ARCHIVE_PATH" "$EXPORT_OPTIONS_TMP"
mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR" "$STAGE_DIR" "$ARTIFACTS_DIR" "$LOG_DIR"

echo "[open-snek] Generating Xcode project"
"$SCRIPT_DIR/generate_xcodeproj.sh"

generate_export_options "$PACKAGE_DIR/ci/ExportOptions-DeveloperID.plist" "$EXPORT_OPTIONS_TMP"

ARCHIVE_ARGS=(
  -project "$PACKAGE_DIR/OpenSnek.xcodeproj"
  -scheme OpenSnek
  -configuration Release
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)

if [[ "$SKIP_SIGN" == true ]]; then
  ARCHIVE_ARGS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="")
else
  ARCHIVE_ARGS+=(DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY")
  if [[ -n "$CODE_SIGN_KEYCHAIN" ]]; then
    ARCHIVE_ARGS+=(OTHER_CODE_SIGN_FLAGS="--keychain $CODE_SIGN_KEYCHAIN")
  fi
fi

echo "[open-snek] Archiving OpenSnek $VERSION ($BUILD_NUMBER)"
xcodebuild archive "${ARCHIVE_ARGS[@]}" | tee "$LOG_DIR/archive.log"

if [[ "$SKIP_SIGN" == true ]]; then
  ARCHIVE_APP_PATH="$(find_exported_app "$ARCHIVE_PATH/Products/Applications")"
  if [[ -z "$ARCHIVE_APP_PATH" ]]; then
    echo "Archived app not found in $ARCHIVE_PATH/Products/Applications" >&2
    exit 1
  fi
  APP_PATH="$EXPORT_DIR/$(basename "$ARCHIVE_APP_PATH")"
  echo "[open-snek] Collecting unsigned app bundle from archive products"
  ditto "$ARCHIVE_APP_PATH" "$APP_PATH"
else
  EXPORT_ARGS=(
    -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$EXPORT_DIR"
    -exportOptionsPlist "$EXPORT_OPTIONS_TMP"
  )

  echo "[open-snek] Exporting archive"
  xcodebuild "${EXPORT_ARGS[@]}" | tee "$LOG_DIR/export.log"

  APP_PATH="$(find_exported_app "$EXPORT_DIR")"
  if [[ -z "$APP_PATH" ]]; then
    echo "Exported app not found in $EXPORT_DIR" >&2
    exit 1
  fi
fi

if [[ "$SKIP_SIGN" == false ]]; then
  codesign --verify --deep --strict --verbose=2 "$APP_PATH" | tee "$LOG_DIR/app-codesign-verify.log"
fi

if [[ "$SKIP_NOTARIZE" == false ]]; then
  echo "[open-snek] Notarizing app bundle"
  notarize_path "$APP_PATH" "$LOG_DIR/notary-app.json"
  xcrun stapler staple "$APP_PATH" | tee "$LOG_DIR/staple-app.log"
  xcrun stapler validate "$APP_PATH" | tee "$LOG_DIR/staple-app-validate.log"
  spctl -a -vv --type exec "$APP_PATH" 2>&1 | tee "$LOG_DIR/app-spctl.log"
fi

cp -R "$APP_PATH" "$STAGE_DIR/$APP_NAME"
APP_ICON_SOURCE="$PACKAGE_DIR/Branding/AppIcon-master.png"
DMG_BACKGROUND="$OUTPUT_DIR/dmg-background.png"
DMG_BACKGROUND_RETINA="$OUTPUT_DIR/dmg-background@2x.png"
APPDMG_CONFIG="$OUTPUT_DIR/appdmg.json"
VOLUME_ICON="$APP_PATH/Contents/Resources/AppIcon.icns"

echo "[open-snek] Rendering DMG background"
swift "$SCRIPT_DIR/render_dmg_background.swift" \
  --output "$DMG_BACKGROUND" \
  --width 780 \
  --height 460 \
  --icon "$APP_ICON_SOURCE"

swift "$SCRIPT_DIR/render_dmg_background.swift" \
  --output "$DMG_BACKGROUND_RETINA" \
  --width 780 \
  --height 460 \
  --scale 2 \
  --icon "$APP_ICON_SOURCE"

cat > "$APPDMG_CONFIG" <<EOF
{
  "title": "$VOLUME_NAME",
  "icon": "$VOLUME_ICON",
  "background": "$DMG_BACKGROUND",
  "icon-size": 128,
  "format": "UDZO",
  "window": {
    "position": { "x": 160, "y": 120 },
    "size": { "width": 780, "height": 520 }
  },
  "contents": [
    { "x": 220, "y": 222, "type": "file", "path": "$STAGE_DIR/$APP_NAME" },
    { "x": 560, "y": 222, "type": "link", "path": "/Applications" }
  ]
}
EOF

echo "[open-snek] Building styled DMG $DMG_NAME"
npx --yes appdmg@0.6.6 "$APPDMG_CONFIG" "$DMG_PATH" | tee "$LOG_DIR/dmg-create.log"

if [[ "$SKIP_SIGN" == false ]]; then
  echo "[open-snek] Signing DMG with $SIGN_IDENTITY"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH" | tee "$LOG_DIR/dmg-codesign-verify.log"
fi

if [[ "$SKIP_NOTARIZE" == false ]]; then
  echo "[open-snek] Notarizing DMG"
  notarize_path "$DMG_PATH" "$LOG_DIR/notary-dmg.json"
  xcrun stapler staple "$DMG_PATH" | tee "$LOG_DIR/staple-dmg.log"
  xcrun stapler validate "$DMG_PATH" | tee "$LOG_DIR/staple-dmg-validate.log"
fi

echo "[open-snek] Release DMG ready: $DMG_PATH"
