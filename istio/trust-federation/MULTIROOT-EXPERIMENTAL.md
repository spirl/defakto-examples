# Multi-Root Trust: meshConfig Approach

> **✅ STATUS: VERIFIED WORKING (February 2026)**
>
> This approach has been successfully tested and verified with Istio 1.28.3.
> The key requirement is combining `trustDomainAliases` + `caCertificates` + feature flags.

This document describes a declarative approach to configuring multi-root trust in Istio using `meshConfig.caCertificates` and `trustDomainAliases`.

## Objective

Enable Istio workloads to trust certificates from **both**:
1. Istio's built-in CA (trust domain: `cluster.local`)
2. Defakto/SPIRL CA (trust domain: `example.org` or custom)

**WITHOUT** replacing the Istio CA, but **adding** the Defakto CA to the trust bundle.

## Why This Approach?

The current demo uses **certificate concatenation** into the `cacerts` secret, which works but requires manual maintenance. The `meshConfig.caCertificates` approach is:

- ✓ More declarative (configuration as code)
- ✓ Designed for federation scenarios
- ✓ Supports dynamic trust bundle updates
- ✓ Documented in Istio's official API

However, it has had reliability issues in previous Istio versions and requires specific feature flags.

## Key Configuration Elements

### 1. meshConfig.trustDomainAliases

```yaml
meshConfig:
  trustDomain: cluster.local
  trustDomainAliases:
    - example.org
```

**Purpose**: Tells Istio to recognize and trust identities from the `example.org` trust domain.

**Important**: While primarily used for authorization policies, `trustDomainAliases` is **required** for Istio to fetch CA certificates for federated domains. ([Source](https://github.com/istio/istio/issues/57399))

### 2. meshConfig.caCertificates

```yaml
meshConfig:
  caCertificates:
    - pem: |
        -----BEGIN CERTIFICATE-----
        [Defakto CA certificate]
        -----END CERTIFICATE-----
      certSigners:
        - "spiffe://example.org"
```

**Purpose**: Adds the Defakto CA certificate to Envoy's trusted CA bundle.

**Options**:
- `pem`: PEM-encoded certificate(s)
- `certSigners`: SPIFFE IDs that this CA signs for (optional but recommended)
- `trustDomains`: Trust domains this CA is valid for (optional)

### 3. Feature Flags

#### Required in Pilot (istiod)

```yaml
values:
  pilot:
    env:
      ISTIO_MULTIROOT_MESH: "true"
```

**Purpose**: Enables multi-root mesh support in the control plane.

#### Required in Proxies

```yaml
meshConfig:
  defaultConfig:
    proxyMetadata:
      PROXY_CONFIG_XDS_AGENT: "true"
```

**Purpose**: Enables XDS agent in proxies to process additional CA certificates.

### 4. Optional: Permissive Mode

```yaml
values:
  pilot:
    env:
      PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
```

**Purpose**: Skips strict trust domain validation. Use if the strict configuration doesn't work.

**Warning**: This is less secure and should only be used for testing.

## Available Configurations

We provide two experimental configurations:

### Configuration 1: Strict (Recommended)

**File**: `k8s/istio/istio-multiroot-experimental.yaml`

- Uses `certSigners` to restrict the Defakto CA to its trust domain
- Includes `trustDomainAliases` for the Defakto trust domain
- More secure but may be more sensitive to configuration issues

**Apply with**:
```bash
export TRUST_DOMAIN="example.org"
export SPIRL_BUNDLE_ENDPOINT="https://fed.spirl.org/t-{id}/td-{id}/bundle"
./k8s/istio/apply-multiroot-experimental.sh
```

### Configuration 2: Permissive

**File**: `k8s/istio/istio-multiroot-permissive.yaml`

- Adds `PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"`
- No `certSigners` restriction on the CA certificate
- More permissive but may work in cases where strict doesn't

**Apply with**:
```bash
# Edit the apply script to use istio-multiroot-permissive.yaml
# Then run:
./k8s/istio/apply-multiroot-experimental.sh
```

## Testing Procedure

### Step 1: Start with clean Istio installation

```bash
# Start with the standard Istio installation
./k8s/istio/install-istio.sh
```

### Step 2: Deploy bookinfo and verify baseline

```bash
# Deploy bookinfo
kubectl apply -f k8s/app/bookinfo.yaml

# Verify single CA certificate (Istio's)
./verify-multiroot.sh
```

Expected: 1 CA certificate in ROOTCA

### Step 3: Apply multi-root configuration

```bash
# Set environment variables
export TRUST_DOMAIN="example.org"
export SPIRL_BUNDLE_ENDPOINT="https://fed.spirl.org/..."

# Apply the experimental configuration
./k8s/istio/apply-multiroot-experimental.sh
```

### Step 4: Restart workloads and verify

```bash
# Restart bookinfo pods
kubectl rollout restart deployment -n bookinfo

# Wait for rollout
kubectl rollout status deployment -n bookinfo productpage-v1

# Verify multiple CA certificates
./verify-multiroot.sh
```

Expected: 2 CA certificates in ROOTCA (Istio + Defakto)

### Step 5: Add cluster to Defakto

```bash
spirlctl cluster add istio-trust-federation \
  --trust-domain $TRUST_DOMAIN \
  --platform istio
```

### Step 6: Deploy SPIRL workload

Pick one of the bookinfo services to use SPIRL certificates. We'll use `details` as an example:

```bash
# Label the details deployment to use SPIRL certificates
kubectl patch deployment details-v1 -n bookinfo -p '{"spec":{"template":{"metadata":{"labels":{"k8s.spirl.com/spiffe-csi":"enabled"}}}}}'

# Restart to pick up the CSI volume
kubectl rollout restart deployment/details-v1 -n bookinfo
```

### Step 7: Verify cross-CA communication

```bash
# Test from productpage (Istio cert) to details (SPIRL cert)
kubectl exec -n bookinfo deployment/productpage-v1 -c productpage -- \
  python -c "import requests; print(requests.get('http://details:9080/details/0').text)"

# Should return JSON if successful
```

## Verification Details

The `verify-multiroot.sh` script checks:

1. **Mesh configuration**: Trust domain and aliases
2. **Feature flags**: `ISTIO_MULTIROOT_MESH`, `PROXY_CONFIG_XDS_AGENT`
3. **Envoy's ROOTCA secret**: Number of CA certificates
4. **Workload certificates**: SPIFFE IDs and expiration

### Success Criteria

✓ Envoy ROOTCA contains **2 certificates**:
  - Istio CA (subject includes `cluster.local`)
  - Defakto CA (subject includes your trust domain)

✓ Workload certificates have correct SPIFFE IDs:
  - Istio workloads: `spiffe://cluster.local/ns/...`
  - SPIRL workloads: `spiffe://example.org/ns/...`

✓ Cross-CA communication succeeds

## Troubleshooting

### Only 1 CA certificate in Envoy

**Possible causes**:
1. Feature flags not enabled correctly
2. Mesh configuration not applied
3. Pods not restarted after config change
4. Bug in Istio version

**Steps**:
```bash
# Check mesh config
kubectl get configmap istio -n istio-system -o yaml | grep -A 20 caCertificates

# Check feature flags
kubectl get deployment istiod -n istio-system -o yaml | grep ISTIO_MULTIROOT_MESH

# Check istiod logs for errors
kubectl logs -n istio-system deployment/istiod | grep -i "certificate\|error"

# Force pod restart
kubectl delete pod -n bookinfo --all
```

### Certificates found but communication fails

**Possible causes**:
1. `certSigners` mismatch
2. Trust domain validation issues
3. SPIFFE ID format problems

**Steps**:
```bash
# Try permissive configuration
# Edit apply script to use istio-multiroot-permissive.yaml
./k8s/istio/apply-multiroot-experimental.sh

# Check Envoy logs for TLS errors
kubectl logs -n bookinfo deployment/productpage-v1 -c istio-proxy | grep -i tls

# Verify SPIFFE IDs match expected format
kubectl exec -n bookinfo deployment/productpage-v1 -c istio-proxy -- \
  pilot-agent request GET certs
```

### Configuration not applying

**Steps**:
```bash
# Check istioctl version (should be 1.18+)
istioctl version

# Manually apply and check for errors
istioctl install -f k8s/istio/istio-multiroot-experimental.yaml

# Check IstioOperator status
kubectl get istiooperator -n istio-system -o yaml
```

## Known Issues and Limitations

### GitHub Issues

- [#39935](https://github.com/istio/istio/issues/39935) - Workload doesn't trust additional root certificates (supposedly fixed)
- [#55442](https://github.com/istio/istio/issues/55442) - caCertificates doesn't work as expected (stale, ongoing issues)
- [#50420](https://github.com/istio/istio/issues/50420) - ISTIO_MULTIROOT_MESH for rotation (limited support)
- [#37096](https://github.com/istio/istio/issues/37096) - Cross-cluster trust domain issues (fixed in 1.12+)

### Version Compatibility

- ✓ Istio 1.12+: Fixes for cross-cluster trust
- ✓ Istio 1.18+: Better multi-root support
- ⚠️ Istio 1.22+: Some reports of issues with external Envoy
- ✓ Istio 1.28.3: (current version in this demo)

## Comparison with Certificate Concatenation

| Aspect | meshConfig Approach | Certificate Concatenation |
|--------|-------------------|--------------------------|
| Declarative | ✓ Yes | ✗ Script-based |
| Istio Native | ✓ Yes | ⚠️ Workaround |
| Reliability | ⚠️ Experimental | ✓ Proven |
| Maintenance | ✓ Easy updates | ⚠️ Manual updates |
| Documentation | ⚠️ Limited | ✓ Well documented |

## References

- [Istio MeshConfig API](https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/)
- [Istio Certificate Management](https://istio.io/latest/docs/tasks/security/cert-management/)
- [Istio Trust Domain Migration](https://istio.io/latest/docs/tasks/security/authorization/authz-td-migration/)
- [SPIFFE Trust Domain and Bundle](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/#trust-domain-and-bundle)

## Next Steps if This Works

If this experimental approach works:

1. Document the exact configuration that succeeded
2. Test with more complex scenarios (multiple workloads, stress testing)
3. Verify certificate rotation works correctly
4. Consider updating the main README to use this approach
5. Report findings to Istio community

## Next Steps if This Doesn't Work

If this approach still doesn't work:

1. Stick with certificate concatenation (proven to work)
2. Document this attempt in Appendix B of the main README
3. Consider filing a detailed bug report with Istio
4. Explore alternative approaches (e.g., custom CA integration)
