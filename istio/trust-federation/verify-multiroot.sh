#!/usr/bin/env bash
set -e

echo "=============================================="
echo "Multi-Root Trust Verification"
echo "=============================================="
echo ""

# Check if any pods exist in bookinfo namespace
if ! kubectl get pods -n bookinfo &>/dev/null; then
    echo "WARNING: bookinfo namespace not found"
    NAMESPACE="default"
elif [ $(kubectl get pods -n bookinfo --no-headers 2>/dev/null | wc -l) -eq 0 ]; then
    echo "WARNING: No pods found in bookinfo namespace"
    NAMESPACE="default"
else
    NAMESPACE="bookinfo"
fi

# Get a pod to inspect - try multiple label selectors
POD=$(kubectl get pod -n ${NAMESPACE} -l app --no-headers 2>/dev/null | grep Running | head -1 | awk '{print $1}')

# If no pod with "app" label, try any pod with istio-proxy
if [ -z "${POD}" ]; then
    echo "No pods with 'app' label found, looking for any pod with istio-proxy sidecar..."
    POD=$(kubectl get pod -n ${NAMESPACE} -o json 2>/dev/null | \
        jq -r '.items[] | select(.spec.containers[].name == "istio-proxy") | .metadata.name' | head -1)
fi

if [ -z "${POD}" ]; then
    echo "ERROR: No pods with istio-proxy sidecar found in namespace ${NAMESPACE}"
    echo ""
    echo "Available pods in ${NAMESPACE}:"
    kubectl get pods -n ${NAMESPACE}
    echo ""
    echo "Please ensure you have deployed a workload with Istio sidecar injection enabled."
    echo ""
    echo "To deploy bookinfo:"
    echo "  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.28/samples/bookinfo/platform/kube/bookinfo.yaml"
    exit 1
fi

echo "Using pod: ${POD} in namespace ${NAMESPACE}"
echo ""

# Step 1: Check mesh configuration
echo "Step 1: Checking mesh configuration"
echo "----------------------------------------------"
echo ""

echo "Trust Domain:"
kubectl get istiooperator -n istio-system -o jsonpath='{.items[0].spec.meshConfig.trustDomain}' 2>/dev/null || \
    kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' 2>/dev/null | grep trustDomain | head -1
echo ""

echo ""
echo "Trust Domain Aliases:"
kubectl get istiooperator -n istio-system -o jsonpath='{.items[0].spec.meshConfig.trustDomainAliases}' 2>/dev/null || \
    kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' 2>/dev/null | grep -A 5 trustDomainAliases || echo "  (none configured)"
echo ""

echo ""
echo "CA Certificates configured in mesh:"
kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' 2>/dev/null | grep -A 10 "caCertificates" || echo "  (none configured via meshConfig)"
echo ""

# Step 2: Check environment variables
echo ""
echo "Step 2: Checking feature flags"
echo "----------------------------------------------"
echo ""

echo "ISTIO_MULTIROOT_MESH:"
kubectl get deployment istiod -n istio-system -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ISTIO_MULTIROOT_MESH")].value}' 2>/dev/null || echo "  (not set)"
echo ""

echo ""
echo "PROXY_CONFIG_XDS_AGENT (in pilot-agent):"
kubectl exec -n ${NAMESPACE} ${POD} -c istio-proxy -- env 2>/dev/null | grep PROXY_CONFIG_XDS_AGENT || echo "  (not set)"
echo ""

# Step 3: Check Envoy's ROOTCA secret
echo ""
echo "Step 3: Checking Envoy's trusted CA bundle"
echo "----------------------------------------------"
echo ""

# Get the ROOTCA secret from Envoy - handle both standard and SPIFFECertValidatorConfig formats
ROOTCA_JSON=$(istioctl proxy-config secret ${POD}.${NAMESPACE} -o json 2>/dev/null | \
    jq -r '.dynamicActiveSecrets[] | select(.name == "ROOTCA")')

if [ -z "$ROOTCA_JSON" ]; then
    echo "❌ Could not retrieve ROOTCA from Envoy"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check if pod has istio-proxy: kubectl get pod ${POD} -n ${NAMESPACE} -o jsonpath='{.spec.containers[*].name}'"
    echo "  2. Check proxy status: istioctl proxy-status"
    echo "  3. Check istiod logs: kubectl logs -n istio-system deployment/istiod"
    ROOTCA_COUNT=0
else
    # Try standard format first
    ROOTCA_CERTS=$(echo "$ROOTCA_JSON" | jq -r '.secret.validationContext.trustedCa.inlineBytes' 2>/dev/null)

    # If not found, try SPIFFECertValidatorConfig format
    if [ -z "$ROOTCA_CERTS" ] || [ "$ROOTCA_CERTS" = "null" ]; then
        ROOTCA_CERTS=$(echo "$ROOTCA_JSON" | \
            jq -r '.secret.validationContext.customValidatorConfig.typedConfig.trustDomains[].trustBundle.inlineBytes' 2>/dev/null | \
            tr '\n' ' ')
    fi

    # Decode and count certificates
    ROOTCA_COUNT=$(echo "$ROOTCA_CERTS" | base64 -d 2>/dev/null | grep -c "BEGIN CERTIFICATE" || echo "0")

    if [ "$ROOTCA_COUNT" = "0" ]; then
        echo "❌ Could not parse ROOTCA certificates"
        echo ""
        echo "Debug: ROOTCA structure:"
        echo "$ROOTCA_JSON" | jq '.secret.validationContext' 2>/dev/null || echo "Failed to parse"
    else
        echo "✓ Found ROOTCA in Envoy with ${ROOTCA_COUNT} certificate(s)"
        echo ""

        if [ "$ROOTCA_COUNT" -eq 1 ]; then
            echo "⚠️  WARNING: Only 1 CA certificate found"
            echo "   Expected: 2 (Istio CA + Defakto CA)"
            echo "   This suggests multi-root trust is NOT working"
        elif [ "$ROOTCA_COUNT" -eq 2 ]; then
            echo "✓ SUCCESS: 2 CA certificates found"
            echo "   This suggests multi-root trust IS working!"
        else
            echo "ℹ️  Found ${ROOTCA_COUNT} CA certificates"
            echo "   (Expected 2: Istio CA + Defakto CA)"
        fi
        echo ""

        echo "Certificate details:"
        echo ""
        echo "$ROOTCA_CERTS" | base64 -d 2>/dev/null | \
            awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/ {cert=cert $0 "\n"} /END CERTIFICATE/ {print cert | "openssl x509 -subject -issuer -dates -noout 2>/dev/null"; cert=""; print ""}'
    fi
fi

# Step 4: Check workload certificate
echo ""
echo "Step 4: Checking workload certificate"
echo "----------------------------------------------"
echo ""

kubectl exec -n ${NAMESPACE} ${POD} -c istio-proxy -- pilot-agent request GET certs 2>/dev/null | \
    jq -r '.certificates[0].cert_chain[0] |
    "Subject: " + (.subject_alt_names[0].uri // "N/A") + "\n" +
    "Valid from: " + .valid_from + "\n" +
    "Expires: " + .expiration_time' 2>/dev/null || echo "Could not retrieve certificate info"

echo ""
echo "=============================================="
echo "Verification Complete"
echo "=============================================="
echo ""

if [ "$ROOTCA_COUNT" -eq 2 ]; then
    echo "✓ Multi-root trust appears to be working correctly"
    echo ""
    echo "Next steps:"
    echo "  1. Deploy a SPIRL workload: kubectl apply -f k8s/app/spirl-workload.yaml"
    echo "  2. Test cross-CA communication"
else
    echo "⚠️  Multi-root trust may not be working correctly"
    echo ""
    echo "Troubleshooting steps:"
    echo "  1. Check istiod logs: kubectl logs -n istio-system deployment/istiod | grep -i 'certificate\\|ca\\|error'"
    echo "  2. Verify mesh config: kubectl get configmap istio -n istio-system -o yaml"
    echo "  3. Check if pods were restarted: kubectl get pods -n ${NAMESPACE}"
    echo "  4. Try restarting pods: kubectl rollout restart deployment -n ${NAMESPACE}"
fi
echo ""
