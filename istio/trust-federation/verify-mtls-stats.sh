#!/usr/bin/env bash
set -e

echo "=============================================="
echo "Verify mTLS Using Istio Statistics"
echo "=============================================="
echo ""

# Check if bookinfo namespace exists
if ! kubectl get namespace bookinfo &>/dev/null; then
    echo "ERROR: bookinfo namespace not found"
    exit 1
fi

# Check if deployments exist
if ! kubectl get deployment -n bookinfo details-v1 &>/dev/null; then
    echo "ERROR: details-v1 deployment not found in bookinfo namespace"
    exit 1
fi

if ! kubectl get deployment -n bookinfo productpage-v1 &>/dev/null; then
    echo "ERROR: productpage-v1 deployment not found in bookinfo namespace"
    exit 1
fi

echo "Checking mTLS request count..."
echo ""

# Get initial mTLS request count
BEFORE=$(kubectl exec -n bookinfo deployment/details-v1 -c istio-proxy -- \
  pilot-agent request GET stats 2>/dev/null | \
  grep "istio_requests_total.*connection_security_policy.mutual_tls" | \
  awk -F': ' '{print $2}' || echo "0")

echo "mTLS requests before: ${BEFORE}"

# Make a request from application container
echo ""
echo "Making test request from productpage to details..."
kubectl exec -n bookinfo deployment/productpage-v1 -c productpage -- \
  python -c "import requests; print(requests.get('http://details:9080/details/0').text)" 2>/dev/null || {
    echo "ERROR: Failed to make request from productpage to details"
    exit 1
}

echo ""
echo "Checking mTLS request count again..."

# Check mTLS request count again
AFTER=$(kubectl exec -n bookinfo deployment/details-v1 -c istio-proxy -- \
  pilot-agent request GET stats 2>/dev/null | \
  grep "istio_requests_total.*connection_security_policy.mutual_tls" | \
  awk -F': ' '{print $2}' || echo "0")

echo "mTLS requests after: ${AFTER}"
echo ""

# Verify counter increased
if [ "${AFTER}" -gt "${BEFORE}" ]; then
  echo "✓ SUCCESS: Counter increased from ${BEFORE} to ${AFTER} - mTLS is working!"
  exit 0
else
  echo "✗ FAILED: Counter did not increase (before: ${BEFORE}, after: ${AFTER})"
  echo ""
  echo "This could mean:"
  echo "  - mTLS is not properly configured"
  echo "  - The request didn't go through the proxy"
  echo "  - Stats collection is not working"
  exit 1
fi
