#!/usr/bin/env bash
# bootstrap.sh — set up the demo's dependencies with as little fuss as possible.
#
# It installs only the ONE dependency that is safe and specific to this demo:
# func-e (a single, self-contained binary placed in ./bin, used to run Envoy
# with no Docker and no system changes). For the standard toolchains (Go, a
# JDK) it only checks and points you at install instructions — it will not
# silently install language runtimes onto your machine.
#
# Safe to run repeatedly.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
info() { printf "  \033[36m•\033[0m %s\n" "$1"; }
miss() { printf "  \033[31m✗\033[0m %s\n" "$1"; }

echo "Bootstrapping the tls-handshake-reject demo…"
echo

# --- Envoy runtime: install func-e into ./bin if nothing suitable exists ------
if [ -x ./bin/func-e ]; then
  ok "Envoy: ./bin/func-e already installed"
elif command -v func-e >/dev/null 2>&1; then
  ok "Envoy: func-e found on PATH ($(func-e --version 2>/dev/null))"
elif command -v envoy >/dev/null 2>&1; then
  ok "Envoy: an 'envoy' binary is already on PATH"
else
  info "Envoy: installing func-e into ./bin (single binary, no Docker)…"
  mkdir -p bin
  if curl -fsSL https://func-e.io/install.sh | bash -s -- -b ./bin >/dev/null 2>&1 && [ -x ./bin/func-e ]; then
    ok "Envoy: installed ./bin/func-e"
  else
    miss "Envoy: automatic func-e install failed. Install manually:"
    echo "        curl -fsSL https://func-e.io/install.sh | bash -s -- -b ./bin"
  fi
fi

# --- Go: required, but do not auto-install a language runtime -----------------
if command -v go >/dev/null 2>&1; then
  ok "Go:   $(go version | awk '{print $3}')"
else
  miss "Go:   MISSING (required for certs + client) — install from https://go.dev/dl/"
fi

# --- JDK: only for the Java examples ------------------------------------------
# (macOS has a /usr/bin/java stub even without a JDK, so test it actually runs.)
if java -version >/dev/null 2>&1; then
  ok "Java: $(java -version 2>&1 | head -1)"
else
  miss "Java: MISSING (only needed for the Java examples) — install a JDK 17+ from https://adoptium.net"
fi

echo
echo "Done. Run the demo with:  scripts/demo.sh all"
