#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Build and launch Open Snek from the repo root.

Usage:
  ./run.sh [--no-build]

Options:
  --no-build    Launch the existing app bundle without rebuilding
  -h, --help    Show this help
USAGE
}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 1
fi

case "${1:-}" in
  "")
    exec "$SCRIPT_DIR/OpenSnek/scripts/run_macos_app.sh" --rebuild
    ;;
  --no-build)
    exec "$SCRIPT_DIR/OpenSnek/scripts/run_macos_app.sh"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    usage >&2
    exit 1
    ;;
esac
