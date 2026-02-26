# Quick Start: Multi-Root Trust (Experimental)

This is a streamlined guide to test the experimental multi-root trust configuration using `meshConfig.caCertificates` and `trustDomainAliases`.

## Prerequisites

- Kubernetes cluster (kind, GKE, EKS, etc.)
- `istioctl` v1.18+ installed
- `kubectl` configured
- Defakto trust domain set up
- SPIRL bundle endpoint URL

## Quick Start (5 Steps)

### 1. Set environment variables

```bash
export TRUST_DOMAIN="example.org"
export SPIRL_BUNDLE_ENDPOINT="https://fed.spirl.org/t-{your-tenant}/td-{your-domain}/bundle"
```

### 2. Install Istio with standard CA

```bash
# Start from clean state
./k8s/istio/install-istio.sh

# Deploy bookinfo
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.28/samples/bookinfo/platform/kube/bookinfo.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.28/samples/bookinfo/networking/bookinfo-gateway.yaml

# Verify - should show 1 CA cert (Istio)
./verify-multiroot.sh
```

### 3. Apply multi-root configuration

```bash
./k8s/istio/apply-multiroot-experimental.sh
```

This will:
- Fetch the Defakto trust bundle
- Apply Istio configuration with `meshConfig.caCertificates`
- Enable `ISTIO_MULTIROOT_MESH` and `PROXY_CONFIG_XDS_AGENT`
- Add trust domain alias for your Defakto domain
- Restart istiod

### 4. Restart workloads and verify

```bash
# Restart bookinfo pods to pick up new trust config
kubectl rollout restart deployment -n bookinfo

# Wait for rollout
kubectl rollout status deployment -n bookinfo productpage-v1
kubectl rollout status deployment -n bookinfo details-v1

# Verify - should show 2 CA certs (Istio + Defakto)
./verify-multiroot.sh
```

**Success criteria**: `verify-multiroot.sh` shows **2 certificates** in ROOTCA

### 5. Test with SPIRL workload

```bash
# Add cluster to Defakto
spirlctl cluster add istio-trust-federation \
  --trust-domain $TRUST_DOMAIN \
  --platform istio

# Enable SPIRL certificates for the details service
./enable-spirl-for-service.sh details-v1 bookinfo

# Test cross-CA communication
kubectl exec -n bookinfo deployment/productpage-v1 -c productpage -- \
  python -c "import requests; print(requests.get('http://details:9080/details/0').text)"
```

**Success criteria**: The request succeeds and returns JSON data.

## Verification Checklist

✓ Mesh configuration shows:
  - `trustDomain: cluster.local`
  - `trustDomainAliases` includes your Defakto domain
  - `caCertificates` section with Defakto CA

✓ Feature flags enabled:
  - `ISTIO_MULTIROOT_MESH: "true"` in istiod
  - `PROXY_CONFIG_XDS_AGENT: "true"` in proxies

✓ Envoy ROOTCA contains 2 certificates:
  - Istio CA (cluster.local)
  - Defakto CA (your trust domain)

✓ SPIRL workload has correct SPIFFE ID:
  - Format: `spiffe://<your-trust-domain>/ns/bookinfo/sa/...`

✓ Cross-CA communication succeeds

## Troubleshooting

### Still seeing only 1 CA certificate?

```bash
# Check mesh config was applied
kubectl get configmap istio -n istio-system -o yaml | grep -A 20 caCertificates

# Check feature flags
kubectl get deployment istiod -n istio-system -o yaml | grep ISTIO_MULTIROOT_MESH

# Check istiod logs
kubectl logs -n istio-system deployment/istiod | tail -50

# Force restart
kubectl rollout restart deployment/istiod -n istio-system
kubectl delete pods -n bookinfo --all
```

### Communication failing?

Try the more permissive configuration:

```bash
# Edit apply-multiroot-experimental.sh
# Change: cp k8s/istio/istio-multiroot-experimental.yaml
# To: cp k8s/istio/istio-multiroot-permissive.yaml

# Then re-run
./k8s/istio/apply-multiroot-experimental.sh
```

### Need more details?

See [MULTIROOT-EXPERIMENTAL.md](./MULTIROOT-EXPERIMENTAL.md) for:
- Detailed explanation of each setting
- Known issues and GitHub references
- Comparison with certificate concatenation approach
- Advanced troubleshooting

## Comparison with Certificate Concatenation

This experimental approach differs from the proven certificate concatenation method:

| Feature | meshConfig (Experimental) | Certificate Concatenation (Proven) |
|---------|--------------------------|-------------------------------------|
| Method | `meshConfig.caCertificates` | Concatenate CAs in `cacerts` secret |
| Scripts | `apply-multiroot-experimental.sh` | `add-trust-bundle.sh` |
| Reliability | ⚠️ Experimental | ✓ Proven to work |
| Setup | Single configuration file | Script-based |
| Maintenance | Declarative updates | Manual updates |

**If this doesn't work**, fall back to the certificate concatenation method which is documented in the main [README.md](./README.md).

## Files

- `k8s/istio/istio-multiroot-experimental.yaml` - Strict configuration
- `k8s/istio/istio-multiroot-permissive.yaml` - Permissive configuration
- `k8s/istio/apply-multiroot-experimental.sh` - Apply script
- `verify-multiroot.sh` - Verification script
- `enable-spirl-for-service.sh` - Enable SPIRL for a specific service

## Next Steps

If this works:
1. Test with multiple services using SPIRL certificates
2. Verify certificate rotation works correctly
3. Test under load
4. Document findings and share with Istio community

If this doesn't work:
1. Use the certificate concatenation approach (proven to work)
2. Document attempt in issue report to Istio
3. Consider contributing improvements to Istio
