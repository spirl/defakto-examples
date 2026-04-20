#!/usr/bin/env bash
set -e

# Configuration — both have working defaults for the demo
TRUST_DOMAIN="${TRUST_DOMAIN:-defakto.example.com}"
SPIRL_BUNDLE_ENDPOINT="${SPIRL_BUNDLE_ENDPOINT:-https://fed.spirl.org/t-o9cpowm5yo/td-tph7n4519n/bundle}"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "========================================"
echo "Adding Defakto Trust Bundle to Istio"
echo "========================================"
echo ""
echo "Trust Domain:    ${TRUST_DOMAIN}"
echo "Bundle Endpoint: ${SPIRL_BUNDLE_ENDPOINT}"
echo ""

# Step 1: Fetch the Defakto trust bundle
echo "Step 1: Fetching Defakto trust bundle..."
SPIRL_BUNDLE_FILE="${TEMP_DIR}/spirl-bundle.pem"
if ! curl -fsSL "${SPIRL_BUNDLE_ENDPOINT}" -o "${SPIRL_BUNDLE_FILE}"; then
    echo "ERROR: Failed to fetch trust bundle from ${SPIRL_BUNDLE_ENDPOINT}"
    exit 1
fi
if [ ! -s "${SPIRL_BUNDLE_FILE}" ]; then
    echo "ERROR: Trust bundle is empty"
    exit 1
fi

# Convert JWKS → PEM if needed
if grep -q '"keys"' "${SPIRL_BUNDLE_FILE}"; then
    echo "Bundle is in JWKS format, converting to PEM..."
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required to process JWKS bundles"
        exit 1
    fi
    PEM_FILE="${TEMP_DIR}/converted-bundle.pem"
    jq -r '.keys[].x5c[]?' "${SPIRL_BUNDLE_FILE}" | while read -r cert; do
        echo "-----BEGIN CERTIFICATE-----"
        echo "$cert" | fold -w 64
        echo "-----END CERTIFICATE-----"
    done > "${PEM_FILE}"
    if [ ! -s "${PEM_FILE}" ]; then
        echo "ERROR: Failed to extract certificates from JWKS bundle"
        exit 1
    fi
    mv "${PEM_FILE}" "${SPIRL_BUNDLE_FILE}"
    echo "✓ Converted JWKS to PEM"
fi
SPIRL_CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${SPIRL_BUNDLE_FILE}" || true)
echo "✓ Defakto bundle: ${SPIRL_CERT_COUNT} certificate(s)"
echo ""

# Step 2: Get Istio's current root certificate
echo "Step 2: Getting Istio root certificate..."
ISTIO_ROOT_FILE="${TEMP_DIR}/istio-root-cert.pem"
if kubectl get secret istio-ca-secret -n istio-system &>/dev/null; then
    kubectl get secret istio-ca-secret -n istio-system \
        -o jsonpath='{.data.ca-cert\.pem}' | base64 -d > "${ISTIO_ROOT_FILE}"
elif kubectl get configmap istio-ca-root-cert -n istio-system &>/dev/null; then
    kubectl get configmap istio-ca-root-cert -n istio-system \
        -o jsonpath='{.data.root-cert\.pem}' > "${ISTIO_ROOT_FILE}"
else
    echo "ERROR: Could not find Istio root certificate"
    exit 1
fi
if [ ! -s "${ISTIO_ROOT_FILE}" ]; then
    echo "ERROR: Istio root certificate is empty"
    exit 1
fi
ISTIO_CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${ISTIO_ROOT_FILE}" || true)
echo "✓ Istio root cert: ${ISTIO_CERT_COUNT} certificate(s)"
echo ""

# Step 3: Concatenate
echo "Step 3: Creating combined root certificate..."
COMBINED_ROOT_FILE="${TEMP_DIR}/combined-root-cert.pem"
cat "${ISTIO_ROOT_FILE}" > "${COMBINED_ROOT_FILE}"
cat "${SPIRL_BUNDLE_FILE}" >> "${COMBINED_ROOT_FILE}"
COMBINED_CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${COMBINED_ROOT_FILE}" || true)
echo "✓ Combined: ${COMBINED_CERT_COUNT} certificate(s) (${ISTIO_CERT_COUNT} Istio + ${SPIRL_CERT_COUNT} Defakto)"
echo ""

# Step 4: Update or create cacerts secret
echo "Step 4: Updating Istio CA configuration..."
CA_CERT_FILE="${TEMP_DIR}/ca-cert.pem"
CA_KEY_FILE="${TEMP_DIR}/ca-key.pem"
CERT_CHAIN_FILE="${TEMP_DIR}/cert-chain.pem"

if kubectl get secret cacerts -n istio-system &>/dev/null; then
    kubectl get secret cacerts -n istio-system \
        -o jsonpath='{.data.ca-cert\.pem}' | base64 -d > "${CA_CERT_FILE}"
    kubectl get secret cacerts -n istio-system \
        -o jsonpath='{.data.ca-key\.pem}' | base64 -d > "${CA_KEY_FILE}"
    kubectl get secret cacerts -n istio-system \
        -o jsonpath='{.data.cert-chain\.pem}' | base64 -d > "${CERT_CHAIN_FILE}"
elif kubectl get secret istio-ca-secret -n istio-system &>/dev/null; then
    kubectl get secret istio-ca-secret -n istio-system \
        -o jsonpath='{.data.ca-cert\.pem}' | base64 -d > "${CA_CERT_FILE}"
    kubectl get secret istio-ca-secret -n istio-system \
        -o jsonpath='{.data.ca-key\.pem}' | base64 -d > "${CA_KEY_FILE}"
    kubectl get secret istio-ca-secret -n istio-system \
        -o jsonpath='{.data.cert-chain\.pem}' | base64 -d > "${CERT_CHAIN_FILE}"
else
    echo "ERROR: Neither secret/cacerts nor secret/istio-ca-secret found in istio-system."
    echo "This Istio installation does not expose the CA keypair needed to create secret/cacerts."
    exit 1
fi

kubectl create secret generic cacerts -n istio-system \
    --from-file=ca-cert.pem="${CA_CERT_FILE}" \
    --from-file=ca-key.pem="${CA_KEY_FILE}" \
    --from-file=root-cert.pem="${COMBINED_ROOT_FILE}" \
    --from-file=cert-chain.pem="${CERT_CHAIN_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
echo "✓ cacerts secret updated"
echo ""

# Step 5: Restart istiod
echo "Step 5: Restarting istiod..."
kubectl rollout restart deployment/istiod -n istio-system
kubectl rollout status deployment/istiod -n istio-system --timeout=300s
echo ""
echo "========================================"
echo "✓ Trust Bundle Added Successfully"
echo "========================================"
echo ""
echo "Envoy proxies now trust both:"
echo "  - Certificates issued by Istio CA (cluster.local)"
echo "  - Certificates issued by Defakto CA (${TRUST_DOMAIN})"
echo ""
echo "Next: restart bookinfo pods so they pick up Defakto certs:"
echo "  kubectl rollout restart deployment -n bookinfo"
