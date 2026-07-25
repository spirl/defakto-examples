#!/usr/bin/env bash
# demo.sh — run one (or all) of the five examples end-to-end:
#   builds what's needed, starts the server, calls it once as the ALLOWED
#   (prod) client and once as the DENIED (dev) client, prints the server log,
#   then stops the server.
#
# If a required dependency is missing it stops UP FRONT (before building or
# starting anything), tells you everything that's missing, and offers to
# install the one safe/demo-specific piece (func-e) for you. You do not have to
# have run scripts/bootstrap.sh first — this notices and guides you either way.
#
# Usage:
#   scripts/demo.sh <example>
#   examples: go-spiffe go-custom java-spiffe java-custom envoy-static
#             all
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p logs

BOLD=$'\033[1m'; DIM=$'\033[2m'; RST=$'\033[0m'
hr() { printf "%s\n" "────────────────────────────────────────────────────────────────────────"; }

ALL_EXAMPLES="go-spiffe go-custom java-spiffe java-custom envoy-static"

find_envoy() {
  if [ -x "$ROOT/bin/func-e" ]; then echo "$ROOT/bin/func-e run -c"; return; fi
  if command -v func-e >/dev/null 2>&1; then echo "func-e run -c"; return; fi
  if command -v envoy  >/dev/null 2>&1; then echo "envoy -c"; return; fi
  echo ""  # not found
}
have_envoy() { [ -n "$(find_envoy)" ]; }
# NOTE: macOS ships a /usr/bin/java stub that is always on PATH even with no JDK
# installed, so `command -v java` gives a false positive. Check it actually runs.
have_java()  { java -version >/dev/null 2>&1; }

# missing_deps <targets...> — echo the space-separated set of missing tools
# (go / java / envoy) needed by the given examples.
missing_deps() {
  local need_java=0 need_envoy=0 t
  for t in "$@"; do
    case "$t" in java-*) need_java=1 ;; envoy-*) need_envoy=1 ;; esac
  done
  local m=""
  command -v go >/dev/null 2>&1 || m="$m go"
  if [ $need_java -eq 1 ] && ! have_java; then m="$m java"; fi
  if [ $need_envoy -eq 1 ] && ! have_envoy; then m="$m envoy"; fi
  echo "$m"
}

# ensure_deps <original-target> <targets...> — gate on dependencies before doing
# any work. Offers to auto-install func-e; instructs for the rest; exits if unmet.
ensure_deps() {
  local orig="$1"; shift
  local targets=("$@")
  local missing; missing="$(missing_deps "${targets[@]}")"
  [ -z "$missing" ] && return 0

  echo "${BOLD}Hold on — some dependencies aren't set up yet:${RST}"
  local m
  for m in $missing; do
    case "$m" in
      go)    echo "  ✗ go     — required (generates certs + builds the client). Install: https://go.dev/dl/" ;;
      java)  echo "  ✗ java   — needed for the Java examples. Install a JDK 17+: https://adoptium.net (Maven not needed; ./mvnw handles it)" ;;
      envoy) echo "  ✗ func-e — needed for the Envoy examples. A single binary; no Docker required." ;;
    esac
  done
  echo

  # Auto-fix the one safe, demo-specific dependency: func-e.
  if printf '%s' " $missing " | grep -q ' envoy '; then
    if [ -t 0 ]; then
      printf "func-e can be installed for you into ./bin now. Install it? [Y/n] "
      local ans; read -r ans || ans="n"
      case "${ans:-Y}" in
        [Nn]*) echo "Skipping func-e install." ;;
        *)     "$ROOT/scripts/bootstrap.sh" ;;
      esac
      echo
    else
      echo "${DIM}(non-interactive shell; not auto-installing. Run scripts/bootstrap.sh to install func-e.)${RST}"
    fi
  fi

  # Re-check after any auto-install. Go and a JDK are never auto-installed.
  missing="$(missing_deps "${targets[@]}")"
  if [ -n "$missing" ]; then
    echo "${BOLD}Still missing:${RST}$missing"
    echo "Install the item(s) above (or run ${BOLD}scripts/bootstrap.sh${RST}), then re-run:"
    echo "    scripts/demo.sh $orig"
    exit 1
  fi
  echo "${DIM}All dependencies ready — continuing.${RST}"; echo
}

ensure_certs() {
  if [ ! -f certs/ca.crt ]; then
    echo "${DIM}generating certs (go run ./common/certgen)…${RST}"
    go run ./common/certgen >/dev/null
  fi
}

ensure_client() {
  if [ ! -x bin/client ]; then
    echo "${DIM}building client…${RST}"
    go build -o bin/client ./common/client
  fi
}

ensure_java_jar() {
  if [ ! -f java-server/target/java-server.jar ]; then
    echo "${DIM}building Java server (./mvnw package)…${RST}"
    (cd java-server && ./mvnw -q -DskipTests package)
  fi
}

# call_client <port> <allowed|denied>
call_client() {
  local port="$1" id="$2"
  echo "${BOLD}→ client as '${id}':${RST}"
  ./bin/client -addr "localhost:${port}" -id "$id" 2>&1 | sed 's/^/    /'
  echo
}

# run_one <name> — assumes dependencies were already verified by ensure_deps.
run_one() {
  local name="$1" port cmd ready
  case "$name" in
    go-spiffe)    port=8443; ready="listening";                   go build -o bin/go-spiffe ./go-server/config-based; cmd="./bin/go-spiffe" ;;
    go-custom)    port=8444; ready="listening";                   go build -o bin/go-custom ./go-server/custom;        cmd="./bin/go-custom" ;;
    java-spiffe)  port=8445; ready="listening";                   ensure_java_jar; cmd="java -cp java-server/target/java-server.jar com.example.SpiffeLibServer" ;;
    java-custom)  port=8446; ready="listening";                   ensure_java_jar; cmd="java -cp java-server/target/java-server.jar com.example.CustomTrustManagerServer" ;;
    envoy-static) port=8447; ready="starting main dispatch loop"; cmd="$(find_envoy) envoy/static-san/envoy.yaml" ;;
  esac

  ensure_certs; ensure_client

  local log="logs/${name}.log"
  hr; echo "${BOLD}EXAMPLE: ${name}   (https://localhost:${port})${RST}"; hr
  echo "${DIM}starting server: ${cmd}${RST}"
  echo "${DIM}server log: ${log}${RST}"; echo

  # shellcheck disable=SC2086
  $cmd >"$log" 2>&1 &
  local pid=$!
  trap 'kill '"$pid"' 2>/dev/null' RETURN

  local i
  for i in $(seq 1 60); do
    grep -q "$ready" "$log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || { echo "server exited early; log:"; cat "$log"; return 1; }
    sleep 0.5
  done
  sleep 0.5

  call_client "$port" allowed
  call_client "$port" denied

  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  trap - RETURN

  echo "${BOLD}Server-side log (${log}) — note it names the exact rejected SPIFFE ID:${RST}"
  grep -E "ALLOW|DENY|listening|script log|GET / " "$log" | sed 's/^/    /' || tail -n 12 "$log" | sed 's/^/    /'
  echo
}

# ---- entrypoint --------------------------------------------------------------
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "usage: scripts/demo.sh <example>"
  echo "  examples: $ALL_EXAMPLES   (or: all)"
  exit 2
fi

if [ "$TARGET" = "all" ]; then
  # shellcheck disable=SC2206
  TARGETS=($ALL_EXAMPLES)
else
  case " $ALL_EXAMPLES " in
    *" $TARGET "*) TARGETS=("$TARGET") ;;
    *) echo "unknown example: $TARGET"; echo "  choose from: $ALL_EXAMPLES   (or: all)"; exit 2 ;;
  esac
fi

ensure_deps "$TARGET" "${TARGETS[@]}"

for n in "${TARGETS[@]}"; do
  run_one "$n"
done
