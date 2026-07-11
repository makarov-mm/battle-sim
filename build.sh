#!/usr/bin/env bash
# Builds both components. The Swift/Metal client only builds on macOS;
# on other systems the server still builds and the client step is skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warning:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m error:\033[0m %s\n' "$*" >&2; exit 1; }

# --- server (Elixir) ---
command -v mix >/dev/null 2>&1 || die "elixir/mix not found. Install Elixir 1.14+."

info "Building server (Elixir)..."
( cd server && MIX_ENV="${MIX_ENV:-dev}" mix compile )
info "Server built."

# --- client (Swift/Metal, macOS only) ---
if [ "$(uname -s)" != "Darwin" ]; then
    warn "Not macOS, skipping Swift/Metal client build (needs Metal)."
    info "Server is ready. Run ./run-server.sh"
    exit 0
fi

command -v swift >/dev/null 2>&1 || die "swift not found. Install Xcode command line tools."

CONFIG="${CONFIG:-release}"
info "Building client (Swift, -c $CONFIG)..."
( cd client && swift build -c "$CONFIG" )
info "Client built."

info "Done. Start everything with ./run.sh (or run server and client separately)."
