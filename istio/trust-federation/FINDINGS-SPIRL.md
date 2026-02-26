# SPIRL Codebase Investigation: Supplemental Roots and Trust Domains

**Investigation Date:** February 12, 2026
**SPIRL Repository:** spirl/spirl
**Focus:** How `--supplemental-roots-file` flag works and why it doesn't support multi-trust-domain federation

---

## Executive Summary

The SPIRL agent's `--supplemental-roots-file` flag **merges** supplemental CA certificates into existing trust domain bundles rather than creating separate trust domain entries. This prevents proper multi-trust-domain federation with Istio because the SPIFFECertValidatorConfig requires explicit trust domain entries for each CA.

**Current Behavior:**
- Supplemental roots → merged into primary trust domain bundle
- Result: One trust domain with multiple CAs

**Required Behavior:**
- Supplemental roots → separate trust domain entries
- Result: Multiple trust domains, each with their own CA

---

## How `--supplemental-roots-file` Currently Works

### Code Flow

#### 1. Flag Parsing
**File:** `spirl-agent/cmd/root.go:165`

```go
cfg.SupplementalRootsFile = viper.GetString("supplemental-roots-file")
```

#### 2. Loading Certificates
**File:** `spirl-agent/internal/agent.go:166-173`

```go
var supplementalRoots []*x509.Certificate
if a.c.SupplementalRootsFile != "" {
    supplementalRoots, err = pemutil.LoadCertificates(a.c.SupplementalRootsFile)
    // ...
}
```

#### 3. Adding to Bundles
**File:** `common/bundlerefresher/refresher.go:114-117`

```go
for _, bundle := range event.AddedOrUpdated {
    // Evan's hack for agent side bundle injection
    for _, ca := range r.c.SupplementalRoots {
        bundle.AddX509Authority(ca)  // ← Adds to existing bundle!
    }
}
```

**Problem:** This merges the supplemental CA into **every** trust domain bundle, not as a separate entry.

#### 4. SDS Construction
**File:** `common/endpoints/sdsv3/validationcontext.go:84-93`

```go
func trustDomainConfigFromBundle(bundle *x509bundle.Bundle) *tlsv3.SPIFFECertValidatorConfig_TrustDomain {
    return &tlsv3.SPIFFECertValidatorConfig_TrustDomain{
        Name: bundle.TrustDomain().Name(),
        TrustBundle: &corev3.DataSource{
            Specifier: &corev3.DataSource_InlineBytes{
                InlineBytes: pemutil.EncodeCertificates(bundle.X509Authorities()), // ← All authorities bundled together
            },
        },
    }
}
```

---

## The Problem

### Current Output (Wrong)

The supplemental roots are merged into each trust domain's `trust_bundle`:

```json
{
  "trust_domains": [
    {
      "name": "defakto.example.com",
      "trust_bundle": {
        "inline_bytes": "<DEFAKTO_CA + ISTIO_CA>"  // ← Both CAs bundled
      }
    }
  ]
}
```

### Required Output (Correct)

Federation requires separate trust domain entries:

```json
{
  "trust_domains": [
    {
      "name": "defakto.example.com",
      "trust_bundle": {
        "inline_bytes": "<DEFAKTO_CA>"
      }
    },
    {
      "name": "cluster.local",
      "trust_bundle": {
        "inline_bytes": "<ISTIO_CA>"
      }
    }
  ]
}
```

### Root Cause

The supplemental roots don't carry **trust domain information** - they're just certificates. To properly support federation, each supplemental root needs to be associated with its trust domain name so separate entries can be created in the SPIFFECertValidatorConfig.

---

## Proposed Solution

### Design Overview

Associate supplemental roots with their trust domain names so they can be presented as separate trust domain entries to Envoy.

### Configuration Format Options

#### Option A: Extended Flag Format

```bash
--supplemental-trust-domain cluster.local:/path/to/istio-ca.pem
--supplemental-trust-domain another.example.com:/path/to/other-ca.pem
```

#### Option B: Configuration File (Recommended)

```yaml
# /etc/spirl/supplemental-trust-domains.yaml
- name: "cluster.local"
  roots_file: "/etc/spirl/istio-ca.pem"
- name: "another.example.com"
  roots_file: "/etc/spirl/other-ca.pem"
```

**Recommendation:** Option B is cleaner and more maintainable for multiple trust domains.

---

## Implementation Plan

### Step 1: Add New Config Structure

**File:** `spirl-agent/internal/config.go`

```go
// SupplementalTrustDomain represents an additional trust domain
// to be included in the trust bundle for federation scenarios
type SupplementalTrustDomain struct {
    Name      string
    RootsFile string
}

// In Config struct, replace:
// SupplementalRootsFile string
// With:
SupplementalTrustDomains []SupplementalTrustDomain
```

### Step 2: Update Flag Parsing

**File:** `spirl-agent/cmd/root.go` (around line 325)

Replace the old flag:

```go
rootCmd.PersistentFlags().String("supplemental-trust-domains-config", "",
    "Path to YAML config file defining supplemental trust domains for federation (experimental)")
check(viper.BindPFlag("supplemental-trust-domains-config",
    rootCmd.PersistentFlags().Lookup("supplemental-trust-domains-config")))
```

In `setConfigFromViper()` function (around line 165):

```go
// Load supplemental trust domains from config file
supplementalTrustDomainsConfig := viper.GetString("supplemental-trust-domains-config")
if supplementalTrustDomainsConfig != "" {
    var trustDomains []struct {
        Name      string `yaml:"name"`
        RootsFile string `yaml:"roots_file"`
    }

    configData, err := os.ReadFile(supplementalTrustDomainsConfig)
    if err != nil {
        return fmt.Errorf("failed to read supplemental trust domains config: %v", err)
    }

    if err := yaml.Unmarshal(configData, &trustDomains); err != nil {
        return fmt.Errorf("failed to parse supplemental trust domains config: %v", err)
    }

    for _, td := range trustDomains {
        cfg.SupplementalTrustDomains = append(cfg.SupplementalTrustDomains, agent.SupplementalTrustDomain{
            Name:      td.Name,
            RootsFile: td.RootsFile,
        })
    }
}
```

### Step 3: Update Bundle Refresher

**File:** `common/bundlerefresher/refresher.go`

Update the config structure:

```go
type Config struct {
    Log    *xlog.ContextLogger
    Signer Signer
    Cache  *bundlecache.Cache
    Clock  clock.Clock
    RetryRandomizationFactor float64

    // Replace SupplementalRoots with:
    SupplementalTrustDomains []SupplementalTrustDomain

    ReportToSentry bool
}

type SupplementalTrustDomain struct {
    Name            string
    X509Authorities []*x509.Certificate
}
```

Update the `Run()` method (around line 103):

```go
func (r *Refresher) Run(ctx context.Context) error {
    // ... existing setup code ...

    set := spiffebundle.NewSet()
    var hashes map[string][]byte

    // Add synthetic bundles for supplemental trust domains
    for _, std := range r.c.SupplementalTrustDomains {
        td, err := spiffeid.TrustDomainFromString(std.Name)
        if err != nil {
            return fmt.Errorf("invalid supplemental trust domain %q: %w", std.Name, err)
        }

        bundle := x509bundle.New(td)
        for _, ca := range std.X509Authorities {
            bundle.AddX509Authority(ca)
        }
        set.Add(bundle)
        tempLogger.Info("Added supplemental trust domain",
            zap.String("trustDomain", std.Name),
            zap.Int("authorities", len(std.X509Authorities)))
    }

    for {
        connected := false
        callback := func(event client.BundleSyncEvent) {
            connected = true
            // ... existing logging ...

            changed := false
            for _, bundle := range event.AddedOrUpdated {
                // REMOVE the old hack that added supplemental roots to every bundle
                // Just use the bundle as-is from the server
                tempLogger.Info("Bundle added or updated", zap.Stringer("trustDomain", bundle.TrustDomain()))
                set.Add(bundle)
                changed = true
            }

            for _, td := range event.Removed {
                // Don't remove supplemental trust domains
                isSupplemental := false
                for _, std := range r.c.SupplementalTrustDomains {
                    if td.String() == std.Name {
                        isSupplemental = true
                        break
                    }
                }

                if !isSupplemental {
                    tempLogger.Info("Bundle removed", zap.Stringer("trustDomain", td))
                    set.Remove(td)
                    changed = true
                }
            }

            hashes = event.Hashes
            if changed {
                r.c.Cache.Update(bundlecache.State{
                    Bundles: spiffebundle.NewSet(set.Bundles()...),
                })
            }
        }

        // ... rest of the loop ...
    }
}
```

### Step 4: Update Agent Initialization

**File:** `spirl-agent/internal/agent.go` (around line 165)

```go
// Load supplemental trust domains
var supplementalTrustDomains []bundlerefresher.SupplementalTrustDomain
for _, std := range a.c.SupplementalTrustDomains {
    certs, err := pemutil.LoadCertificates(std.RootsFile)
    if err != nil {
        return fmt.Errorf("unable to load supplemental roots for trust domain %q: %v", std.Name, err)
    }
    supplementalTrustDomains = append(supplementalTrustDomains, bundlerefresher.SupplementalTrustDomain{
        Name:            std.Name,
        X509Authorities: certs,
    })
    a.c.Log.Info(ctx, "Loaded supplemental trust domain",
        zap.String("trustDomain", std.Name),
        zap.Int("authorities", len(certs)))
}

bundleRefresher, err := bundlerefresher.New(bundlerefresher.Config{
    Log:                      a.c.Log.Named("bundleRefresher"),
    Signer:                   syncBundlesClient,
    Cache:                    bundleCache,
    SupplementalTrustDomains: supplementalTrustDomains,
})
```

---

## Usage After Implementation

### Configuration File

Create `/etc/spirl/supplemental-trust-domains.yaml`:

```yaml
- name: "cluster.local"
  roots_file: "/etc/spirl/istio-root-ca.pem"
- name: "another.example.com"
  roots_file: "/etc/spirl/another-ca.pem"
```

### Agent Command

```bash
spirl-agent \
  --supplemental-trust-domains-config /etc/spirl/supplemental-trust-domains.yaml \
  # ... other flags
```

### Expected Result

With these changes, the SDS API will deliver:

```json
{
  "trust_domains": [
    {
      "name": "defakto.example.com",
      "trust_bundle": {
        "inline_bytes": "<DEFAKTO_CA_ONLY>"
      }
    },
    {
      "name": "cluster.local",
      "trust_bundle": {
        "inline_bytes": "<ISTIO_CA>"
      }
    }
  ]
}
```

---

## Testing & Verification

### 1. Check Envoy Config Dump

```bash
POD=$(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo ${POD} -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null | \
  jq '.configs[] | select(.["@type"] == "type.googleapis.com/envoy.admin.v3.SecretsConfigDump") |
      .dynamic_active_secrets[] | select(.name == "ROOTCA") |
      .secret.validationContext.customValidatorConfig.typedConfig.trust_domains[] | .name'
```

**Expected output:**
```
"defakto.example.com"
"cluster.local"
```

### 2. Verify mTLS Between Trust Domains

```bash
kubectl exec -n bookinfo deployment/productpage-v1 -c productpage -- \
  python -c "import requests; print(requests.get('http://details:9080/details/0').text)"
```

**Expected:** Successful response (not 503)

### 3. Use Existing Verification Script

```bash
./verify-multiroot.sh
```

---

## Key Files Modified

| File | Changes |
|------|---------|
| `spirl-agent/internal/config.go` | Add `SupplementalTrustDomain` struct |
| `spirl-agent/cmd/root.go` | Add `--supplemental-trust-domains-config` flag |
| `common/bundlerefresher/refresher.go` | Create separate bundles per trust domain |
| `spirl-agent/internal/agent.go` | Load and pass supplemental trust domains |
| `common/endpoints/sdsv3/validationcontext.go` | No changes needed (already correct) |

---

## Related Issues

This implementation would resolve:
- Cross-CA mTLS failures in Istio multi-root setups
- SPIFFE federation scenarios requiring multiple trust domains
- Any use case where workloads need to trust CAs from different SPIFFE trust domains

---

## Status

- ❌ **Current:** `--supplemental-roots-file` merges CAs into one trust domain
- 🔄 **Proposed:** `--supplemental-trust-domains-config` creates separate trust domain entries
- ⏳ **Implementation:** Awaiting SPIRL team review and approval
