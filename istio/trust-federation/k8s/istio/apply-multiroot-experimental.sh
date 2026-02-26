#!/usr/bin/env bash
set -e

# Configuration
TRUST_DOMAIN="${TRUST_DOMAIN:-example.org}"
SPIRL_BUNDLE_ENDPOINT="${SPIRL_BUNDLE_ENDPOINT}"
TEMP_DIR=$(mktemp -d)
trap "rm -rf ${TEMP_DIR}" EXIT

echo "=============================================="
echo "Applying Multi-Root Trust (Experimental)"
echo "=============================================="
echo ""
echo "This script configures Istio to trust both:"
echo "  1. Istio's built-in CA (cluster.local)"
echo "  2. Defakto CA (${TRUST_DOMAIN})"
echo ""
echo "Using experimental meshConfig.caCertificates approach"
echo ""

# Validate environment
if [ -z "${SPIRL_BUNDLE_ENDPOINT}" ]; then
    echo "ERROR: SPIRL_BUNDLE_ENDPOINT not set"
    echo ""
    echo "Please set the Defakto Bundle Endpoint URL for your trust domain."
    echo "Example:"
    echo "  export SPIRL_BUNDLE_ENDPOINT=https://fed.spirl.org/t-abc123/td-xyz789/bundle"
    echo "  ./k8s/istio/apply-multiroot-experimental.sh"
    exit 1
fi

if ! command -v istioctl &> /dev/null; then
    echo "ERROR: istioctl not found"
    echo "Please install istioctl: https://istio.io/latest/docs/setup/getting-started/#download"
    exit 1
fi

# Step 1: Fetch the Defakto trust bundle
echo "Step 1: Fetching Defakto trust bundle"
echo "----------------------------------------------"
echo "Trust Domain: ${TRUST_DOMAIN}"
echo "Bundle Endpoint: ${SPIRL_BUNDLE_ENDPOINT}"
echo ""

SPIRL_BUNDLE_FILE="${TEMP_DIR}/spirl-bundle.pem"
echo "Fetching bundle..."
if ! curl -fsSL "${SPIRL_BUNDLE_ENDPOINT}" -o "${SPIRL_BUNDLE_FILE}"; then
    echo "ERROR: Failed to fetch trust bundle"
    exit 1
fi

# Check if the bundle is in JWKS format and convert to PEM if needed
if grep -q '"keys"' ${SPIRL_BUNDLE_FILE}; then
    echo "Converting JWKS to PEM format..."

    if ! command -v jq &> /dev/null; then
        echo "ERROR: jq is required but not installed"
        echo "Please install jq: https://jqlang.github.io/jq/download/"
        exit 1
    fi

    PEM_FILE="${TEMP_DIR}/converted-bundle.pem"
    jq -r '.keys[].x5c[]?' ${SPIRL_BUNDLE_FILE} | while read -r cert; do
        echo "-----BEGIN CERTIFICATE-----"
        echo "$cert" | fold -w 64
        echo "-----END CERTIFICATE-----"
    done > ${PEM_FILE}

    if [ ! -s ${PEM_FILE} ]; then
        echo "ERROR: Failed to extract certificates from JWKS bundle"
        exit 1
    fi

    mv ${PEM_FILE} ${SPIRL_BUNDLE_FILE}
    echo "✓ Converted to PEM format"
fi

CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" ${SPIRL_BUNDLE_FILE} || echo "0")
echo "✓ Fetched bundle with ${CERT_COUNT} certificate(s)"
echo ""

# Step 2: Create Istio configuration with Defakto CA
echo "Step 2: Preparing Istio configuration"
echo "----------------------------------------------"
echo ""

ISTIO_CONFIG="${TEMP_DIR}/istio-config.yaml"

# Replace trust domain first
sed "s|__DEFAKTO_TRUST_DOMAIN__|${TRUST_DOMAIN}|g" \
    k8s/istio/istio-multiroot-experimental.yaml > ${ISTIO_CONFIG}.tmp

# Use awk to replace the certificate placeholder with actual content
awk -v bundle_file="${SPIRL_BUNDLE_FILE}" '
/^          __DEFAKTO_CA_BUNDLE__$/ {
    while ((getline line < bundle_file) > 0) {
        print "          " line
    }
    close(bundle_file)
    next
}
{ print }
' ${ISTIO_CONFIG}.tmp > ${ISTIO_CONFIG}

echo "✓ Configuration prepared"
echo ""

# Show the relevant section of the config
echo "Configuration preview (caCertificates section):"
echo "----------------------------------------------"
grep -A 15 "caCertificates:" ${ISTIO_CONFIG} | head -20
echo ""

echo "Dumping entire configuration:"
echo "----------------------------------------------"
cat ${ISTIO_CONFIG}
echo ""

# Step 3: Apply the configuration
echo "Step 3: Applying configuration with istioctl"
echo "----------------------------------------------"
echo ""
echo "This will update the Istio control plane..."
echo ""

if istioctl install -f ${ISTIO_CONFIG} -y; then
    echo ""
    echo "✓ Configuration applied successfully"
else
    echo ""
    echo "ERROR: Failed to apply configuration"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check istioctl version: istioctl version"
    echo "  2. View full config: cat ${ISTIO_CONFIG}"
    echo "  3. Check istiod logs: kubectl logs -n istio-system deployment/istiod"
    exit 1
fi

echo ""
echo "Step 4: Waiting for istiod to be ready"
echo "----------------------------------------------"
kubectl rollout status deployment/istiod -n istio-system --timeout=300s

echo ""
echo "=============================================="
echo "✓ Multi-Root Trust Configuration Applied"
echo "=============================================="
echo ""
echo "Istio should now trust certificates from:"
echo "  1. Istio CA (cluster.local)"
echo "  2. Defakto CA (${TRUST_DOMAIN})"
echo ""
echo "Next steps:"
echo "  1. Restart existing pods to pick up new configuration:"
echo "     kubectl rollout restart deployment -n bookinfo"
echo ""
echo "  2. Verify trust bundle in Envoy:"
echo "     ./verify-multiroot.sh"
echo ""
echo "  3. Deploy SPIRL workload:"
echo "     kubectl apply -f k8s/app/spirl-workload.yaml"
echo ""
