#!/usr/bin/env bash
# Exercise an on-demand signing key rotation for a trust domain deployment.
# Runbook: https://d.defakto.security/mint/operations/runbook-signing-key-rotation/
# Usage: rotate.sh <trust-domain> [deployment-name]   (deployment defaults to "default")
set -euo pipefail

cat <<'LOGO'
        ━━━━━━━━━━━━━━━━━
    ━━━━━━━━━━━━━━━━━━━━━━━
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
━━━━━━━━━━━        ━━━━━━━━━━━
━━━━━━━━━━━━          ━━━━━━━━━
━━━━━━━━━━━━          ━━━━━━━━━
━━━━━━━━━━━        ━━━━━━━━━━━
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ━━━━━━━━━━━━━━━━━━━━━━━
        ━━━━━━━━━━━━━━━━━

  Defakto · Signing Key Rotation
LOGO

TRUST_DOMAIN="${1:?usage: $0 <trust-domain> [deployment-name]}"
DEPLOYMENT_NAME="${2:-default}"
TDD=(--trust-domain "$TRUST_DOMAIN" --deployment-name "$DEPLOYMENT_NAME")

step()  { printf '\n\033[1;38;2;135;82;250m==> %s\033[0m\n' "$*"; }
pause() { read -rp "Press Enter to continue (Ctrl-C to abort)... " _; }
list()  { defakto trust-domain deployment keyset list "${TDD[@]}"; }

step "Step 2: Inspecting current keysets for $TRUST_DOMAIN/$DEPLOYMENT_NAME"
list
OLD_KEYSET_ID=$(list | awk '/ Active / { print $2; exit }')
[[ -n "$OLD_KEYSET_ID" ]] || { echo "No active keyset found" >&2; exit 1; }
echo "Active keyset: $OLD_KEYSET_ID"
pause

step "Step 3: Preparing a new keyset"
NEW_KEYSET_ID=$(defakto trust-domain deployment keyset prepare "${TDD[@]}" | tee /dev/stderr | awk '/prepared/ { print $2 }')
[[ -n "$NEW_KEYSET_ID" ]] || { echo "Could not parse new keyset ID" >&2; exit 1; }
list
pause

step "Step 4: Activating $NEW_KEYSET_ID"
defakto trust-domain deployment keyset activate "$NEW_KEYSET_ID" "${TDD[@]}"
list
echo "Expect $NEW_KEYSET_ID Active and $OLD_KEYSET_ID Prepared."
echo "Check every server replica logs 'Refreshed cached key ring' with no 'Failed to cache key ring'."
pause

step "Step 5: Tainting old keyset $OLD_KEYSET_ID"
defakto trust-domain deployment keyset taint "$OLD_KEYSET_ID" "${TDD[@]}"
list
pause

# Deliberately removes before the propagation wait (runbook order is taint -> wait -> remove)
# to exercise the verification-failure path: SVIDs still signed by the old keyset fail immediately.
step "Step 6: Removing old keyset $OLD_KEYSET_ID (permanent)"
defakto trust-domain deployment keyset remove "$OLD_KEYSET_ID" "${TDD[@]}"
list
pause

step "Step 7: Waiting 2 minutes for workloads to recover with SVIDs from $NEW_KEYSET_ID"
echo "Watch spirl_agent_mint_svid_total / spirl_server_mint_svid_total return to baseline."
sleep 120

step "Rotation complete: $NEW_KEYSET_ID is now the only active keyset"


