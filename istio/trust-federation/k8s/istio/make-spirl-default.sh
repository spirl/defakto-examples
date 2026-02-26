#!/usr/bin/env bash
set -e

echo "========================================"
echo "Make SPIRL Default Certificate Issuer"
echo "========================================"
echo ""
echo "This changes Istio's default sidecar injection template to"
echo "include SPIRL CSI driver volume mounts. After this change:"
echo ""
echo "  ✓ All NEW workloads will receive SPIRL-issued certificates"
echo "  ✓ Existing workloads keep their certificates until restarted"
echo "  ✓ Trust bundle still includes both Istio and SPIRL CAs"
echo "  ✓ Workloads with different CAs can still communicate"
echo ""
echo "Prerequisites:"
echo "  - SPIRL cluster must be added (spirlctl cluster add)"
echo "  - SPIRL trust bundle must be added (./add-trust-bundle.sh)"
echo ""

# Check if SPIRL CSI driver is installed
if ! kubectl get csidriver csi.spiffe.io &>/dev/null; then
    echo "ERROR: SPIRL CSI driver not found"
    echo ""
    echo "Please add the SPIRL cluster first:"
    echo "  spirlctl cluster add istio-trust-federation --trust-domain example.org --platform istio"
    echo ""
    exit 1
fi

echo "✓ SPIRL CSI driver detected"
echo ""

read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo "Updating Istio default sidecar template..."
istioctl install -y -f k8s/istio/istio-with-spirl-default.yaml

echo ""
echo "Waiting for Istio to be ready..."
kubectl rollout status deployment/istiod -n istio-system --timeout=300s

echo ""
echo "========================================"
echo "✓ SPIRL is now the default CA"
echo "========================================"
echo ""
echo "What Changed:"
echo "-------------"
echo "- Default sidecar template now includes SPIRL CSI volume mounts"
echo "- New workloads will automatically receive SPIRL certificates"
echo "- Existing workloads keep Istio certificates until restarted"
echo "- Both certificate types can coexist safely"
echo ""
echo "To verify:"
echo "---------"
echo "1. Restart a workload:"
echo "   kubectl rollout restart deployment -n bookinfo productpage-v1"
echo ""
echo "2. Check its certificate:"
echo "   kubectl exec -n bookinfo deployment/productpage-v1 -c istio-proxy -- \\"
echo "     pilot-agent request GET certs | grep -A 5 'Certificate Chain'"
echo ""
echo "3. Verify SPIFFE ID is from SPIRL trust domain (example.org)"
echo ""
echo "To revert to Istio-only certificates:"
echo "-------------------------------------"
echo "   istioctl install -y -f k8s/istio/istio-initial.yaml"
echo "   ./add-trust-bundle.sh  # Re-add SPIRL trust if needed"
echo ""
