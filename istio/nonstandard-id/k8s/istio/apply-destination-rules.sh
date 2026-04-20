#!/usr/bin/env bash
set -e

export TRUST_DOMAIN="${TRUST_DOMAIN:-defakto.example.com}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo "Applying DestinationRules"
echo "========================================"
echo ""
echo "Trust Domain: ${TRUST_DOMAIN}"
echo ""
echo "This fixes the nonstandard SPIFFE ID SAN validation issue:"
echo "  istio/istio#43105"
echo ""

# Expand only ${TRUST_DOMAIN} in the template (leave other $ patterns untouched)
envsubst '$TRUST_DOMAIN' < "${SCRIPT_DIR}/destination-rules-template.yaml" | kubectl apply -f -

echo ""
echo "✓ DestinationRules applied"
echo ""
echo "Services now accept nonstandard SPIFFE IDs:"
for svc in details productpage reviews ratings; do
  echo "  spiffe://${TRUST_DOMAIN}/ns/bookinfo/sa/bookinfo-${svc}/wl/${svc}"
done
echo ""
echo "Run ./verify-nonstandard-id.sh to confirm mTLS is working"
