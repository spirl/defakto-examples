# Istio Trust Federation Demo: Adding the Defakto root CA

## Overview

This demo shows how to add a Defakto CA certificate to the
trust store of an existing Istio service mesh that uses Istio's
built-in CA (`istiod`).

This enables a hybrid deployment where Istio-based workloads can
acquire X.509 certificates from either the default CA or the Defakto
CA (`spirl-server`), and communicate securely via mTLS because they
trust each other's CAs.

*Note: Defakto components are also referred to by the previous SPIRL name.*

## Use Cases

This pattern is useful for:

- **Gradual Defakto adoption**: Migrating to Defakto workload identity
  without disrupting existing Istio workloads
- **Hybrid identity**: Some workloads need Defakto's advanced identity
  features while others use standard Istio
- **Cross-platform Communication**: Istio workloads need to
  communicate with non-Istio workloads that use Defakto

> [!WARNING] SPIFFE CA certificates like those managed by Defakto
> rotate on a frequent basis. This demo shows how to add a new CA
> certificate to the Istio trust store, but does not include code for
> ongoing maintenance and polling of the Defakto trust bundle. See the
> [Server Key
> Rotation](https://d.spirl.com/install/spirl-server/server-rotation)
> section of our documentation for more information about the rotation
> schedule.

## Architecture

The demo progresses through these stages:

### Stage 1: Istio with default CA

```
┌─────────────────────────────────────────┐
│ Istio Mesh (cluster.local)              │
│                                         │
│  Istio CA (istiod)                      │
│       │                                 │
│       ├── Issues cert ──> Service A     │
│       └── Issues cert ──> Service B     │
│                                         │
│  Service A ──mTLS──> Service B ✓        │
└─────────────────────────────────────────┘
```

All workloads get certificates from `istiod` and trust only
certificates from the built-in root CA.

### Stage 2: Add Defakto trust bundle

```
┌──────────────────────────────────────────────────────┐
│ Istio Mesh (cluster.local)                           │
│                                                      │
│  Istio CA (istiod) ───────> Service A (Istio cert)   │
│                             Service B (Istio cert)   │
│                                                      │
│  Defakto CA (example.org) ──> Service C (Defakto)    │
│                                                      │
│  Envoy Trusted CAs:                                  │
│    1. istiod (cluster.local)                         │
│    2. Defakto (example.org)       ← NEW              │
│                                                      │
│  Service A ──mTLS──> Service B ✓ (both Istio certs)  │
│  Service A ──mTLS──> Service C ✓ (Istio ↔ Defakto)   │
│  Service C ──mTLS──> Service B ✓ (Defakto ↔ Istio)   │
└──────────────────────────────────────────────────────┘
```

After adding Defakto's CA to the trust bundle, all workloads trust
both Istio-issued and Defakto-issued certificates.

## Configuration Approach

### meshConfig with trustDomainAliases (Primary Method)

This demo uses Istio's `meshConfig.caCertificates` with
`trustDomainAliases` to configure multi-root trust. This is a
declarative, GitOps-friendly approach that was verified working with
Istio 1.28.3.

**Alternative:** See **Appendix B** for a simpler certificate
concatenation approach that doesn't require feature flags but is less
declarative.

### How It Works

The configuration uses three critical components that work together:

1. **trustDomainAliases** - Tells Istio to recognize and trust the
   Defakto trust domain
2. **caCertificates** - Provides the Defakto CA certificate bundle
3. **Feature flags** - Enables multi-root support in control and data
   planes

**Configuration:**

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    pilot:
      env:
        ISTIO_MULTIROOT_MESH: "true"  # Enable multi-root support

  meshConfig:
    trustDomain: cluster.local

    # CRITICAL: Without this, Istio won't trust federated CAs
    trustDomainAliases:
      - defakto.example.com

    defaultConfig:
      proxyMetadata:
        PROXY_CONFIG_XDS_AGENT: "true"  # Enable in proxies

    # Additional CA certificates
    caCertificates:
      - pem: |
          -----BEGIN CERTIFICATE-----
          [Defakto CA certificate]
          -----END CERTIFICATE-----
        certSigners:
          - "spiffe://defakto.example.com"
```

**Why This Approach:**
- ✓ **Declarative**: Configuration as code, GitOps-friendly
- ✓ **Istio-native**: Uses official meshConfig API
- ✓ **Verified**: Tested and working with Istio 1.28.3
- ✓ **Maintainable**: Update YAML instead of running scripts
- ✓ **Documented**: See [Istio MeshConfig
  API](https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/)

### Workload opt-in methods

There are two ways for workloads to opt into Defakto-issued certificates:

#### Method 1: Label-based (used in this demo)

The SPIRL controller (installed by `spirlctl cluster add`) includes a
mutating webhook that automatically injects the SPIFFE socket for pods
with this label:

```yaml
metadata:
  labels:
    k8s.spirl.com/spiffe-csi: enabled
```

The webhook injects a CSI volume mounted at
`/run/secrets/workload-spiffe-uds` into all containers. Since
`istio-proxy` checks this path for a SPIFFE Workload API socket, it
automatically uses Defakto certificates when the socket is present.

**Advantages:**
- Simple, just requires a label
- Automatic injection via webhook
- No Istio configuration changes needed

#### Method 2: Annotation-based (Istio sidecar template)

Define a custom Istio sidecar template that adds the SPIFFE CSI volume:

```yaml
spec:
  values:
    sidecarInjectorWebhook:
      templates:
        spirl: |
          spec:
            containers:
            - name: istio-proxy
              volumeMounts:
              - name: workload-socket
                mountPath: /run/secrets/workload-spiffe-uds
                readOnly: true
            volumes:
            - name: workload-socket
              csi:
                driver: "csi.spiffe.io"
                readOnly: true
```

Workloads opt in with an annotation:

```yaml
metadata:
  annotations:
    inject.istio.io/templates: "sidecar,spirl"
```

**Advantages:**
- Istio-native approach
- Familiar to Istio users
- Can be combined with other templates

**Both methods mount the SPIFFE socket at the same path, achieving the
same result.**

## Prerequisites

### Tools used in demo

The following tools must be installed:

- **kubectl** - Kubernetes CLI
- **kind** - Kubernetes in Docker
- **Tilt** - For orchestrating the demo ([install
  guide](https://docs.tilt.dev/install.html))
- **istioctl** v1.18+ - Istio CLI ([install
  guide](https://istio.io/latest/docs/setup/getting-started/#download))
- **curl** - For fetching trust bundles from Defakto Bridge (usually
  pre-installed)
- **jq** - For use by scripts

**Optional:**
- **ctlptl** - For managing KIND clusters with registries ([install
  guide](https://github.com/tilt-dev/ctlptl))
  - Without `ctlptl`, create the cluster manually with `kind create
    cluster --name istio-trust-federation`


### Kubernetes cluster

The demo uses a cluster named `istio-trust-federation` by default.

### Defakto Setup

This demo requires:

1. **An existing Defakto trust domain** (e.g., `example.org`)
2. **The SPIFFE Bundle Endpoint URL** for your trust domain. For demo
   purposes, a Defakto-hosted trust domain is more convenient.

Defakto provides an HTTPS endpoint for each trust domain that serves
the SPIFFE trust bundle. This endpoint follows the format:

```
https://fed.spirl.org/t-{tenant-id}/td-{trust-domain-id}/bundle
```

The trust domain's SPIFFE bundle endpoint can be found either via the
UI (https://app.spirl.com) or via `spirlctl trust-domain info
TRUST_DOMAIN`.


## Running the Demo

### Set environment variables

```bash
export TRUST_DOMAIN="example.org"
export SPIRL_BUNDLE_ENDPOINT="https://fed.spirl.org/t-{your-tenant}/td-{your-domain}/bundle"
```

### Step 1: Launch the environment

**Option A: Using ctlptl (recommended)**

```bash
# From the istio-trust-federation directory
ctlptl apply -f ctlptl-cluster-config.yaml

# Start tilt
tilt up
```

**Option B: Using kind directly**

```bash
# Create the cluster
kind create cluster --name istio-trust-federation

# Start Tilt
tilt up
```

**Option C: Using the Makefile**

```bash
make env-up
```
Open the Tilt UI at http://localhost:10350

### Step 2: Install Istio

In the Tilt UI:

1. Click the trigger for **install-istio** to install Istio with its built-in CA
2. Wait for Istio to become ready
3. Click the trigger for **bookinfo-gateway** to deploy the Bookinfo sample app
4. (Optional) Click the trigger for **kiali** for observability

At this point, you have a standard Istio mesh using `istiod` as the CA
in self-signed mode.

### Step 3: Enforce Strict mTLS

By default, Istio uses PERMISSIVE mTLS mode, which allows both
plaintext and mTLS connections. To demonstrate trust federation
properly, we need to enforce STRICT mTLS mode so all communication
uses mTLS.

**Apply the PeerAuthentication policy:**

```bash
kubectl apply -f k8s/istio/peer-authentication-strict.yaml
```

This creates a mesh-wide policy that requires all workloads to use mTLS.

**Verify the policy is applied:**

```bash
# Check the policy exists
kubectl get peerauthentication -n istio-system

# Verify mTLS mode is STRICT for a workload
istioctl x describe pod -n bookinfo $(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
```

Expected output should show:
```
Effective PeerAuthentication:
   Workload mTLS mode: STRICT
```

### Step 4: Verify Istio operation

**Verify web interface:**

Access the bookinfo app at http://localhost:8080/productpage

**Verify sidecars were automatically injected:**

```bash
# Check that pods have the istio-proxy sidecar
kubectl get pods -n bookinfo -o custom-columns='NAME:.metadata.name,CONTAINERS:.spec.containers[*].name,SIDECARS:.spec.initContainers[?(@.name=="istio-proxy")].name'
```

Expected output (each pod should have both app container and istio-proxy):
```
NAME                              CONTAINERS    SIDECARS
details-v1-5f4d584748-abc12       details       istio-proxy
productpage-v1-7f4cc988c6-def34   productpage   istio-proxy
ratings-v1-6c9dbf6b45-ghi56       ratings       istio-proxy
reviews-v2-77c65dc5c5-jkl78       reviews       istio-proxy
reviews-v3-5b5d7f4f4b-mno90       reviews       istio-proxy
```

Each line should show the pod name, the application container, and the
`istio-proxy` sidecar. In Istio 1.29+, the sidecar runs as a
long-running init container rather than a regular container.

**Verify mTLS is working:**

```bash
# View all certificates on the pod
kubectl exec -n bookinfo deployment/productpage-v1 -c istio-proxy -- \
  pilot-agent request GET certs
```

Expected output should show the workload certificate with a SPIFFE ID:
```json
{
 "certificates": [
  {
   "ca_cert": [
    {
     "path": "/var/run/secrets/istio/root-cert.pem",
     "serial_number": "...",
     "valid_from": "2026-02-01T12:00:00Z",
     "expiration_time": "2036-01-30T12:00:00Z"
    }
   ],
   "cert_chain": [
    {
     "path": "/etc/certs/cert-chain.pem",
     "serial_number": "...",
     "subject_alternative_names": [
      {
       "uri": "spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage"
      }
     ],
     "valid_from": "2026-02-02T12:00:00Z",
     "expiration_time": "2026-02-03T12:00:00Z"
    }
   ]
  }
 ]
}
```

Verify that the `subject_alternative_names` field contains a URI like:
```
spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage
```

Test service-to-service communication:
```bash
# Make request from application container (not istio-proxy)
kubectl exec -n bookinfo deployment/productpage-v1 -c productpage -- \
  python -c "import requests; print(requests.get('http://details:9080/details/0').text)"
```

Expected output (JSON response from the details service):
```json
{"id":0,"author":"William Shakespeare","year":1595,"type":"paperback","pages":200,"publisher":"PublisherA","language":"English","ISBN-10":"1234567890","ISBN-13":"123-1234567890"}
```

Check Envoy cluster TLS configuration:
```bash
istioctl proxy-config cluster -n bookinfo deployment/productpage-v1 \
  --fqdn details.bookinfo.svc.cluster.local -o json | \
  jq '.[] | {name: .name, tls: .transportSocketMatches[0].transportSocket.typedConfig.commonTlsContext}'
```

Expected output shows mTLS is configured:
```json
{
  "name": "outbound|9080||details.bookinfo.svc.cluster.local",
  "tls": {
    "tlsParams": {
      "tlsMinimumProtocolVersion": "TLSv1_2",
      "tlsMaximumProtocolVersion": "TLSv1_3"
    },
    "tlsCertificateSdsSecretConfigs": [
      {
        "name": "default",
        "sdsConfig": {...}
      }
    ],
    "combinedValidationContext": {
      "defaultValidationContext": {
        "matchSubjectAltNames": [
          {
            "exact": "spiffe://cluster.local/ns/bookinfo/sa/bookinfo-details"
          }
        ]
      },
      "validationContextSdsSecretConfig": {
        "name": "ROOTCA",
        ...
      }
    }
  }
}
```

Key indicators of mTLS:
- ✓ `tlsCertificateSdsSecretConfigs` - Using certificates from SDS
- ✓ `matchSubjectAltNames` - Validating peer SPIFFE ID
- ✓ `validationContextSdsSecretConfig` with `ROOTCA` - Using CA bundle
  for validation

**Verify mTLS is actually being used:**

Use Istio's stats to see connections are treated as mutual-tls.

**Check Envoy statistics for mTLS connections**

Run the verification script:

```bash
./verify-mtls-stats.sh
```

This script:
1. Gets the current mTLS request count from Envoy stats
2. Makes a test request from productpage to details
3. Checks if the mTLS request count increased
4. Reports success if the counter incremented

**Expected output:**

```
==============================================
Verify mTLS Using Istio Statistics
==============================================

Checking mTLS request count...

mTLS requests before: 2

Making test request from productpage to details...
{"id":0,"author":"William Shakespeare","year":1595,"type":"paperback","pages":200,"publisher":"PublisherA","language":"English","ISBN-10":"1234567890","ISBN-13":"123-1234567890"}

Checking mTLS request count again...
mTLS requests after: 3

✓ SUCCESS: Counter increased from 2 to 3 - mTLS is working!
```

The counter increment confirms that Istio's mutual TLS is actively
being used for the connection.

### Step 5: Add cluster to Defakto trust domain

This step enables the partial migration scenario - some workloads will
use Istio certificates, others will use Defakto-issued certificates.

To add the cluster to your Defakto trust domain:

```bash
spirlctl cluster add istio-trust-federation \
  --trust-domain $TRUST_DOMAIN \
  --platform istio
```

This installs:
- **SPIRL Agent** (DaemonSet) - Provides SPIFFE Workload API on each node
- **SPIFFE CSI Driver** - Mounts the agent socket into pods
- **SPIRL Controller** - Mutating webhook that automatically injects CSI volumes

The SPIRL controller is pre-configured to inject the SPIFFE socket at
`/run/secrets/workload-spiffe-uds/socket` (the path where `istio-proxy` looks
for SPIFFE Workload API endpoints) for any pod with the label:

```yaml
k8s.spirl.com/spiffe-csi: enabled
```

This means workloads can opt into Defakto certificates simply by
adding this label.

### Step 6: Configure Multi-Root Trust (in Istio trust domain)

**This is the key configuration change that this demo demonstrates.**

Apply the meshConfig configuration with `trustDomainAliases` and
`caCertificates`:

```bash
./k8s/istio/apply-multiroot-experimental.sh
```

The script:
1. Fetches the Defakto trust bundle from the HTTPS endpoint
2. Converts JWKS to PEM format if needed
3. Generates Istio configuration with:
   - `trustDomainAliases` for the Defakto trust domain
   - `caCertificates` with the Defakto CA
   - Feature flags (`ISTIO_MULTIROOT_MESH`, `PROXY_CONFIG_XDS_AGENT`)
4. Applies the configuration using `istioctl install`
5. Waits for istiod to be ready

**What this does:**
- Enables multi-root trust in Istio's control and data planes
- Adds Defakto trust domain as an alias
- Configures Envoy proxies to trust both Istio and Defakto CAs
- Existing workloads need restart to pick up new configuration


### Step 7: Configure Multi-Root trust (in Defakto trust domain)

The Defakto platform also needs to be configured to trust the built-in
trust domain from the default installation of Istio. When Istio is switched
to use the Spirl Agent for workloads, we need to provide trust anchors
for workloads that are using the built-in root.

**Step 7a: Retrieve the built-in root**

Istio under a default installation creates a root certificate that signs
credentials under the cluster.local trust domain.

We need to retrieve a copy of that root.

```bash
kubectl -n istio-system get secret istio-ca-secret -o jsonpath='{.data.ca-cert\.pem}' | base64 -d > cluster.local.root.crt
```

**Step 7b: Convert the format**

The SPIFFE Federation is a specified interface available at [SPIFFE Federation Documentation](https://spiffe.io/docs/latest/spiffe-specs/spiffe_federation/).
We convert the format of the CRT file used by istio to a format supported by
istiol.

Please Note: This script is for example purposes only.

```bash
./pem-to-spiffe-bundle.sh cluster.local.root.crt --sequence 1 --refresh-hint 86400 -o cluster.local.bundle.json
```

**Step 7c: Upload the resulting file**

The file needs to be available on an HTTPs URL that the SPIRL servers can scrape
and discover the trust anchors to use for the cluster.local trust domain.

In this example, if you use Github you can upload the file as a gist.

Example of what it looks like: [Gist](https://gist.githubusercontent.com/knisbet/e77e1a011a233dce73dd9a9154a30cdb/raw/2e0ec55f83039f9fd9707620b481ed4e6afd6da3/bundle.json)

Note: Make sure to use the raw output file, the text of the response must be a json file representing the JWKS of the keys in use by a trust domain.

**Step 7d: Create the federation link**

```bash
FEDERATION_URL="https://gist.githubusercontent.com/knisbet/e77e1a011a233dce73dd9a9154a30cdb/raw/2e0ec55f83039f9fd9707620b481ed4e6afd6da3/bundle.json"
spirlctl federation link $TRUST_DOMAIN --foreign-trust-domain cluster.local --endpoint-url $FEDERATION_URL
```

This will create the federation link on the trust domain you are using for this
demo, to trust a foreign cluster from istio (cluster.local), and it will retrieve the trust bundle from the gist.githubusercontent... url that has been provided.

**Step 7e: Check the status of the federation**

```bash
spirlctl federation list
```

Will show the federation link and it's last poll status. Please note this can take
several minutes for polling to be succesful.


### Step 8: Verify Multi-Root Trust Configuration

After applying the configuration, verify that multi-root trust is
working.

**Step 8a: Restart workloads**

Restart the bookinfo deployments to pick up the new trust configuration:

```bash
kubectl rollout restart deployment -n bookinfo
kubectl rollout status deployment -n bookinfo productpage-v1
```

**Step 8b: Run verification script**

```bash
./verify-multiroot.sh
```

**Expected output:**

```
Step 1: Checking mesh configuration
✓ trustDomain: cluster.local
✓ trustDomainAliases: - defakto.example.com
✓ caCertificates configured

Step 2: Checking feature flags
✓ ISTIO_MULTIROOT_MESH: true
✓ PROXY_CONFIG_XDS_AGENT: true

Step 3: Checking Envoy's trusted CA bundle
✓ Found ROOTCA in Envoy with 2 certificate(s)
✓ SUCCESS: 2 CA certificates found
```

**What this proves:**
- ✓ Mesh configuration includes both trust domains
- ✓ Feature flags are enabled
- ✓ Envoy proxies have 2 CA certificates in their trust bundle

At this point, all bookinfo services still use Istio certificates, but
they're ready to trust Defakto certificates.

### Step 9: Enable Defakto Certificates for One Service

Now we'll enable Defakto certificates for the `details` service while
keeping all other bookinfo services using Istio certificates. This
demonstrates **cross-CA communication** - services with different CAs
can still communicate via mTLS.

**Enable Defakto certificates for the details service:**

```bash
./enable-spirl-for-service.sh details-v1 bookinfo
```

This script:
1. Adds the `k8s.spirl.com/spiffe-csi: enabled` label to the deployment
2. Restarts the deployment
3. Verifies the SPIFFE socket is mounted
4. Checks if the pod obtained a Defakto-issued certificate

**Expected output:**

```
✓ Label added: k8s.spirl.com/spiffe-csi=enabled
✓ Deployment restarted
✓ SPIFFE socket found at /run/secrets/workload-spiffe-uds/socket
✓ SUCCESS: Certificate is from SPIRL CA
  Trust Domain: defakto.example.com
```

**How it works:**

The label triggers the SPIRL controller webhook to inject a CSI volume:
- Volume mounted at `/run/secrets/workload-spiffe-uds`
- This is where `istio-proxy` looks for SPIFFE Workload API
- `istio-proxy` connects to SPIRL Agent and obtains Defakto certificates
- These certificates are used for mTLS with other services

**Check the certificate trust domain:**

```bash
POD=$(kubectl get pod -n bookinfo -l app=details -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n bookinfo $POD -c istio-proxy -- \
  pilot-agent request GET certs 2>/dev/null | \
  jq -r '.certificates[0].cert_chain[0].subject_alt_names[0].uri'
```

Expected output:
```
spiffe://example.org/ns/bookinfo/sa/bookinfo-details
```

Note: `example.org` (not `cluster.local`) - This pod now uses a
Defakto certificate!

### Step 10: Test Cross-CA Communication

Now test that the bookinfo application still works even though
`details` uses a Defakto certificate while `productpage` uses an Istio
certificate.

**Test: Productpage (Istio CA) → Details (Defakto CA)**

```bash
kubectl exec -n bookinfo deployment/productpage-v1 -c productpage -- \
  python -c "import requests; print(requests.get('http://details:9080/details/0').text)"
```

**Expected output** (JSON response):
```json
{"id":0,"author":"William Shakespeare","year":1595,"type":"paperback","pages":200,"publisher":"PublisherA","language":"English","ISBN-10":"1234567890","ISBN-13":"123-1234567890"}
```

✅ **Success!** The request succeeds even though the services use
certificates from different CAs.

**Access the Bookinfo UI:**

```bash
# Open in browser
open http://localhost:8080/productpage
```


Refresh the page multiple times - it should work perfectly, with
`productpage` calling `details`, `reviews`, and `ratings` to fill different sections of the page. The fact that `details` uses a Defakto certificate is transparent to the application.


### Step 11: Verify mTLS is Actually Used

Prove that the connection uses mTLS (via Envoy) by checking Istio's
statistics:

```bash
./verify-mtls-stats.sh
```

**Expected output:**
```
==============================================
Verify mTLS Using Istio Statistics
==============================================

Checking mTLS request count...

mTLS requests before: 5

Making test request from productpage to details...
{"id":0,"author":"William Shakespeare","year":1595,"type":"paperback","pages":200,"publisher":"PublisherA","language":"English","ISBN-10":"1234567890","ISBN-13":"123-1234567890"}

Checking mTLS request count again...
mTLS requests after: 6

✓ SUCCESS: Counter increased from 5 to 6 - mTLS is working!
```

The counter increment confirms cross-CA mTLS is working - productpage
with an Istio certificate successfully communicates with details using
a Defakto certificate.

**Verify certificates are from different CAs:**

```bash
# Check productpage certificate (Istio CA)
kubectl exec -n bookinfo deployment/productpage-v1 -c istio-proxy -- \
  pilot-agent request GET certs 2>&1 | \
  jq -r '.certificates[0].cert_chain[0].subject_alt_names[0].uri'

# Check details certificate (Defakto CA)
kubectl exec -n bookinfo deployment/details-v1 -c istio-proxy -- \
  pilot-agent request GET certs 2>&1 | \
  jq -r '.certificates[0].cert_chain[0].subject_alt_names[0].uri'
```

**Expected output shows different trust domains:**
```
spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage
spiffe://example.org/ns/bookinfo/sa/bookinfo-details
```

## What This Demonstrates

✅ **Multi-root trust is working:**
- Envoy proxies have 2 CA certificates in their trust bundle
- Services with Istio certificates can call services with Defakto
  certificates
- All communication uses mTLS (verified by Envoy statistics)
- The application works transparently - no code changes needed

✅ **Configuration via meshConfig:**
- `trustDomainAliases` tells Istio to recognize the Defakto trust
  domain
- `caCertificates` provides the Defakto CA certificate
- Feature flags enable multi-root support
- Declarative, GitOps-friendly configuration

## Key Files

### Istio Configurations (meshConfig Approach)

- **k8s/istio/istio-initial.yaml**: Standard Istio with built-in CA
- **k8s/istio/istio-multiroot-experimental.yaml**: Multi-root trust
  configuration
  - Includes `trustDomainAliases` for Defakto trust domain
  - Configures `caCertificates` with Defakto CA
  - Enables required feature flags
- **k8s/istio/istio-multiroot-permissive.yaml**: Alternative
  configuration with `PILOT_SKIP_VALIDATE_TRUST_DOMAIN`

### Scripts

- **k8s/istio/apply-multiroot-experimental.sh**: Apply multi-root
  configuration
  - Fetches Defakto trust bundle
  - Generates IstioOperator config
  - Applies via `istioctl install`
- **verify-multiroot.sh**: Comprehensive verification
  - Checks mesh configuration
  - Verifies feature flags
  - Counts CA certificates in Envoy
- **verify-mtls-stats.sh**: Verify mTLS using Envoy statistics
  - Checks mTLS request counters before/after test request
  - Confirms mTLS is actively used for connections
  - Compatible with both bash and zsh
- **enable-spirl-for-service.sh**: Enable Defakto certificates for a
  service
  - Adds CSI injection label
  - Restarts deployment
  - Verifies certificate provisioning
- **k8s/istio/install-istio.sh**: Install standard Istio

### Documentation

- **MULTIROOT-EXPERIMENTAL.md**: Detailed technical guide
- **QUICKSTART-MULTIROOT.md**: Quick start guide
- **FINDINGS.md**: Research findings and key insights



## Troubleshooting

### Kiali mTLS Status Error

**Symptom**: Kiali shows error "Error fetching Mesh-wide mTLS status"

This is a known compatibility issue between certain versions of Kiali
and Istio. It doesn't affect the demo functionality - you can still:
- View the service graph
- See traffic animation
- Check per-service mTLS status (the error only affects mesh-wide status)

To work around it, you can still verify mTLS is working by:
1. Looking at the service graph with Display → Security enabled
   (padlock icons show mTLS)
2. Checking Envoy configuration directly (see verification commands in
   the README)

### Trust Bundle Not Applied

**Symptom**: Configuration applied but Envoy still doesn't trust SPIRL
certificates

**Check:**

1. Verify the ConfigMap was created:
```bash
kubectl get configmap istio -n istio-system -o yaml | grep -A 20 caCertificates
```

2. Check istiod logs for errors:
```bash
kubectl logs -n istio-system deployment/istiod -f | grep -i "certificate\|CA"
```

3. Verify xDS push occurred:
```bash
istioctl proxy-status
```

All proxies should show recent update times.

### mTLS Handshake Failures

**Symptom**: Connections fail with TLS errors

**Check:**

1. Envoy logs for TLS handshake errors:
```bash
kubectl logs -n bookinfo deployment/productpage-v1 -c istio-proxy | grep -i "tls\|handshake"
```

2. Verify certificates and SPIFFE IDs:
```bash
kubectl exec -n bookinfo deployment/productpage-v1 -c istio-proxy -- \
  pilot-agent request GET certs
```

3. Check Envoy cluster configuration:
```bash
kubectl exec -n bookinfo deployment/productpage-v1 -c istio-proxy -- \
  pilot-agent request GET clusters | grep -E "(details|ratings|reviews)"
```

### SPIRL Workload Not Getting Certificates

**Symptom**: SPIRL workload pod fails to start or doesn't have certificates

**Check:**

1. Verify SPIRL agent is running:
```bash
kubectl get pods -n spirl-system
```

2. Check if cluster is registered with SPIRL:
```bash
spirlctl cluster list --trust-domain example.org
```

3. Verify CSI driver is installed:
```bash
kubectl get csidriver
```

Should include `csi.spiffe.io`.

4. Check workload has correct labels/annotations:
```bash
kubectl get pod -n spirl-demo -o yaml | grep -A 5 "labels\|annotations"
```

### Configuration Not Updating

**Symptom**: Changes don't take effect

**Force update:**

1. Restart istiod:
```bash
kubectl rollout restart deployment/istiod -n istio-system
```

2. Restart workload pods:
```bash
kubectl rollout restart deployment -n bookinfo productpage-v1
```

## Cleanup

**Using ctlptl:**

```bash
# Stop Tilt and delete cluster
tilt down
ctlptl delete -f cluster.yaml

# Remove cluster from SPIRL (if added)
spirlctl cluster delete istio-trust-federation \
  --trust-domain example.org \
  --force
```

**Using kind directly:**

```bash
# Stop Tilt
tilt down

# Delete the cluster
kind delete cluster --name istio-trust-federation

# Remove cluster from SPIRL (if added)
spirlctl cluster delete istio-trust-federation \
  --trust-domain example.org \
  --force
```

**Using the Makefile:**

```bash
make env-down
```


## Appendix A: Alternative approach with `meshConfig.caCertificates`

Istio provides an alternative method for configuring multi-root trust
using `meshConfig.caCertificates`. This approach is more declarative
than certificate concatenation and is designed for federation
scenarios.

### ✅ This Approach Works! (Verified February 2026)

We successfully configured multi-root trust using
`meshConfig.caCertificates` with Istio 1.28.3. The key was combining
**three critical elements** that work together:

1. **trustDomainAliases** - Tells Istio to recognize the federated trust domain
2. **caCertificates** - Provides the CA certificate bundle
3. **certSigners** - Restricts the CA to specific SPIFFE trust domains

### Complete Working Configuration

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
        # REQUIRED: Enable multi-root mesh support
        ISTIO_MULTIROOT_MESH: "true"

  meshConfig:
    # Primary trust domain (Istio's built-in CA)
    trustDomain: cluster.local

    # CRITICAL: Add federated trust domain as alias
    # Without this, Istio won't fetch/trust the CA certificates
    trustDomainAliases:
      - defakto.example.com

    defaultConfig:
      proxyMetadata:
        # REQUIRED: Enable XDS agent to process additional CAs
        PROXY_CONFIG_XDS_AGENT: "true"

    # Add Defakto CA to trust bundle
    caCertificates:
      - pem: |
          -----BEGIN CERTIFICATE-----
          [Defakto CA certificate]
          -----END CERTIFICATE-----
        # Restrict CA to specific SPIFFE trust domain
        certSigners:
          - "spiffe://defakto.example.com"
```

### Why It Works Now

Previous attempts failed because we were missing the
**`trustDomainAliases`** configuration. Research revealed that
`trustDomainAliases` is not just for authorization policies - it's
also **required** for Istio to fetch and trust CA certificates from
federated domains. (Source: [Istio Issue
#57399](https://github.com/istio/istio/issues/57399))

The complete configuration must include:
- ✅ `ISTIO_MULTIROOT_MESH: "true"` in pilot
- ✅ `PROXY_CONFIG_XDS_AGENT: "true"` in proxy metadata
- ✅ `trustDomainAliases` with the federated domain
- ✅ `caCertificates` with the CA bundle
- ✅ `certSigners` with the SPIFFE trust domain

### How to Use This Approach

**Quick start:**

```bash
# Set environment variables
export TRUST_DOMAIN="defakto.example.com"
export SPIRL_BUNDLE_ENDPOINT="https://fed.spirl.org/t-{id}/td-{id}/bundle"

# Apply configuration
./k8s/istio/apply-multiroot-experimental.sh

# Restart workloads
kubectl rollout restart deployment -n bookinfo

# Verify - should show 2 CA certificates
./verify-multiroot.sh
```

**Verification:**

```bash
# Check mesh configuration
kubectl get configmap istio -n istio-system -o yaml | grep -A 10 trustDomainAliases

# Verify Envoy has both CAs
POD=$(kubectl get pod -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config secret ${POD}.bookinfo -o json | \
  jq '.dynamicActiveSecrets[] | select(.name == "ROOTCA")' | \
  grep -c "BEGIN CERTIFICATE"
# Should output: 2
```

### Comparison: meshConfig vs Certificate Concatenation

Both approaches work. Choose based on your needs:

| Aspect | meshConfig Approach | Certificate Concatenation |
|--------|---------------------|---------------------------|
| **Configuration** | Declarative (IstioOperator) | Script-based |
| **Istio Version** | 1.28.3+ (tested) | All versions |
| **Feature Flags** | Required (2 flags) | Not needed |
| **Setup Complexity** | Medium | Simple |
| **Maintenance** | Easy (update YAML) | Manual (run script) |
| **Maturity** | Newly verified (2026) | Proven (KubeCon 2024) |
| **Documentation** | Limited | Well documented |

**Recommendation:**
- **meshConfig approach** (used in this demo) for declarative, GitOps-friendly configuration
- **Certificate concatenation** (see Appendix B) for simpler setup without feature flags

### Files for meshConfig Approach

- `k8s/istio/istio-multiroot-experimental.yaml` - Configuration template
- `k8s/istio/apply-multiroot-experimental.sh` - Setup script
- `verify-multiroot.sh` - Verification script
- `MULTIROOT-EXPERIMENTAL.md` - Detailed documentation
- `QUICKSTART-MULTIROOT.md` - Quick start guide

### References

- [Istio MeshConfig API](https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/)
- [Trust Domain Migration](https://istio.io/latest/docs/tasks/security/authorization/authz-td-migration/)
- [Wildcard trustDomain for SPIRE federation](https://github.com/istio/istio/issues/57399) - Documents need for trustDomainAliases
- [Workload certificate trust issues](https://github.com/istio/istio/issues/39935) - Feature flag requirements
- [Istio root cert rotation demo](https://github.com/zirain/istio-root-cert-rotation) - Certificate concatenation approach

## Appendix B: Certificate Concatenation Approach

An alternative to the meshConfig approach is to concatenate CA
certificates directly into the `cacerts` secret. This method is
simpler but less declarative.

### How It Works

1. Istio reads CA certificates from the `cacerts` secret
2. The `root-cert.pem` field can contain multiple PEM certificates
3. Envoy trusts all certificates in the bundle

### Implementation

```bash
# 1. Get Istio's current root certificate
kubectl get secret istio-ca-secret -n istio-system \
  -o jsonpath='{.data.ca-cert\.pem}' | base64 -d > istio-root.pem

# 2. Fetch Defakto's root certificate
curl -fsSL "${SPIRL_BUNDLE_ENDPOINT}" > defakto-root.pem

# 3. Concatenate them
cat istio-root.pem defakto-root.pem > combined-root.pem

# 4. Get current CA cert and key
kubectl get secret istio-ca-secret -n istio-system \
  -o jsonpath='{.data.ca-cert\.pem}' | base64 -d > ca-cert.pem
kubectl get secret istio-ca-secret -n istio-system \
  -o jsonpath='{.data.ca-key\.pem}' | base64 -d > ca-key.pem
kubectl get secret istio-ca-secret -n istio-system \
  -o jsonpath='{.data.cert-chain\.pem}' | base64 -d > cert-chain.pem

# 5. Create cacerts secret
kubectl create secret generic cacerts -n istio-system \
  --from-file=ca-cert.pem=ca-cert.pem \
  --from-file=ca-key.pem=ca-key.pem \
  --from-file=root-cert.pem=combined-root.pem \
  --from-file=cert-chain.pem=cert-chain.pem

# 6. Restart istiod
kubectl rollout restart deployment/istiod -n istio-system
```

### Script

A helper script is provided:

```bash
export TRUST_DOMAIN="defakto.example.com"
export SPIRL_BUNDLE_ENDPOINT="https://fed.spirl.org/..."
./k8s/istio/add-trust-bundle.sh
```

### Advantages

- ✓ Simple and direct
- ✓ No feature flags needed
- ✓ Works in all Istio versions
- ✓ Well documented (used for CA rotation)
- ✓ Based on [Istio root cert rotation
  demo](https://github.com/zirain/istio-root-cert-rotation)

### Disadvantages

- ✗ Script-based (not declarative)
- ✗ Requires manual secret updates
- ✗ Less GitOps-friendly
- ✗ No `trustDomainAliases` (for authorization policies)

### When to Use

Use certificate concatenation when:
- You want the simplest possible setup
- You don't need declarative configuration
- You're not using GitOps
- You want maximum compatibility across Istio versions
