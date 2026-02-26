# Multi-Root Trust with meshConfig: Findings and Status

**Date:** February 13, 2026
**Istio Version:** 1.28.3
**Status:** 🟡 PARTIAL SUCCESS - Istio configured correctly, but cross-CA mTLS blocked by SPIRL agent limitation

## Summary

We successfully configured multi-root trust in Istio using the
`meshConfig.caCertificates` approach. Istio workloads now have 2 CA
certificates in their ROOTCA bundles (verified). However, **cross-CA
mTLS communication is not working** due to a limitation in how the
SPIRL agent delivers trust bundles via SPIFFECertValidatorConfig.

**What Works:**
- ✅ Istio configured with multiple CAs via `meshConfig.caCertificates`
- ✅ Trust domain aliases properly set
- ✅ All workloads have 2 CAs in their ROOTCA bundles
- ✅ Istio → Istio mTLS works (both using cluster.local)

**What Doesn't Work:**
- ❌ Istio → SPIRL mTLS fails (cluster.local → defakto.example.com)
- ❌ SPIRL agent delivers only one trust domain entry in SPIFFECertValidatorConfig
- ❌ Details pod rejects productpage's certificate with `CERTIFICATE_VERIFY_FAILED`

**Root Cause:**
The SPIRL agent's `--supplemental-roots-file` flag merges all CAs into
the primary trust domain's bundle instead of creating separate trust
domain entries. See [FINDINGS-SPIRL.md](FINDINGS-SPIRL.md) for detailed
analysis and proposed solution.

## What We Achieved

✅ **Istio configuration successful:**
- Configured Istio to trust two CAs via `meshConfig.caCertificates`
- Istio's built-in CA (trust domain: `cluster.local`)
- Defakto/SPIRL CA (trust domain: `defakto.example.com`)

✅ **Configuration is declarative:**
- No manual secret manipulation required
- Standard IstioOperator configuration
- Can be version-controlled and GitOps-friendly

✅ **Verification confirmed:**
- 2 CA certificates in Envoy's ROOTCA bundle (both Istio and SPIRL pods)
- Feature flags properly enabled
- Trust domain aliases configured
- CA certificates loaded into mesh

❌ **Cross-CA mTLS not working:**
- Workloads using SPIRL certificates cannot validate Istio certificates
- SPIRL agent delivers ROOTCA with only one trust domain entry
- See [SPIRL Integration Issue](#spirl-integration-issue-spiffecertvalidatorconfig-format) below

## The Missing Piece: trustDomainAliases

Previous attempts at using `meshConfig.caCertificates` failed because
we didn't include `trustDomainAliases`. Research revealed this
critical requirement:

**From [Istio Issue #57399](https://github.com/istio/istio/issues/57399):**

> "Without domains listed in trustDomain or trustDomainAliases, Istio
> will not fetch the CA certificates" for federated domains.

While `trustDomainAliases` is often described as being "for
authorization policies," it has a second critical function: **telling
Istio which trust domains to fetch and trust CA certificates for**.

## Complete Working Configuration

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
spec:
  profile: default

  values:
    pilot:
      env:
        # Feature flag #1: Enable multi-root mesh
        ISTIO_MULTIROOT_MESH: "true"

  meshConfig:
    # Primary trust domain
    trustDomain: cluster.local

    # ⭐ THE MISSING PIECE ⭐
    # Without this, caCertificates won't work!
    trustDomainAliases:
      - defakto.example.com

    defaultConfig:
      proxyMetadata:
        # Feature flag #2: Enable XDS agent
        PROXY_CONFIG_XDS_AGENT: "true"

    # Additional CA certificates
    caCertificates:
      - pem: |
          -----BEGIN CERTIFICATE-----
          [Defakto CA certificate in PEM format]
          -----END CERTIFICATE-----
        # Optional but recommended: restrict to specific signers
        certSigners:
          - "spiffe://defakto.example.com"
```

## Why Previous Attempts Failed

### Attempt 1: Missing trustDomainAliases
```yaml
# ❌ This doesn't work
meshConfig:
  trustDomain: cluster.local
  # Missing: trustDomainAliases
  caCertificates:
    - pem: |
        [certificate]
```

**Result:** Envoy only had 1 CA certificate (Istio's). The Defakto CA
was ignored because Istio didn't know to fetch/trust it.

### Attempt 2: Feature flags but no trustDomainAliases
```yaml
# ❌ This doesn't work either
values:
  pilot:
    env:
      ISTIO_MULTIROOT_MESH: "true"
meshConfig:
  defaultConfig:
    proxyMetadata:
      PROXY_CONFIG_XDS_AGENT: "true"
  caCertificates:
    - pem: |
        [certificate]
```

**Result:** Same issue. Feature flags enable the multi-root
capability, but without `trustDomainAliases`, Istio doesn't know which
domains to trust.

### Attempt 3: All three components (SUCCESS!)
```yaml
# ✅ This works!
values:
  pilot:
    env:
      ISTIO_MULTIROOT_MESH: "true"
meshConfig:
  trustDomain: cluster.local
  trustDomainAliases:          # ⭐ Added this!
    - defakto.example.com
  defaultConfig:
    proxyMetadata:
      PROXY_CONFIG_XDS_AGENT: "true"
  caCertificates:
    - pem: |
        [certificate]
      certSigners:
        - "spiffe://defakto.example.com"
```

**Result:** Envoy has 2 CA certificates. Multi-root trust works!

## Key Insights

### 1. Three Components Must Work Together

The configuration requires **all three** of these components:

| Component | Purpose | Without It |
|-----------|---------|------------|
| `ISTIO_MULTIROOT_MESH` | Enables multi-root support in control plane | Feature disabled |
| `PROXY_CONFIG_XDS_AGENT` | Enables multi-root support in data plane | Proxies ignore extra CAs |
| `trustDomainAliases` | Tells Istio which domains to trust | CAs not fetched/trusted |

### 2. trustDomainAliases Has Dual Purpose

Documentation emphasizes `trustDomainAliases` for authorization
policies, but it's also **required for CA certificate trust**. This
dual purpose is not well documented.

### 3. certSigners is Optional but Recommended

The `certSigners` field restricts the CA to specific SPIFFE trust
domains:

```yaml
caCertificates:
  - pem: |
      [certificate]
    certSigners:
      - "spiffe://defakto.example.com"
```

This provides better security by ensuring the CA can only sign for its
intended trust domain.

### 4. Verification is Critical

Use this command to verify multi-root trust is working:

```bash
POD=$(kubectl get pod -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config secret ${POD}.bookinfo -o json | \
  jq '.dynamicActiveSecrets[] | select(.name == "ROOTCA") |
      .secret.validationContext.trustedCa.inlineBytes' | \
  base64 -d | \
  grep -c "BEGIN CERTIFICATE"
```

Expected output: `2` (or more if multiple CAs)

## Comparison with Certificate Concatenation

Both approaches achieve the same goal: trusting multiple CAs.

### meshConfig Approach

**Pros:**
- ✅ Declarative (IstioOperator)
- ✅ GitOps-friendly
- ✅ Istio-native
- ✅ No manual secret manipulation

**Cons:**
- ⚠️ Requires feature flags
- ⚠️ More complex configuration
- ⚠️ Less documented
- ⚠️ Newly verified (Feb 2026)

### Certificate Concatenation Approach

**Pros:**
- ✅ Simple and direct
- ✅ Works in all Istio versions
- ✅ No feature flags needed
- ✅ Well documented (KubeCon 2024)
- ✅ Battle-tested

**Cons:**
- ⚠️ Script-based (not declarative)
- ⚠️ Requires manual secret updates
- ⚠️ Less GitOps-friendly

## Recommendation

**For Istio-only multi-root trust:**
- ✅ Use **meshConfig approach** (verified working)
- ✅ Declarative, GitOps-friendly
- ✅ All workloads receive multiple CAs correctly

**For Istio + SPIRL federation:**
- ⚠️ **Currently blocked** by SPIRL agent limitation
- ⚠️ Wait for SPIRL agent enhancement
- ⚠️ See [FINDINGS-SPIRL.md](FINDINGS-SPIRL.md) for proposed solution

**Alternative (if urgent):**
- Use **certificate concatenation** approach instead
- Bypasses SPIFFECertValidatorConfig limitation
- Works but less declarative

## Testing Procedure

### Setup

1. Install Istio with standard configuration
2. Deploy test workloads (e.g., bookinfo)
3. Verify single CA (Istio only)

### Apply meshConfig Configuration

```bash
export TRUST_DOMAIN="defakto.example.com"
export SPIRL_BUNDLE_ENDPOINT="https://fed.spirl.org/t-{id}/td-{id}/bundle"
./k8s/istio/apply-multiroot-experimental.sh
```

### Verify

```bash
# Restart workloads
kubectl rollout restart deployment -n bookinfo

# Run verification
./verify-multiroot.sh
```

**Expected output:**
```
✓ Found ROOTCA in Envoy with 2 certificate(s)
✓ SUCCESS: 2 CA certificates found
   This suggests multi-root trust IS working!
```

### Test Cross-CA Communication

1. Enable SPIRL for one service:
   ```bash
   ./enable-spirl-for-service.sh details-v1 bookinfo
   ```

2. Test communication:
   ```bash
   kubectl exec -n bookinfo deployment/productpage-v1 -c productpage -- \
     python -c "import requests; print(requests.get('http://details:9080/details/0').text)"
   ```

3. Verify mTLS:
   ```bash
   kubectl exec -n bookinfo deployment/details-v1 -c istio-proxy -- \
     pilot-agent request GET stats | grep istio_requests_total.*mutual_tls
   ```

## Files Created

- `k8s/istio/istio-multiroot-experimental.yaml` - Strict configuration
- `k8s/istio/istio-multiroot-permissive.yaml` - Permissive variant
- `k8s/istio/apply-multiroot-experimental.sh` - Setup script
- `verify-multiroot.sh` - Verification script
- `enable-spirl-for-service.sh` - Per-service SPIRL enablement
- `MULTIROOT-EXPERIMENTAL.md` - Detailed documentation
- `QUICKSTART-MULTIROOT.md` - Quick start guide
- `FINDINGS.md` - This document

## Next Steps

### For This Demo

- [x] Verify meshConfig approach works for Istio configuration
- [x] Document configuration
- [x] Identify root cause of cross-CA mTLS failure
- [x] Document SPIRL agent limitation
- [ ] Wait for SPIRL agent fix (or implement workaround)
- [ ] Test cross-CA mTLS after SPIRL fix
- [ ] Test with multiple SPIRL workloads
- [ ] Test certificate rotation
- [ ] Performance/scale testing

### For SPIRL Team

- [ ] Review proposed solution in [FINDINGS-SPIRL.md](FINDINGS-SPIRL.md)
- [ ] Implement `--supplemental-trust-domains-config` flag
- [ ] Support multiple trust domain entries in SPIFFECertValidatorConfig
- [ ] Release new SPIRL agent version with federation support

### For Istio Community

Consider contributing back:
1. Document the `trustDomainAliases` requirement more clearly
2. File issue about confusing documentation
3. Propose documentation improvements
4. Share findings with Istio community

## References

### Issues That Helped

- [#57399](https://github.com/istio/istio/issues/57399) - Wildcard trustDomain for SPIRE federation
  - Revealed the `trustDomainAliases` requirement
- [#39935](https://github.com/istio/istio/issues/39935) - Workload doesn't trust additional root certificates
  - Documented the feature flag requirements
- [#37096](https://github.com/istio/istio/issues/37096) - Cross-cluster trust domain issues
  - Confirmed bugs fixed in Istio 1.12+

### Documentation

- [Istio MeshConfig API](https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/)
- [Trust Domain Migration](https://istio.io/latest/docs/tasks/security/authorization/authz-td-migration/)
- [Certificate Management](https://istio.io/latest/docs/tasks/security/cert-management/)

### Related Work

- [Istio Root Cert Rotation](https://github.com/zirain/istio-root-cert-rotation) - KubeCon EU 2024
  - Demonstrates certificate concatenation approach

## Conclusion (Istio Configuration)

The `meshConfig.caCertificates` approach **works correctly** in Istio
1.28.3 when properly configured with `trustDomainAliases`. All workloads
successfully receive multiple CA certificates in their ROOTCA bundles.

**Key learnings:**
1. `trustDomainAliases` is not just for authorization policies - it's
   also required for CA certificate trust in multi-root scenarios
2. Feature flags (`ISTIO_MULTIROOT_MESH` and `PROXY_CONFIG_XDS_AGENT`)
   must both be enabled
3. Istio's configuration works correctly for standard mTLS scenarios

**Remaining blocker:**
Cross-CA mTLS fails when workloads use SPIRL-issued certificates due to
how the SPIRL agent delivers trust bundles. The issue is in the SPIRL
agent, not in Istio's configuration. See the SPIRL Integration Issue
section below for details.

---

# SPIRL Integration Issue: SPIFFECertValidatorConfig Format

**Date:** February 13, 2026
**Status:** 🔴 BLOCKED - Cross-CA mTLS Failing

## Problem Summary

While Istio workloads successfully trust both CAs (verified with 2
certificates in ROOTCA), **cross-CA communication fails** when one
service uses SPIRL-issued certificates. The issue is not with Istio's
configuration, but with how SPIRL's agent delivers the ROOTCA in
SPIFFECertValidatorConfig format.

### Symptom

```bash
kubectl exec -n bookinfo deployment/productpage-v1 -c productpage -- \
  python -c "import requests; print(requests.get('http://details:9080/details/0').text)"
```

**Result:**
```
upstream connect error or disconnect/reset before headers. reset reason: connection termination
```

## Root Cause Analysis

### Configuration Asymmetry

There are **two different formats** for delivering ROOTCA via SDS:

#### 1. Standard Format (Istio CA - productpage)

Used by Istio's istiod when delivering ROOTCA:

```json
{
  "name": "ROOTCA",
  "secret": {
    "validation_context": {
      "trusted_ca": {
        "inline_bytes": "<base64-encoded bundle with both CAs>"
      }
    }
  }
}
```

**Verification command:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
      .dynamic_active_secrets[] | select(.name == "ROOTCA")'
```

#### 2. SPIFFECertValidatorConfig Format (SPIRL CA - details)

Used by SPIRL agent when delivering ROOTCA:

```json
{
  "name": "ROOTCA",
  "secret": {
    "validation_context": {
      "custom_validator_config": {
        "name": "envoy.tls.cert_validator.spiffe",
        "typed_config": {
          "@type": "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.SPIFFECertValidatorConfig",
          "trust_domains": [
            {
              "name": "defakto.example.com",
              "trust_bundle": {
                "inline_bytes": "<base64 with BOTH CAs>"
              }
            }
          ]
        }
      }
    }
  }
}
```

**Verification command:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
      .dynamic_active_secrets[] | select(.name == "ROOTCA")'
```

### The Critical Difference

**SPIFFECertValidatorConfig requires explicit trust domain entries.**

When Envoy validates a certificate:
1. Extracts the SPIFFE ID (e.g., `spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage`)
2. Looks for a matching trust domain entry in the `trust_domains` array
3. Uses that trust domain's CA bundle for validation

**Current state:**
- Details has only ONE trust domain entry: `defakto.example.com`
- Both CAs (Defakto + Istio) are in that trust domain's bundle
- When productpage connects with `spiffe://cluster.local/...` ID, details cannot find a `cluster.local` trust domain entry
- Result: `CERTIFICATE_VERIFY_FAILED`

### Detailed TLS Handshake Failure

**To see the failure in real-time:**

```bash
# Enable debug logging
POD_DETAILS=$(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD_DETAILS} -c istio-proxy -- \
  pilot-agent request POST 'logging?paths=connection:debug' >/dev/null 2>&1

# Make request and see the error
kubectl exec -n bookinfo deployment/productpage-v1 -c productpage -- \
  python -c "import requests; requests.get('http://details:9080/details/0', timeout=2)" 2>&1 || true

# View the TLS error
kubectl logs -n bookinfo ${POD_DETAILS} -c istio-proxy --tail=20 --since=5s | \
  grep -i "tls_error\|certificate"
```

**Expected output:**
```
2026-02-13T01:46:29.050415Z  debug  envoy connection [...]
  remote address:10.244.0.47:60870,
  TLS_error:|268435581:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED:TLS_error_end
```

**From productpage side:**
```
2026-02-13T01:45:46.938527Z  debug  envoy connection [...]
  remote address:10.244.0.46:9080,
  TLS_error:|268436502:SSL routines:OPENSSL_internal:SSLV3_ALERT_CERTIFICATE_UNKNOWN:TLS_error_end
```

- **Details (server):** `CERTIFICATE_VERIFY_FAILED` - Cannot validate client's certificate
- **Productpage (client):** `SSLV3_ALERT_CERTIFICATE_UNKNOWN` - Server rejected certificate

## Trust Bundle Analysis

### Decoding the Trust Bundle

The details pod's trust bundle contains **2 certificates**:

```bash
POD=$(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq -r '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
         .dynamic_active_secrets[] | select(.name == "ROOTCA") |
         .secret.validationContext.customValidatorConfig.typedConfig.trust_domains[0].trust_bundle.inline_bytes' | \
  base64 -d
```

**Certificate 1: Defakto/SPIRL CA**
```
Subject: C=US, O=SPIRL, CN=ks_37zQG4IVU3Ojp3DztqmJ41pmx45
Issuer:  C=US, O=SPIRL, CN=ks_37zQG4IVU3Ojp3DztqmJ41pmx45
```

**Certificate 2: Istio CA** (from supplemental roots)
```
Subject: O=cluster.local
Issuer:  O=cluster.local
```

**Both CAs are present**, but they're associated with only the
`defakto.example.com` trust domain.

### SPIRL Agent Configuration

The SPIRL agent was configured with supplemental roots:

```bash
kubectl create configmap spirl-agent-supplemental-roots -n spirl-system \
  --from-file=istio-ca.pem=<(kubectl get configmap istio-ca-root-cert -n istio-system \
    -o jsonpath='{.data.root-cert\.pem}')

kubectl patch daemonset spirl-agent -n spirl-system --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/args/-",
    "value": "--supplemental-roots-file=/run/spirl/supplemental-roots/istio-ca.pem"
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "supplemental-roots",
      "configMap": {"name": "spirl-agent-supplemental-roots"}
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "supplemental-roots",
      "mountPath": "/run/spirl/supplemental-roots",
      "readOnly": true
    }
  }
]'
```

**Result:** Agent logs show:
```
Loaded supplemental roots  count=1
```

However, the `--supplemental-roots-file` flag adds CAs to the primary
trust domain's bundle, not as separate trust domain entries.

## What's Needed

For SPIFFECertValidatorConfig to work, we need **two separate trust
domain entries**:

```json
{
  "trust_domains": [
    {
      "name": "defakto.example.com",
      "trust_bundle": {
        "inline_bytes": "<Defakto CA>"
      }
    },
    {
      "name": "cluster.local",
      "trust_bundle": {
        "inline_bytes": "<Istio CA>"
      }
    }
  ]
}
```

## Investigation Summary

### Working Configuration (Istio → Istio)

✅ Productpage (Istio CA) → Reviews (Istio CA)
✅ Both have ROOTCA with 2 CAs in standard format
✅ mTLS works correctly

### Failing Configuration (Istio → SPIRL)

❌ Productpage (Istio CA, `cluster.local`) → Details (SPIRL CA, `defakto.example.com`)
❌ Details has 2 CAs but only one trust domain entry
❌ Details rejects productpage's certificate
❌ Error: `CERTIFICATE_VERIFY_FAILED`

### SDS Cluster Configuration

Both pods use `sds-grpc` cluster for certificate delivery:

**Productpage:**
```bash
# Points to Istio's pilot-agent SDS socket
./var/run/secrets/workload-spiffe-uds/socket
```

**Details:**
```bash
# Points to SPIRL agent's SDS socket (via CSI mount)
./var/run/secrets/workload-spiffe-uds/socket
```

The socket path is the same, but the actual socket provider differs:
- Productpage: Istio pilot-agent (delivers standard format)
- Details: SPIRL agent (delivers SPIFFECertValidatorConfig format)

## Open Questions

1. **SPIRL Agent Configuration:** Does the SPIRL agent support
   configuring multiple trust domains with separate CA mappings?

2. **Trust Domain Mapping:** Is there a way to tell the SPIRL agent
   that supplemental roots should be associated with specific trust
   domains?

3. **Alternative Approach:** Should workloads using SPIRL certs get
   their ROOTCA from istiod instead of the SPIRL agent?

4. **Helm Values:** Does `agent.supplementalRootsPEM` in Helm support
   trust domain specifications?

## Next Steps

1. Check SPIRL agent documentation for trust domain configuration
   options
2. Test if Helm values support specifying trust domains for
   supplemental roots
3. Consider hybrid approach: SPIRL for workload certs, istiod for
   ROOTCA
4. Investigate if SPIRL agent needs a feature enhancement to support
   multiple trust domains in SPIFFECertValidatorConfig

## Inspection Commands

### SPIRL Side (SPIFFECertValidatorConfig Format)

**View full ROOTCA secret on details pod:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
      .dynamic_active_secrets[] | select(.name == "ROOTCA")'
```

**View SPIFFECertValidatorConfig structure:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
      .dynamic_active_secrets[] | select(.name == "ROOTCA") |
      .secret.validationContext.customValidatorConfig.typedConfig'
```

**View trust domains array:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
      .dynamic_active_secrets[] | select(.name == "ROOTCA") |
      .secret.validationContext.customValidatorConfig.typedConfig.trust_domains[] | .name'
```

**Decode and view trust bundle certificates:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq -r '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
         .dynamic_active_secrets[] | select(.name == "ROOTCA") |
         .secret.validationContext.customValidatorConfig.typedConfig.trust_domains[0].trust_bundle.inline_bytes' | \
  base64 -d
```

**Count certificates in trust bundle:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq -r '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
         .dynamic_active_secrets[] | select(.name == "ROOTCA") |
         .secret.validationContext.customValidatorConfig.typedConfig.trust_domains[0].trust_bundle.inline_bytes' | \
  base64 -d | grep -c "BEGIN CERTIFICATE"
```

**Show certificate subjects:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq -r '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
         .dynamic_active_secrets[] | select(.name == "ROOTCA") |
         .secret.validationContext.customValidatorConfig.typedConfig.trust_domains[0].trust_bundle.inline_bytes' | \
  base64 -d > /tmp/bundle.pem && \
  echo "=== Certificate 1 ===" && openssl x509 -in /tmp/bundle.pem -noout -subject -issuer && \
  echo "" && echo "=== Certificate 2 ===" && \
  awk '/BEGIN CERTIFICATE/{p++} p==2' /tmp/bundle.pem | openssl x509 -noout -subject -issuer
```

### Istio Side (Standard validation_context Format)

**View full ROOTCA secret on productpage pod:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
      .dynamic_active_secrets[] | select(.name == "ROOTCA")'
```

**View standard validation_context structure:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
      .dynamic_active_secrets[] | select(.name == "ROOTCA") |
      .secret.validationContext'
```

**Check for SPIFFECertValidatorConfig (should be null):**
```bash
POD=$(kubectl get pod -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
      .dynamic_active_secrets[] | select(.name == "ROOTCA") |
      .secret.validationContext.customValidatorConfig.typedConfig'
```

**Decode and view trust bundle certificates:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq -r '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
         .dynamic_active_secrets[] | select(.name == "ROOTCA") |
         .secret.validationContext.trustedCa.inlineBytes' | \
  base64 -d
```

**Count certificates in trust bundle:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq -r '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
         .dynamic_active_secrets[] | select(.name == "ROOTCA") |
         .secret.validationContext.trustedCa.inlineBytes' | \
  base64 -d | grep -c "BEGIN CERTIFICATE"
```

**Show certificate subjects:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq -r '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
         .dynamic_active_secrets[] | select(.name == "ROOTCA") |
         .secret.validationContext.trustedCa.inlineBytes' | \
  base64 -d > /tmp/bundle.pem && \
  echo "=== Certificate 1 ===" && openssl x509 -in /tmp/bundle.pem -noout -subject -issuer && \
  echo "" && echo "=== Certificate 2 ===" && \
  awk '/BEGIN CERTIFICATE/{p++} p==2' /tmp/bundle.pem | openssl x509 -noout -subject -issuer
```

### TLS Debugging

**Enable TLS debug logging:**
```bash
POD=$(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- \
  pilot-agent request POST 'logging?paths=connection:debug' >/dev/null 2>&1
```

**Make test request and view errors:**
```bash
# Make request
kubectl exec -n bookinfo deployment/productpage-v1 -c productpage -- \
  python -c "import requests; requests.get('http://details:9080/details/0', timeout=2)" 2>&1 || true

# View details (server) side error
POD=$(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
echo "=== Details (server) rejecting certificate ==="
kubectl logs -n bookinfo ${POD} -c istio-proxy --tail=20 --since=5s | \
  grep -i "tls_error\|certificate"

# View productpage (client) side error
POD=$(kubectl get pod -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
echo ""
echo "=== Productpage (client) receiving rejection ==="
kubectl logs -n bookinfo ${POD} -c istio-proxy --tail=20 --since=5s | \
  grep -i "tls_error\|certificate"
```

### Key Differences Summary

| Aspect | Productpage (Istio) | Details (SPIRL) |
|--------|---------------------|-----------------|
| Format | Standard `trustedCa` | `SPIFFECertValidatorConfig` |
| Structure | Single `inlineBytes` | `trust_domains[]` array |
| Trust Domains | Implicit (all CAs trusted) | Explicit (per domain) |
| Validation | By CA signature | By SPIFFE ID + CA |
| Path | `.validationContext.trustedCa.inlineBytes` | `.validationContext.customValidatorConfig.typedConfig.trust_domains[].trust_bundle.inlineBytes` |
| SDS Provider | Istio pilot-agent | SPIRL agent (via CSI) |

## SPIRL Codebase Analysis

For detailed analysis of the SPIRL agent codebase and proposed implementation changes, see:

**[FINDINGS-SPIRL.md](FINDINGS-SPIRL.md)** - Comprehensive investigation of:
- How `--supplemental-roots-file` currently works
- Why it doesn't support multi-trust-domain federation
- Code flow through spirl-agent and bundlerefresher
- Proposed solution with implementation plan
- Specific files and functions that need changes

## Files Updated

- `verify-multiroot.sh` - Updated to handle SPIFFECertValidatorConfig format
- `FINDINGS.md` - This document
- `FINDINGS-SPIRL.md` - SPIRL codebase investigation and proposed solution
