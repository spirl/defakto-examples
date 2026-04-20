# Nonstandard SPIFFE ID Demo

Demonstrates how Istio's hardcoded SAN validation breaks when workloads hold
X.509-SVIDs with a non-default SPIFFE ID path, and how DestinationRules fix it.

## Background

Istio auto-mTLS expects every workload's SPIFFE ID to follow the exact form:

```
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
```

When Defakto issues certs using a custom `--path-template` that appends a
workload-specific suffix (e.g. `/wl/<app>`), Istio rejects the connection
because the SAN no longer matches its hardcoded pattern.

Reference: [istio/istio#43105](https://github.com/istio/istio/issues/43105)

### What this demo shows

1. Bookinfo pods receive Defakto-issued SVIDs with nonstandard IDs:
   ```
   spiffe://defakto.example.com/ns/bookinfo/sa/bookinfo-details/wl/details
   ```
2. Without DestinationRules, Envoy rejects these connections.
3. Adding a DestinationRule with an explicit `subjectAltNames` list and
   `mode: ISTIO_MUTUAL` restores mTLS without changing the Istio installation.

## Prerequisites

| Tool | Purpose |
|------|---------|
| `mise` | Tool version manager — installs all required tools automatically; install via `curl https://mise.run \| sh` |
| `kind` | Installed automatically via `mise` |
| `ctlptl` | Installed automatically via `mise` (optional, recommended) |
| `istioctl` | Installed automatically via `mise` (v1.21.6) |
| `tilt` | Installed automatically via `mise` |
| `spirlctl` | Defakto workload registration — must be installed manually |
| `kubectl` | Installed automatically via `mise` |
| `jq` | Installed automatically via `mise` |
| `envsubst` | Installed automatically via `mise` |

> **Istio version:** This demo is tested against Istio **1.21**. The minimum
> supported version is **1.10** (set by `ISTIO_MULTIROOT_MESH`, introduced in
> 1.10.0). See the [Appendix](#appendix-istio-version-requirements) for the
> full per-feature analysis.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `TRUST_DOMAIN` | `defakto.example.com` | SPIFFE trust domain |
| `SPIRL_BUNDLE_ENDPOINT` | `https://fed.spirl.org/t-o9cpowm5yo/td-tph7n4519n/bundle` | Defakto CA bundle URL |

Export these before running any scripts if you want to override the defaults.

> **Note:** If you override `TRUST_DOMAIN`, also update `meshConfig.trustDomainAliases`
> in `k8s/istio/istio-with-defakto-default.yaml` to the same value. That file
> hardcodes `defakto.example.com`; changing only the environment variable will
> cause Istio to reject inbound workload certificates from the new trust domain.

## Starting the demo

### 0. Install required tools

If you don't have `mise` yet:

```bash
curl https://mise.run | sh
```

From the `nonstandard-id` directory, install all pinned tool versions:

```bash
mise install
```

This installs `istioctl` 1.21.6, `kind`, `kubectl`, `tilt`, `ctlptl`, `jq`, and `envsubst`.

`spirlctl` is Defakto-specific and must be installed separately.

> **Note:** `make env-up` runs `mise install` automatically as its first step,
> so this step is optional if you proceed straight to step 1.

### 1. Start the cluster and Tilt

```bash
make env-up
```

This creates a KIND cluster named `istio-nonstandard-id` (with a local registry
if `ctlptl` is available) and opens the Tilt UI.

### 2. Walk through the Tilt stages

The demo is staged — each step must be triggered manually in the Tilt UI:

| Step | Tilt resource | What it does |
|------|---------------|-------------|
| 1 | `install-istio` | Installs Istio with `cluster.local` trust domain |
| 2 | `bookinfo-gateway` | Creates the ingress Gateway and VirtualService |
| 3 | `enforce-strict-mtls` | Applies mesh-wide `STRICT` PeerAuthentication |
| — | *(terminal)* | Register cluster with Defakto — see below |
| 4 | `add-trust-bundle` | Adds the Defakto CA to Istio's `cacerts` secret and restarts istiod |
| 5 | `restart-for-defakto` | Rolls all bookinfo pods to pick up Defakto-issued certs |
| 6 | `apply-destination-rules` | Applies DestinationRules with explicit nonstandard SANs |

Each resource has one or more buttons in the Tilt UI for the action and for
inspection (viewing SPIFFE IDs, running verification, etc.).

**Before triggering step 4**, register the cluster with Defakto from a terminal.
This installs the SPIFFE CSI driver and sets up workload attestation. It
requires the cluster to be running and Istio to be installed (steps 1–3 above):

```bash
spirlctl cluster add istio-nonstandard-id \
  --trust-domain "${TRUST_DOMAIN:-defakto.example.com}" \
  --platform istio \
  --path-template "/ns/{{kubernetes.pod.namespace}}/sa/{{kubernetes.pod.service_account}}/wl/{{kubernetes.pod.label[app]}}"
```

### 3. Observe the problem and apply the fix

After completing Tilt steps 1–5, the bookinfo pods hold Defakto-issued
certificates with nonstandard SPIFFE IDs. Istio's Envoy proxies reject
outbound connections because the SAN no longer matches the expected pattern.
Step 6 fixes this with DestinationRules.

#### After step 5: confirm the nonstandard SPIFFE IDs

Run this in a terminal to inspect the cert on the `details` pod:

```bash
kubectl exec -n bookinfo deployment/details-v1 -c istio-proxy -- \
  pilot-agent request GET certs 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['certificates'][0]['cert_chain'][0]['subject_alt_names'][0]['uri'])"
```

Expected output — note the `/wl/details` suffix that Istio does not expect:

```
spiffe://defakto.example.com/ns/bookinfo/sa/bookinfo-details/wl/details
```

Or use the **Show current SPIFFE IDs** button on the `restart-for-defakto`
resource in Tilt to check all four services at once.

#### After step 5, before step 6: watch the connection fail

```bash
kubectl exec -n bookinfo deployment/productpage-v1 -c productpage -- \
  python3 -c "import requests; print(requests.get('http://details:9080/details/0', timeout=5).status_code)"
```

Expected: `503` — Envoy on `productpage` rejects the server certificate from
`details` because the SAN `...bookinfo-details/wl/details` does not match its
hardcoded expected pattern `...bookinfo-details`.

The proxy startup log confirms Defakto certs are in use:

```bash
kubectl logs -n bookinfo deployment/productpage-v1 -c istio-proxy | grep "workload SDS\|file mounted"
```

Expected output:

```
Existing workload SDS socket found at var/run/secrets/workload-spiffe-uds/socket. Default Istio SDS Server will only serve files
Workload is using file mounted certificates. Skipping connecting to CA
```

This confirms `istio-proxy` is reading certs from the Defakto CSI socket
rather than from istiod. Envoy logs the TLS rejection at `warning` level
but filters it at startup; the 503 status code is the observable effect.

#### Preview the fix before applying

Before applying, review what DestinationRules will be created and why:

```bash
./k8s/istio/preview-destination-rules.sh
```

Or use the **Preview DestinationRules** button on the `apply-destination-rules`
resource in Tilt.

The preview shows, for each bookinfo service, the `subjectAltNames` override
that tells Envoy to accept the nonstandard `/wl/<app>` SAN, and renders the
full YAML that will be applied.

#### After step 6: watch the connection succeed

Trigger **Apply DestinationRules (Fix SAN Validation)** in Tilt, then repeat
the same request:

```bash
kubectl exec -n bookinfo deployment/productpage-v1 -c productpage -- \
  python3 -c "import requests; print(requests.get('http://details:9080/details/0', timeout=5).status_code)"
```

Expected: `200` — the DestinationRule for `details` tells Envoy to accept the
nonstandard SAN, so mTLS succeeds.

### 4. Verify

After completing all six stages, run the verification script:

```bash
./verify-nonstandard-id.sh
```

Or use the **Run full verification** button on the `apply-destination-rules`
resource in Tilt.

The script checks:
- Each bookinfo pod holds a SPIFFE ID matching `spiffe://defakto.example.com/ns/bookinfo/sa/bookinfo-<svc>/wl/<svc>`
- All four `*-nonstandard-id` DestinationRules exist
- An mTLS request counter in Envoy increments after a live request

## Teardown

Stop Tilt and delete the cluster:

```bash
make env-down
```

To reset (delete and recreate from scratch):

```bash
make env-reset
```

---

## Appendix: Istio Version Requirements

**Tested with:** Istio 1.21 (`istioctl` v1.21.x)
**Minimum supported:** Istio **1.10.0**

The minimum version is the latest of the four feature introduction dates below.
All four features must be present simultaneously for the demo to work.

| Feature | Min Version | Source |
|---------|-------------|--------|
| `ISTIO_MULTIROOT_MESH` pilot env var | **1.10.0** ← binding | [PR #31700](https://github.com/istio/istio/pull/31700) (Mar 2021) |
| `sidecarInjectorWebhook.templates` named injection templates | 1.9.0 | [PR #29728](https://github.com/istio/istio/pull/29728) (Dec 2020) |
| `meshConfig.trustDomainAliases` | 1.4.0 | API added 1.4; TCP mTLS enforcement from 1.7 |
| `subjectAltNames` in `DestinationRule.spec.trafficPolicy.tls` | 0.8.0 | Original `networking.v1alpha3` API |

### ISTIO_MULTIROOT_MESH (binding constraint)

`ISTIO_MULTIROOT_MESH` is a pilot environment variable that allows the mesh to
accept certificates signed by more than one trust anchor for `ISTIO_MUTUAL`
mTLS. It is what permits Envoy's inbound listeners to accept Defakto-issued
certs (trust domain `defakto.example.com`) alongside the default Istio CA
(`cluster.local`).

It was introduced in Istio 1.10.0 via [PR #31700](https://github.com/istio/istio/pull/31700).
It is absent from `pilot/pkg/features/pilot.go` in the `release-1.9` branch
and present in `release-1.10`. It was never mentioned in any Istio release
notes — it shipped as an undocumented experimental knob and remains so. Later
issues [#50420](https://github.com/istio/istio/issues/50420) and
[#52803](https://github.com/istio/istio/issues/52803) reference it, confirming
it has been present since 1.10.

### Named Injection Templates (1.9.0)

`sidecarInjectorWebhook.templates` and the `inject.istio.io/templates` pod
annotation enable the `spirl` custom template, which replaces the
`workload-socket` emptyDir with the actual SPIFFE CSI volume. Without this
template, istio-proxy cannot reach the Defakto CSI socket.

The feature shipped in Istio 1.9.0 via [PR #29728](https://github.com/istio/istio/pull/29728)
(December 2020). Like `ISTIO_MULTIROOT_MESH`, it shipped without a release
note mention, but is verifiable in `release-1.9/pkg/kube/inject/webhook.go`.

### meshConfig.trustDomainAliases (1.4.0 / 1.7 for TCP)

`trustDomainAliases` was added to the MeshConfig API in Istio 1.4.0. Its
application to inbound mTLS TCP traffic was extended progressively in 1.5
([PR #17594](https://github.com/istio/istio/pull/17594)) and fully supported
for TCP mTLS in 1.7. The demo's use — accepting inbound mTLS from
`defakto.example.com` on TCP — relies on the 1.7+ behavior, but 1.10
(required by `ISTIO_MULTIROOT_MESH`) already exceeds this.

### subjectAltNames in DestinationRule (0.8.0)

`subjectAltNames` in `DestinationRule.spec.trafficPolicy.tls` has been part
of the `networking.v1alpha3` API since Istio 0.8.0 (pre-GA, June 2018). It is
present in every version anyone would realistically run.
