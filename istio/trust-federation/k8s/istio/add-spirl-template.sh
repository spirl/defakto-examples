#!/usr/bin/env bash
set -e

echo "========================================"
echo "Adding SPIRL Sidecar Template to Istio"
echo "========================================"
echo ""
echo "This adds a custom sidecar template that enables workloads to"
echo "receive SPIRL-issued certificates instead of Istio-issued ones."
echo ""
echo "Workloads opt into SPIRL certificates by adding this annotation:"
echo "  inject.istio.io/templates: \"sidecar,spirl\""
echo ""
echo "Note: This does NOT change Istio's default CA (still istiod)"
echo ""

read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo "Updating Istio configuration with SPIRL template..."
istioctl install -y -f k8s/istio/istio-with-spirl-template.yaml

echo ""
echo "Waiting for Istio to be ready..."
kubectl rollout status deployment/istiod -n istio-system --timeout=300s

echo ""
echo "✓ SPIRL template added successfully"
echo ""
echo "Summary:"
echo "--------"
echo "- Default workloads: Continue to get Istio-issued certificates"
echo "- Annotated workloads: Can now get SPIRL-issued certificates"
echo "- Both types can coexist in the same mesh"
echo ""
echo "Next step: Add SPIRL trust bundle so workloads can trust each other"
echo "  ./k8s/istio/add-trust-bundle.sh"
echo ""
