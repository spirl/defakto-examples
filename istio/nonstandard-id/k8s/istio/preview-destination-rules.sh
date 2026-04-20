#!/usr/bin/env bash
set -e

export TRUST_DOMAIN="${TRUST_DOMAIN:-defakto.example.com}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo "DestinationRules Preview (dry run)"
echo "========================================"
echo ""
echo "Trust Domain: ${TRUST_DOMAIN}"
echo ""

echo "WHY these are needed:"
echo ""
echo "  Istio hardcodes SAN validation to match exactly:"
echo "    spiffe://<td>/ns/<ns>/sa/<sa>"
echo ""
echo "  But Defakto issues certs with a nonstandard path template:"
echo "    spiffe://<td>/ns/<ns>/sa/<sa>/wl/<app>"
echo ""
echo "  Without DestinationRules, Envoy's outbound mTLS rejects the"
echo "  server cert because the SAN has the unexpected /wl/<app> suffix."
echo "  (istio/istio#43105)"
echo ""

echo "WHAT will be applied:"
echo ""
echo "  For each bookinfo service, a DestinationRule overrides the"
echo "  default SAN validation with the actual nonstandard SPIFFE ID."
echo "  mode: ISTIO_MUTUAL preserves Istio-managed mTLS."
echo ""

for svc in details productpage reviews ratings; do
  echo "  ${svc}-nonstandard-id:"
  echo "    host: ${svc}"
  echo "    tls.mode: ISTIO_MUTUAL"
  echo "    subjectAltNames:"
  echo "      - spiffe://${TRUST_DOMAIN}/ns/bookinfo/sa/bookinfo-${svc}/wl/${svc}"
  echo ""
done

echo "HOW to apply:"
echo ""
echo "  Option A — wrapper script (expands \$TRUST_DOMAIN and applies):"
echo ""
echo "    ./k8s/istio/apply-destination-rules.sh"
echo ""
echo "  Option B — equivalent kubectl command:"
echo ""
echo "    export TRUST_DOMAIN=\"${TRUST_DOMAIN}\""
echo "    envsubst '\$TRUST_DOMAIN' < k8s/istio/destination-rules-template.yaml | kubectl apply -f -"
echo ""
echo "  (or trigger the 'apply-destination-rules' resource in Tilt)"
echo ""

echo "FULL RENDERED YAML:"
echo ""
envsubst '$TRUST_DOMAIN' < "${SCRIPT_DIR}/destination-rules-template.yaml"
