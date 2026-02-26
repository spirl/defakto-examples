#!/usr/bin/env bash
set -e

# Configuration
TRUST_DOMAIN="${TRUST_DOMAIN:-example.org}"
SPIRL_BUNDLE_ENDPOINT="${SPIRL_BUNDLE_ENDPOINT}"
TEMP_DIR=$(mktemp -d)
trap "rm -rf ${TEMP_DIR}" EXIT

echo "========================================"
echo "Adding Defakto Trust Bundle to Istio"
echo "========================================"
echo ""
echo "This script adds Defakto's CA certificate to Istio's root trust bundle"
echo "by concatenating it with Istio's existing root certificate."
echo ""

# Step 1: Fetch the Defakto trust bundle from Defakto Bridge
echo "Step 1: Fetching Defakto trust bundle from Defakto Bridge"
echo "Trust Domain: ${TRUST_DOMAIN}"
echo ""

if [ -z "${SPIRL_BUNDLE_ENDPOINT}" ]; then
    echo "ERROR: SPIRL_BUNDLE_ENDPOINT not set"
    echo ""
    echo "Please set the Defakto Bundle Endpoint URL for your trust domain."
    echo "This should be in the format:"
    echo "  https://fed.spirl.org/t-{id}/td-{id}/bundle"
    echo ""
    echo "You can find this in your Defakto trust domain configuration."
    echo ""
    echo "Example:"
    echo "  export SPIRL_BUNDLE_ENDPOINT=https://fed.spirl.org/t-abc123/td-xyz789/bundle"
    echo "  ./k8s/istio/add-trust-bundle.sh"
    exit 1
fi

echo "Bundle Endpoint: ${SPIRL_BUNDLE_ENDPOINT}"
echo ""

# Fetch the trust bundle from Defakto Bridge
SPIRL_BUNDLE_FILE="${TEMP_DIR}/spirl-bundle.pem"
echo "Fetching bundle..."
if ! curl -fsSL "${SPIRL_BUNDLE_ENDPOINT}" -o "${SPIRL_BUNDLE_FILE}"; then
    echo "ERROR: Failed to fetch trust bundle from Defakto endpoint"
    echo "Please verify the endpoint URL and your network connectivity"
    exit 1
fi

if [ ! -s ${SPIRL_BUNDLE_FILE} ]; then
    echo "ERROR: Trust bundle is empty"
    exit 1
fi

# Check if the bundle is in JWKS format and convert to PEM if needed
if grep -q '"keys"' ${SPIRL_BUNDLE_FILE}; then
    echo "Bundle is in JWKS format, converting to PEM..."

    # Extract X.509 certificates from JWKS x5c field
    # The x5c field contains base64-encoded DER certificates
    PEM_FILE="${TEMP_DIR}/converted-bundle.pem"

    # Use jq to extract x5c certificates and convert to PEM
    if ! command -v jq &> /dev/null; then
        echo "ERROR: jq is required to process JWKS bundles but is not installed"
        echo "Please install jq: https://jqlang.github.io/jq/download/"
        exit 1
    fi

    # Extract all x5c certificate chains and convert to PEM
    jq -r '.keys[].x5c[]?' ${SPIRL_BUNDLE_FILE} | while read -r cert; do
        echo "-----BEGIN CERTIFICATE-----"
        echo "$cert" | fold -w 64
        echo "-----END CERTIFICATE-----"
    done > ${PEM_FILE}

    if [ ! -s ${PEM_FILE} ]; then
        echo "ERROR: Failed to extract certificates from JWKS bundle"
        exit 1
    fi

    # Replace the original bundle file with the PEM version
    mv ${PEM_FILE} ${SPIRL_BUNDLE_FILE}
    echo "✓ Converted JWKS to PEM format"
fi

echo "✓ Successfully fetched Defakto trust bundle"
SPIRL_CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" ${SPIRL_BUNDLE_FILE} || echo "0")
echo "  Defakto bundle contains ${SPIRL_CERT_COUNT} certificate(s)"
echo ""

# Step 2: Get Istio's current root certificate
echo "Step 2: Getting Istio's current root certificate"
echo ""

ISTIO_ROOT_FILE="${TEMP_DIR}/istio-root-cert.pem"

# Always get the ORIGINAL Istio root cert, not a potentially combined one
# Try istio-ca-secret first (contains the original CA cert)
if kubectl get secret istio-ca-secret -n istio-system &>/dev/null; then
    echo "Fetching Istio root certificate from istio-ca-secret"
    kubectl get secret istio-ca-secret -n istio-system -o jsonpath='{.data.ca-cert\.pem}' | base64 -d > ${ISTIO_ROOT_FILE}
# Fall back to istio-ca-root-cert ConfigMap
elif kubectl get configmap istio-ca-root-cert -n istio-system &>/dev/null; then
    echo "Fetching Istio root certificate from istio-ca-root-cert ConfigMap"
    kubectl get configmap istio-ca-root-cert -n istio-system -o jsonpath='{.data.root-cert\.pem}' > ${ISTIO_ROOT_FILE}
else
    echo "ERROR: Could not find Istio root certificate"
    echo "Checked:"
    echo "  - secret/istio-ca-secret (original CA cert)"
    echo "  - configmap/istio-ca-root-cert (self-signed mode)"
    exit 1
fi

if [ ! -s ${ISTIO_ROOT_FILE} ]; then
    echo "ERROR: Istio root certificate is empty"
    exit 1
fi

ISTIO_CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" ${ISTIO_ROOT_FILE} || echo "0")
echo "✓ Retrieved Istio root certificate"
echo "  Istio root cert contains ${ISTIO_CERT_COUNT} certificate(s)"
echo ""

# Step 3: Create combined root certificate
echo "Step 3: Creating combined root certificate"
echo ""

COMBINED_ROOT_FILE="${TEMP_DIR}/combined-root-cert.pem"

# Concatenate Istio root cert + SPIRL root cert
cat ${ISTIO_ROOT_FILE} > ${COMBINED_ROOT_FILE}
cat ${SPIRL_BUNDLE_FILE} >> ${COMBINED_ROOT_FILE}

COMBINED_CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" ${COMBINED_ROOT_FILE} || echo "0")
echo "✓ Created combined root certificate"
echo "  Combined cert contains ${COMBINED_CERT_COUNT} certificate(s)"
echo "  - ${ISTIO_CERT_COUNT} from Istio CA"
echo "  - ${SPIRL_CERT_COUNT} from Defakto CA"
echo ""

# Step 4: Update or create cacerts secret
echo "Step 4: Updating Istio CA configuration"
echo ""

if kubectl get secret cacerts -n istio-system &>/dev/null; then
    echo "Updating existing cacerts secret..."

    # Get the current ca-cert, ca-key, and cert-chain
    CA_CERT_FILE="${TEMP_DIR}/ca-cert.pem"
    CA_KEY_FILE="${TEMP_DIR}/ca-key.pem"
    CERT_CHAIN_FILE="${TEMP_DIR}/cert-chain.pem"

    kubectl get secret cacerts -n istio-system -o jsonpath='{.data.ca-cert\.pem}' | base64 -d > ${CA_CERT_FILE}
    kubectl get secret cacerts -n istio-system -o jsonpath='{.data.ca-key\.pem}' | base64 -d > ${CA_KEY_FILE}
    kubectl get secret cacerts -n istio-system -o jsonpath='{.data.cert-chain\.pem}' | base64 -d > ${CERT_CHAIN_FILE}

    # Delete and recreate the secret with the combined root cert
    kubectl delete secret cacerts -n istio-system
    kubectl create secret generic cacerts -n istio-system \
        --from-file=ca-cert.pem=${CA_CERT_FILE} \
        --from-file=ca-key.pem=${CA_KEY_FILE} \
        --from-file=root-cert.pem=${COMBINED_ROOT_FILE} \
        --from-file=cert-chain.pem=${CERT_CHAIN_FILE}

    echo "✓ Updated cacerts secret with combined root certificate"
else
    echo "Creating new cacerts secret with combined root certificate..."
    echo ""
    echo "Note: This switches Istio from self-signed mode to plugin CA mode."
    echo "Istio will continue to issue certificates using its existing CA,"
    echo "but will now trust both Istio and SPIRL root certificates."
    echo ""

    # We need to get Istio's current CA cert and key
    # In self-signed mode, these are stored in istio-ca-secret
    CA_CERT_FILE="${TEMP_DIR}/ca-cert.pem"
    CA_KEY_FILE="${TEMP_DIR}/ca-key.pem"
    CERT_CHAIN_FILE="${TEMP_DIR}/cert-chain.pem"

    kubectl get secret istio-ca-secret -n istio-system -o jsonpath='{.data.ca-cert\.pem}' | base64 -d > ${CA_CERT_FILE}
    kubectl get secret istio-ca-secret -n istio-system -o jsonpath='{.data.ca-key\.pem}' | base64 -d > ${CA_KEY_FILE}
    kubectl get secret istio-ca-secret -n istio-system -o jsonpath='{.data.cert-chain\.pem}' | base64 -d > ${CERT_CHAIN_FILE}

    # Create the cacerts secret
    kubectl create secret generic cacerts -n istio-system \
        --from-file=ca-cert.pem=${CA_CERT_FILE} \
        --from-file=ca-key.pem=${CA_KEY_FILE} \
        --from-file=root-cert.pem=${COMBINED_ROOT_FILE} \
        --from-file=cert-chain.pem=${CERT_CHAIN_FILE}

    echo "✓ Created cacerts secret with combined root certificate"
fi
echo ""

# Step 5: Restart istiod to pick up the new certificate
echo "Step 5: Restarting istiod to load new root certificate"
echo ""
echo "Restarting istiod..."
kubectl rollout restart deployment/istiod -n istio-system

echo "Waiting for istiod to be ready..."
kubectl rollout status deployment/istiod -n istio-system --timeout=300s

echo ""
echo "========================================"
echo "✓ Trust Bundle Added Successfully"
echo "========================================"
echo ""
echo "What Changed:"
echo "-------------"
echo "1. Combined Istio's root CA certificate with Defakto's root CA certificate"
echo "2. Updated the cacerts secret with the combined root certificate"
echo "3. Restarted istiod to load the new certificate"
echo "4. Envoy proxies will now trust BOTH:"
echo "   - Certificates issued by Istio CA (cluster.local)"
echo "   - Certificates issued by Defakto CA (${TRUST_DOMAIN})"
echo ""
echo "Next Steps:"
echo "-----------"
echo "Existing pods need to be restarted to pick up the new root certificate:"
echo "  kubectl rollout restart deployment -n bookinfo productpage-v1 details-v1 reviews-v2 reviews-v3 ratings-v1"
echo ""
echo "After restarting, workloads will trust certificates from both CAs,"
echo "enabling secure communication between Istio and Defakto workloads."
echo ""
