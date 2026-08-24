# Envoy mTLS Demo

Deploys a server and client workload in an existing Kubernetes cluster, connected over mTLS using SVIDs obtained via Envoy SDS from the Defakto agent.

## Prerequisites

- A Defakto trust domain with a Trust Domain Server deployment. See the [quick start guide](https://d.defakto.security/mint/quick-start/create-trust-domain) if you don't have one yet.
- A Kubernetes cluster registered to that trust domain with the Defakto agent running (via the `spirl-system` Helm chart). See [adding a cluster](https://d.defakto.security/mint/quick-start/add-k8s-to-trust-domain).

## What this deploys

- **demo-server**: nginx on :8080 behind an Envoy sidecar that terminates mTLS on :8443
- **demo-client**: curl loop behind an Envoy sidecar that proxies requests to the server over mTLS
- A Kubernetes Service exposing the server's mTLS port within the cluster

Both pods carry the `k8s.spirl.com/spiffe-csi: enabled` label, which triggers the Defakto Admission Controller to inject the agent socket. Envoy uses that socket to fetch its SVID and trust bundle via SDS.

## How to run

```sh
terraform init

terraform apply \
  -var="trust_domain_name=<your-trust-domain>" \
  -var="cluster_name=<your-defakto-cluster-name>" \
  -var="kubeconfig_context=<your-kubeconfig-context>"
```

## Verifying

Check the client logs — you should see a response from the server for each request:

```sh
kubectl logs -n envoy-demo -l app=demo-client -c curl -f
```

Expected output:

```
--- Wed Aug 19 10:43:14 UTC 2026
Hello from demo-server
Client SPIFFE ID: spiffe://<trust-domain>/<cluster-name>/ns/envoy-demo
```

The `Client SPIFFE ID` line is extracted by the server-side Envoy from the client's mTLS certificate (`%DOWNSTREAM_PEER_URI_SAN%`) and forwarded to nginx as a request header. Seeing it confirms that the client presented a valid SVID and the mTLS handshake succeeded.

To inspect the SDS stats and verify Envoy received its SVID:

```sh
kubectl port-forward -n envoy-demo deploy/demo-server 9901:9901
curl -s localhost:9901/stats | grep -E 'sds\.(default|ROOTCA)\.update_success'
```

Both counters should be non-zero.
