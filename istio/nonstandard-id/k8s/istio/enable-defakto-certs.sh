#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo "Enabling Defakto Certificate Issuance"
echo "========================================"
echo ""
echo "Registers the 'spirl' sidecar injection template with Istio, opts all"
echo "bookinfo deployments into it, then restarts pods so istio-proxy mounts"
echo "the SPIFFE CSI socket and presents Defakto-issued X.509-SVIDs."
echo ""

# Step 1: Register the 'spirl' injection template with Istio.
# This adds a named template that, when combined with 'sidecar', replaces
# the default workload-socket emptyDir with the actual SPIFFE CSI volume.
echo "Step 1: Registering 'spirl' injection template with Istio..."
istioctl install -y -f "${SCRIPT_DIR}/istio-with-defakto-default.yaml"

echo ""
echo "Waiting for istiod to be ready..."
kubectl rollout status deployment/istiod -n istio-system --timeout=300s
echo ""

# Step 2: Opt all bookinfo deployments into the 'spirl' template.
# Pod-level annotations override namespace annotations, so we patch the
# pod template in each deployment directly.
echo "Step 2: Patching bookinfo deployments to use 'sidecar,spirl' template..."
for dep in details-v1 productpage-v1 reviews-v2 reviews-v3 ratings-v1; do
  kubectl patch deployment "${dep}" -n bookinfo \
    --patch='{"spec":{"template":{"metadata":{"annotations":{"inject.istio.io/templates":"sidecar,spirl"}}}}}'
  echo "  ✓ ${dep}"
done
echo ""

# Step 3: Restart pods to trigger re-injection with the updated template.
echo "Step 3: Restarting bookinfo pods..."
kubectl rollout restart deployment -n bookinfo
for dep in details-v1 productpage-v1 reviews-v2 reviews-v3 ratings-v1; do
  kubectl rollout status deployment/"${dep}" -n bookinfo --timeout=120s
done
echo ""

echo "========================================"
echo "✓ Pods are now using Defakto certificates"
echo "========================================"
echo ""
echo "Each bookinfo pod now holds a Defakto-issued SPIFFE ID with the"
echo "nonstandard /wl/<app> suffix, e.g.:"
echo "  spiffe://defakto.example.com/ns/bookinfo/sa/bookinfo-details/wl/details"
echo ""
echo "mTLS connections will now fail (503) because Istio's Envoy rejects"
echo "the /wl/<app> suffix. Apply DestinationRules (step 6) to fix this."
