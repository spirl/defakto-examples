#!/usr/bin/env bash
set -e

TRUST_DOMAIN="${TRUST_DOMAIN:-defakto.example.com}"
PASS=true

echo "================================================"
echo "Verify Nonstandard SPIFFE ID mTLS"
echo "================================================"
echo ""
echo "Trust Domain: ${TRUST_DOMAIN}"
echo ""

# Prerequisite check
if ! kubectl get namespace bookinfo &>/dev/null; then
    echo "ERROR: bookinfo namespace not found — is the demo running?"
    exit 1
fi

# Step 1: Verify SPIFFE IDs in pod certificates
echo "Step 1: Checking SPIFFE IDs in pod certificates"
echo ""
for svc in productpage details reviews ratings; do
  POD=$(kubectl get pod -n bookinfo -l app=${svc} \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -z "$POD" ]; then
    echo "  ✗ No pod found for app=${svc}"
    PASS=false
    continue
  fi

  SPIFFE_ID=$(kubectl exec -n bookinfo "${POD}" -c istio-proxy -- \
    pilot-agent request GET certs 2>/dev/null | \
    jq -r '.certificates[0].cert_chain[0].subject_alt_names[0].uri // "N/A"' \
    2>/dev/null || echo "N/A")

  EXPECTED="spiffe://${TRUST_DOMAIN}/ns/bookinfo/sa/bookinfo-${svc}/wl/${svc}"
  if [ "$SPIFFE_ID" = "$EXPECTED" ]; then
    echo "  ✓ ${svc}: ${SPIFFE_ID}"
  else
    echo "  ✗ ${svc}: got '${SPIFFE_ID}'"
    echo "         want '${EXPECTED}'"
    if [[ "$SPIFFE_ID" == *"cluster.local"* ]]; then
      echo "         (pod is still using Istio CA — restart after spirlctl cluster add)"
    fi
    PASS=false
  fi
done
echo ""

# Step 2: Verify DestinationRules
echo "Step 2: Checking DestinationRules"
echo ""
for svc in details productpage reviews ratings; do
  if kubectl get destinationrule "${svc}-nonstandard-id" -n bookinfo &>/dev/null; then
    echo "  ✓ ${svc}-nonstandard-id"
  else
    echo "  ✗ ${svc}-nonstandard-id — NOT found"
    echo "    Run: ./k8s/istio/apply-destination-rules.sh"
    PASS=false
  fi
done
echo ""

# Step 3: mTLS connectivity test via Envoy stats
echo "Step 3: Testing mTLS connectivity (productpage → details)"
echo ""
# Istio 1.21.6 emits mTLS stats in Envoy's native dotted format with an
# istiocustom. prefix and all labels as key.value pairs, e.g.:
#   istiocustom.istio_requests_total.<labels>.connection_security_policy.mutual_tls: VALUE
# The prefix and label ordering may vary in other versions but
# connection_security_policy.mutual_tls and the ': VALUE' separator are stable.
BEFORE=$(kubectl exec -n bookinfo deployment/details-v1 -c istio-proxy -- \
  pilot-agent request GET stats 2>/dev/null | \
  grep 'istio_requests_total.*connection_security_policy\.mutual_tls' | \
  awk -F': ' '{sum += $2} END {print sum+0}' \
  || echo "0")
echo "  mTLS request count before: ${BEFORE}"

RESPONSE=$(kubectl exec -n bookinfo deployment/productpage-v1 -c productpage -- \
  python3 -c "import requests; r=requests.get('http://details:9080/details/0', timeout=5); print(r.status_code, r.text[:60])" \
  2>/dev/null || echo "FAILED")

if echo "$RESPONSE" | grep -q "^200"; then
  echo "  ✓ HTTP 200 from details: ${RESPONSE}"
else
  echo "  ✗ Request failed: ${RESPONSE}"
  PASS=false
fi

AFTER=$(kubectl exec -n bookinfo deployment/details-v1 -c istio-proxy -- \
  pilot-agent request GET stats 2>/dev/null | \
  grep 'istio_requests_total.*connection_security_policy\.mutual_tls' | \
  awk -F': ' '{sum += $2} END {print sum+0}' \
  || echo "0")
echo "  mTLS request count after:  ${AFTER}"

if [ "${AFTER:-0}" -gt "${BEFORE:-0}" ]; then
  echo "  ✓ mTLS counter incremented (${BEFORE} → ${AFTER})"
else
  echo "  ✗ mTLS counter did not increment"
  PASS=false
fi
echo ""

# Result
echo "================================================"
if [ "$PASS" = "true" ]; then
  echo "✓ SUCCESS: Nonstandard SPIFFE ID mTLS is working!"
  echo ""
  echo "All bookinfo services hold Defakto-issued X.509-SVIDs with"
  echo "the nonstandard path /wl/<app> suffix. mTLS succeeds because"
  echo "DestinationRules override Envoy's hardcoded SAN validation."
  echo ""
  echo "Reference: https://github.com/istio/istio/issues/43105"
else
  echo "✗ FAILURES detected — see output above"
  exit 1
fi
