#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build a local macOS .app bundle for OpenSnek.

This uses the canonical Xcode app target, then copies the built app into
`OpenSnek/.dist/OpenSnek.app` so local launches can reuse a stable bundle path
for TCC/Input Monitoring.

Usage:
  build_macos_app.sh [options]

Options:
  --configuration <debug|release>   Build configuration (default: debug)
  --output <dir>                    Output directory for .app (default: OpenSnek/.dist)
  --bundle-id <id>                  CFBundleIdentifier override (default: io.opensnek.OpenSnek)
  --version <semver>                CFBundleShortVersionString override (default: project setting)
  --build-number <value>            CFBundleVersion override (default: 1)
  --build-channel <dev|release>     OpenSnek build channel metadata (default: derived from configuration)
  --sign-identity <value>           Signing identity: auto|preserve|adhoc|none|<codesign identity>
  --open                            Open app after build
  -h, --help                        Show this help

Environment overrides:
  OPEN_SNEK_BUNDLE_ID
  OPEN_SNEK_VERSION
  OPEN_SNEK_BUILD_NUMBER
  OPEN_SNEK_BUILD_CHANNEL
  OPEN_SNEK_SIGN_IDENTITY
USAGE
}

CONFIGURATION="debug"
OUTPUT_DIR=""
BUNDLE_ID="${OPEN_SNEK_BUNDLE_ID:-io.opensnek.OpenSnek}"
VERSION="${OPEN_SNEK_VERSION:-}"
BUILD_NUMBER="${OPEN_SNEK_BUILD_NUMBER:-1}"
BUILD_CHANNEL="${OPEN_SNEK_BUILD_CHANNEL:-}"
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
    --build-channel)
      BUILD_CHANNEL="${2:-}"
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

if [[ -z "$BUILD_CHANNEL" ]]; then
  if [[ "$CONFIGURATION" == "debug" ]]; then
    BUILD_CHANNEL="dev"
  else
    BUILD_CHANNEL="release"
  fi
fi

if [[ "$BUILD_CHANNEL" != "dev" && "$BUILD_CHANNEL" != "release" ]]; then
  echo "Invalid build channel: $BUILD_CHANNEL" >&2
  exit 1
fi

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: $name" >&2
    exit 1
  fi
}

detect_project_marketing_version() {
  local spec_file="$1"
  awk '/MARKETING_VERSION:/{print $2; exit}' "$spec_file"
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
}

identity_is_available() {
  local requested="$1"
  [[ -n "$requested" ]] || return 1
  [[ "$requested" == "adhoc" || "$requested" == "-" ]] && return 0
  [[ "$requested" == "none" || "$requested" == "auto" || "$requested" == "preserve" ]] && return 1
  command -v security >/dev/null 2>&1 || return 1

  security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/{print $2}' | grep -Fx -- "$requested" >/dev/null 2>&1
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
      if [[ -n "$existing" ]] && { [[ "$existing" == "adhoc" || "$existing" == "-" ]] || identity_is_available "$existing"; }; then
        printf '%s\n' "$existing"
      else
        printf '%s\n' "auto"
      fi
      ;;
    auto)
      if [[ -n "$existing" && "$existing" != "adhoc" && "$existing" != "-" ]] && identity_is_available "$existing"; then
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$PACKAGE_DIR/.dist}"
PROJECT_FILE="$PACKAGE_DIR/OpenSnek.xcodeproj"
SPEC_FILE="$PACKAGE_DIR/project.yml"
PRODUCT_NAME="OpenSnek"
DISPLAY_NAME="OpenSnek"
APP_BUNDLE="$OUTPUT_DIR/$DISPLAY_NAME.app"
DERIVED_DATA_PATH="$OUTPUT_DIR/.derived-data"

require_cmd xcodebuild
require_cmd ditto

if [[ -z "$VERSION" ]]; then
  VERSION="$(detect_project_marketing_version "$SPEC_FILE")"
fi
VERSION="${VERSION:-0.1.0}"

mkdir -p "$OUTPUT_DIR"

EXISTING_SIGN_IDENTITY=""
if [[ -d "$APP_BUNDLE" ]]; then
  EXISTING_SIGN_IDENTITY="$(detect_existing_sign_identity "$APP_BUNDLE" || true)"
fi
RESOLVED_SIGN_IDENTITY="$(resolve_sign_identity "$SIGN_IDENTITY" "$EXISTING_SIGN_IDENTITY")"

if [[ "$SIGN_IDENTITY" == "preserve" ]]; then
  if [[ -n "$EXISTING_SIGN_IDENTITY" ]]; then
    if [[ "$RESOLVED_SIGN_IDENTITY" == "$EXISTING_SIGN_IDENTITY" ]]; then
      echo "[open-snek] Reusing existing signing identity: $EXISTING_SIGN_IDENTITY"
    else
      echo "[open-snek] Existing signing identity unavailable; falling back to auto signing"
    fi
  else
    echo "[open-snek] No prior app signature found; falling back to auto signing"
  fi
fi
if [[ "$SIGN_IDENTITY" == "auto" && -n "$EXISTING_SIGN_IDENTITY" && "$EXISTING_SIGN_IDENTITY" != "adhoc" ]]; then
  if [[ "$RESOLVED_SIGN_IDENTITY" == "$EXISTING_SIGN_IDENTITY" ]]; then
    echo "[open-snek] Auto mode reusing existing signing identity: $EXISTING_SIGN_IDENTITY"
  else
    echo "[open-snek] Existing signing identity unavailable; auto mode will detect another identity or use ad-hoc signing"
  fi
fi
if [[ "$SIGN_IDENTITY" == "auto" && "$EXISTING_SIGN_IDENTITY" == "adhoc" ]]; then
  echo "[open-snek] Existing app is ad-hoc signed; auto mode will try a real signing identity for stable TCC grants"
fi

XCODE_CONFIGURATION="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIGURATION:0:1}")${CONFIGURATION:1}"

echo "[open-snek] Building $PRODUCT_NAME ($CONFIGURATION) via Xcode target..."
rm -rf "$DERIVED_DATA_PATH"
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme OpenSnek \
  -configuration "$XCODE_CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  OPEN_SNEK_BUILD_CHANNEL="$BUILD_CHANNEL" >/tmp/open_snek_xcodebuild.log

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$XCODE_CONFIGURATION/OpenSnek.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Built app not found: $BUILT_APP" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
ditto "$BUILT_APP" "$APP_BUNDLE"

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
