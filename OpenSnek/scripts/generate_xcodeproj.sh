#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_FILE="$PROJECT_DIR/project.yml"
PROJECT_FILE="$PROJECT_DIR/OpenSnek.xcodeproj"
OPEN_AFTER=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --open)
      OPEN_AFTER=true
      shift
      ;;
    -h|--help)
      cat <<'USAGE'
Generate OpenSnek.xcodeproj from project.yml.

Usage:
  generate_xcodeproj.sh [--open]
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install with: brew install xcodegen" >&2
  exit 1
fi

rm -rf "$PROJECT_FILE"
xcodegen generate --spec "$SPEC_FILE" --project "$PROJECT_DIR"
echo "Generated (gitignored): $PROJECT_FILE"

if $OPEN_AFTER; then
  open "$PROJECT_FILE"
fi
