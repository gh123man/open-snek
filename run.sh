#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Build and launch OpenSnek from the repo root.

Usage:
  ./run.sh [--no-build]

Options:
  --no-build    Launch the existing app bundle without rebuilding
  -h, --help    Show this help
USAGE
}

terminate_existing_opensnek() {
  if ! pgrep -x OpenSnek >/dev/null 2>&1; then
    return
  fi

  echo "[open-snek] Requesting OpenSnek quit"
  osascript -e 'tell application id "io.opensnek.OpenSnek" to quit' >/dev/null 2>&1 || true

  for _ in {1..20}; do
    if ! pgrep -x OpenSnek >/dev/null 2>&1; then
      return
    fi
    sleep 0.1
  done

  echo "[open-snek] Stopping existing OpenSnek processes"
  pkill -x OpenSnek >/dev/null 2>&1 || true

  for _ in {1..20}; do
    if ! pgrep -x OpenSnek >/dev/null 2>&1; then
      return
    fi
    sleep 0.1
  done

  echo "[open-snek] Forcing OpenSnek shutdown"
  pkill -9 -x OpenSnek >/dev/null 2>&1 || true
}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 1
fi

case "${1:-}" in
  "")
    terminate_existing_opensnek
    exec "$SCRIPT_DIR/OpenSnek/scripts/run_macos_app.sh" --rebuild
    ;;
  --no-build)
    terminate_existing_opensnek
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
