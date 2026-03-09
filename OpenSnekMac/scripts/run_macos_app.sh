#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Run Open Snek app bundle with TCC-friendly defaults.

Behavior:
- If the app bundle already exists, open it as-is (preserves code signature/TCC grants).
- Rebuild only when requested via --rebuild or when bundle is missing.

Usage:
  run_macos_app.sh [--rebuild] [--configuration <debug|release>] [--sign-identity <value>]

Options:
  --rebuild                       Force rebuild before opening
  --configuration <debug|release> Build configuration when rebuilding (default: debug)
  --sign-identity <value>         Passed through to build_macos_app.sh (default: auto)
  -h, --help                      Show this help
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$PACKAGE_DIR/.dist/Open Snek.app"

REBUILD=false
CONFIGURATION="debug"
SIGN_IDENTITY="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild)
      REBUILD=true
      shift
      ;;
    --configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --sign-identity)
      SIGN_IDENTITY="${2:-}"
      shift 2
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

if [[ "$REBUILD" == true || ! -d "$APP_BUNDLE" ]]; then
  "$SCRIPT_DIR/build_macos_app.sh" \
    --configuration "$CONFIGURATION" \
    --sign-identity "$SIGN_IDENTITY"
else
  echo "[open-snek] Using existing app bundle (no rebuild): $APP_BUNDLE"
fi

open "$APP_BUNDLE"
