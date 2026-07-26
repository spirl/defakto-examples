#!/usr/bin/env bash
# preflight.sh — report which toolchains are present and what each example needs.
# Nothing here installs anything; it just tells you what to install.
set -uo pipefail

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
miss() { printf "  \033[31m✗\033[0m %s\n" "$1"; }

echo "Toolchain check for the tls-handshake-reject demo"
echo

echo "Core (needed to generate certs + run the client):"
if command -v go >/dev/null 2>&1; then ok "go        $(go version | awk '{print $3}')"
else miss "go        MISSING — install from https://go.dev/dl/ (needed for certs + client)"; fi
echo

echo "For the Java examples:"
# macOS has a /usr/bin/java stub even without a JDK, so test it actually runs.
if java -version >/dev/null 2>&1; then ok "java      $(java -version 2>&1 | head -1)"
else miss "java      MISSING — install a JDK 17+ (e.g. https://adoptium.net). The Maven wrapper (./mvnw) handles Maven itself."; fi
echo

echo "For the Envoy examples (need ONE of these):"
if [ -x "$(dirname "$0")/../bin/func-e" ]; then ok "func-e    ./bin/func-e (project-local)"
elif command -v func-e >/dev/null 2>&1; then ok "func-e    $(func-e --version)"
elif command -v envoy >/dev/null 2>&1; then ok "envoy     $(envoy --version 2>&1 | head -1)"
else
  miss "func-e/envoy MISSING — easiest: curl -fsSL https://func-e.io/install.sh | bash -s -- -b ./bin"
  echo "                (func-e downloads the correct Envoy build on first run; no Docker needed)"
fi
echo
echo "Run a single example end-to-end with:  scripts/demo.sh <example>"
echo "  examples: go-spiffe go-custom java-spiffe java-custom envoy-static   (or: all)"
