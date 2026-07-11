#!/usr/bin/env bash
# Convenience launcher (macOS): starts the server in the background, waits for
# the port to open, then runs the client in the foreground. Stops the server
# on exit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOST="${HOST:-127.0.0.1}"
export PORT="${PORT:-4040}"
CONFIG="${CONFIG:-release}"

[ "$(uname -s)" = "Darwin" ] || { echo "run.sh targets macOS. On other systems use ./run-server.sh." >&2; exit 1; }
command -v mix   >/dev/null 2>&1 || { echo "elixir/mix not found." >&2; exit 1; }
command -v swift >/dev/null 2>&1 || { echo "swift not found." >&2; exit 1; }

SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        echo ""
        echo "==> stopping server (pid $SERVER_PID)"
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "==> starting server on port $PORT"
( cd "$ROOT/server" && env PORT="$PORT" mix run --no-halt ) &
SERVER_PID=$!

# Wait for the port to accept connections (max ~20s) using bash /dev/tcp.
echo -n "==> waiting for server"
for _ in $(seq 1 40); do
    if bash -c "exec 3<>/dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
        echo " ready."
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo ""
        echo "server exited before opening the port." >&2
        exit 1
    fi
    echo -n "."
    sleep 0.5
done

echo "==> launching client (-c $CONFIG)"
( cd "$ROOT/client" && swift run -c "$CONFIG" )
