#!/usr/bin/env bash
set -e

# Default to details service if not specified
SERVICE="${1:-details-v1}"
NAMESPACE="${2:-bookinfo}"

echo "=============================================="
echo "Enable SPIRL Certificates for Service"
echo "=============================================="
echo ""
echo "Service: ${SERVICE}"
echo "Namespace: ${NAMESPACE}"
echo ""

# Check if deployment exists
if ! kubectl get deployment ${SERVICE} -n ${NAMESPACE} &>/dev/null; then
    echo "ERROR: Deployment ${SERVICE} not found in namespace ${NAMESPACE}"
    echo ""
    echo "Available deployments in ${NAMESPACE}:"
    kubectl get deployments -n ${NAMESPACE} -o name
    exit 1
fi

# Check if SPIRL is installed
if ! kubectl get daemonset -n spirl-system spirl-agent &>/dev/null; then
    echo "ERROR: SPIRL not installed in the cluster"
    echo ""
    echo "Please install SPIRL first:"
    echo "  spirlctl cluster add istio-trust-federation --trust-domain \$TRUST_DOMAIN --platform istio"
    exit 1
fi

echo "Step 1: Adding label to enable SPIRL CSI volume injection"
echo "----------------------------------------------"
echo ""

# Add the label and annotation that trigger SPIRL CSI volume injection
kubectl patch deployment ${SERVICE} -n ${NAMESPACE} -p '{
  "spec": {
    "template": {
      "metadata": {
        "labels": {
          "k8s.spirl.com/spiffe-csi": "enabled"
        },
        "annotations": {
          "inject.istio.io/templates": "sidecar,spirl"
        }
      }
    }
  }
}'

echo "✓ Label added: k8s.spirl.com/spiffe-csi=enabled"
echo "✓ Annotation added: inject.istio.io/templates=sidecar,spirl"
echo ""

echo "Step 2: Restarting deployment to pick up SPIRL certificates"
echo "----------------------------------------------"
echo ""

kubectl rollout restart deployment/${SERVICE} -n ${NAMESPACE}

echo "Waiting for rollout to complete..."
kubectl rollout status deployment/${SERVICE} -n ${NAMESPACE} --timeout=300s

echo ""
echo "✓ Deployment restarted"
echo ""

echo "Step 3: Verifying SPIRL certificate"
echo "----------------------------------------------"
echo ""

# Wait a moment for cert provisioning
sleep 5

POD=$(kubectl get pod -n ${NAMESPACE} -l app=${SERVICE%%-*} -o jsonpath='{.items[0].metadata.name}')

if [ -z "${POD}" ]; then
    echo "WARNING: Could not find pod for service ${SERVICE}"
    echo "Check pods manually: kubectl get pods -n ${NAMESPACE} -l app=${SERVICE%%-*}"
else
    echo "Checking pod: ${POD}"
    echo ""

    # Check if the SPIFFE socket is mounted
    if kubectl exec -n ${NAMESPACE} ${POD} -c istio-proxy -- test -S /run/secrets/workload-spiffe-uds/socket 2>/dev/null; then
        echo "✓ SPIFFE socket found at /run/secrets/workload-spiffe-uds/socket"
        echo ""

        # Get certificate info
        echo "Certificate information:"
        kubectl exec -n ${NAMESPACE} ${POD} -c istio-proxy -- \
          pilot-agent request GET certs 2>/dev/null | \
          jq -r '.certificates[0].cert_chain[0] |
          "  SPIFFE ID: " + (.subject_alt_names[0].uri // "N/A") + "\n" +
          "  Valid from: " + .valid_from + "\n" +
          "  Expires: " + .expiration_time' 2>/dev/null || echo "  Could not retrieve certificate info"
        echo ""

        # Check trust domain
        SPIFFE_ID=$(kubectl exec -n ${NAMESPACE} ${POD} -c istio-proxy -- \
          pilot-agent request GET certs 2>/dev/null | \
          jq -r '.certificates[0].cert_chain[0].subject_alt_names[0].uri' 2>/dev/null || echo "")

        if [[ $SPIFFE_ID == *"cluster.local"* ]]; then
            echo "⚠️  WARNING: Certificate is still from Istio CA (cluster.local)"
            echo "   Expected: SPIFFE ID with your SPIRL trust domain"
            echo ""
            echo "Possible issues:"
            echo "  1. SPIRL agent not running on the node"
            echo "  2. CSI driver not installed"
            echo "  3. Pod needs more time to obtain certificate"
            echo ""
            echo "Check SPIRL agent status:"
            echo "  kubectl get pods -n spirl-system"
        elif [[ $SPIFFE_ID == spiffe://* ]]; then
            TRUST_DOMAIN=$(echo $SPIFFE_ID | sed 's|spiffe://\([^/]*\).*|\1|')
            echo "✓ SUCCESS: Certificate is from SPIRL CA"
            echo "  Trust Domain: ${TRUST_DOMAIN}"
        fi
    else
        echo "❌ SPIFFE socket not found at /run/secrets/workload-spiffe-uds/socket"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check if SPIRL CSI driver is installed:"
        echo "     kubectl get daemonset -n spirl-system spiffe-csi-driver"
        echo ""
        echo "  2. Check if SPIRL agent is running on the node:"
        echo "     kubectl get pods -n spirl-system -o wide"
        echo ""
        echo "  3. Check pod events for CSI mount errors:"
        echo "     kubectl describe pod ${POD} -n ${NAMESPACE}"
        echo ""
        echo "  4. Check SPIRL controller webhook logs:"
        echo "     kubectl logs -n spirl-system deployment/spirl-controller"
    fi
fi

echo ""
echo "=============================================="
echo "Done"
echo "=============================================="
echo ""
echo "Service ${SERVICE} is now configured to use SPIRL certificates."
echo ""
echo "To verify cross-CA communication:"
echo "  1. Test from another service to ${SERVICE}:"
echo "     kubectl exec -n ${NAMESPACE} deployment/productpage-v1 -c productpage -- \\"
echo "       python -c \"import requests; print(requests.get('http://${SERVICE%%-*}:9080/...').text)\""
echo ""
echo "  2. Check mTLS statistics:"
echo "     kubectl exec -n ${NAMESPACE} ${POD} -c istio-proxy -- \\"
echo "       pilot-agent request GET stats | grep istio_requests_total.*mutual_tls"
echo ""
