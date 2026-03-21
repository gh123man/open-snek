#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Generate OpenSnek.xcodeproj from project.yml, then forward arguments to xcodebuild.

Usage:
  xcodebuild_generated.sh <xcodebuild args...>
USAGE
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

"$SCRIPT_DIR/generate_xcodeproj.sh"
exec xcodebuild -project "$PACKAGE_DIR/OpenSnek.xcodeproj" "$@"
