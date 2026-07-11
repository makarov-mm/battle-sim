#!/usr/bin/env bash
# Builds (if needed) and launches the Swift/Metal client. macOS only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-release}"
export HOST="${HOST:-127.0.0.1}"
export PORT="${PORT:-4040}"

[ "$(uname -s)" = "Darwin" ] || { echo "Client requires macOS (Metal)." >&2; exit 1; }
command -v swift >/dev/null 2>&1 || { echo "swift not found. Install Xcode command line tools." >&2; exit 1; }

echo "==> Client -> ws://${HOST}:${PORT}/  (-c $CONFIG)"
cd "$ROOT/client"
exec swift run -c "$CONFIG"
