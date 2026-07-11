#!/usr/bin/env bash
# Starts the Elixir simulation + WebSocket server (ws://127.0.0.1:PORT/).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-4040}"

command -v mix >/dev/null 2>&1 || { echo "elixir/mix not found. Install Elixir 1.14+." >&2; exit 1; }

echo "==> Battlefield server on ws://127.0.0.1:${PORT}/  (Ctrl-C twice to stop)"
cd "$ROOT/server"
exec env PORT="$PORT" mix run --no-halt
