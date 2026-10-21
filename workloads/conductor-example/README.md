# Conductor worker to Google Cloud with a Defakto JWT-SVID

A Conductor workflow whose worker reaches Google Cloud with no stored service account key. The
workflow `gcp_federation` has one task, `gcp_web_identity`. The worker that runs it asks the
Defakto agent for a JWT-SVID with audience `gcp-demo` and exchanges it at Google's Security Token
Service through Workload Identity Federation. It then uses the federated token to impersonate a
Google service account, which gives it an ordinary OAuth access token. The identity behind the
JWT-SVID is the worker pod's Kubernetes service account, attested by the Defakto agent. Nothing
in Conductor, the worker's image, or a Kubernetes Secret is a credential, and nothing is written
to disk.

The same pattern covers any workflow step that calls Google Cloud: Cloud Storage, Pub/Sub,
BigQuery, Secret Manager, or anything else a service account can be granted. This example stops
once the access token is issued, so the service account in it holds no roles.

## What you need

| Component | Version this example was built with |
|---|---|
| A Kubernetes cluster in your Defakto trust domain, with the agent from the `spirl-system` Helm chart, including its SPIFFE CSI driver | chart 0.47.0, agent 0.47.0 |
| `defakto` CLI, signed in (`defakto login`) | 0.36.0 |
| A Google Cloud project where you can create a Workload Identity Pool, a service account, and IAM bindings, and the `gcloud` CLI signed in to it | |
| `kubectl` with built-in kustomize, and `jq` for `run-workflow.sh` | |
| Images, both public on Docker Hub | `conductoross/conductor:3.32.5`, `python:3.14-alpine` |
| Python packages, from PyPI at pod start | `conductor-python==2.0.0`, `spiffe==0.3.2` |

The worker calls Google's REST endpoints with the Python standard library, so it needs no
Google client library. The worker pod needs outbound HTTPS to PyPI (at start),
`sts.googleapis.com`, and `iamcredentials.googleapis.com`.

## What is in this directory

```
README.md                         this file
run-workflow.sh                   starts one workflow run and prints its result
k8s/kustomization.yaml            kubectl apply -k k8s/
k8s/conductor.yaml                namespace, Conductor server and UI (demo: SQLite, one replica)
k8s/worker.yaml                   the worker's ServiceAccount and Deployment
k8s/worker/worker.py              the worker: JWT-SVID in, Google access token out
k8s/worker/requirements.txt       its pinned packages
policies/k8s/                     reference Managed Config sections for the cluster (step 1)
```

## Step 1: find the issuer and the worker's SPIFFE ID

The Google Cloud setup needs two values from Defakto.

The issuer is your trust domain's JWT issuer URL:

```
defakto trust-domain info <your-trust-domain>
```

Copy the `JWT Issuer:` line, for example `https://fed.spirl.org/t-o9cpowm5yo/td-wyw33falzt`.
Leave off `/.well-known/openid-configuration`. Defakto publishes the OIDC discovery document and
JWKS at that URL, so Google can verify tokens without any further setup on your side.

The SPIFFE ID is the token's `sub`. The cluster's `SVIDIssuancePolicy` section decides it. With
the path template in `policies/k8s/SVIDIssuancePolicy.yaml`:

```yaml
pathTemplate: "/{{cluster.name}}/ns/{{kubernetes.pod.namespace}}/sa/{{kubernetes.pod.service_account}}"
```

the worker in namespace `conductor` with service account `conductor-worker`, on a cluster named
`prod-east`, gets:

```
spiffe://<your-trust-domain>/prod-east/ns/conductor/sa/conductor-worker
```

Your cluster may use another template. Check it before writing the IAM binding:

```
defakto config get cluster --id <cluster-id>
```

Do not `set` the files in `policies/k8s/` on a cluster that already issues SVIDs to other
workloads. A new path template changes every workload's SPIFFE ID on that cluster, and anything
that authorizes by ID stops matching. The files are here to show where the ID comes from.
`AgentAttestation.yaml` holds a `${jwks_k8s}` placeholder for the same reason: `defakto cluster
add` already wrote that section for your cluster.

## Step 2: create the Workload Identity Pool and service account

This follows the public tutorial,
[GCP federation](https://d.defakto.security/mint/integration/gcp/tutorial-gcp-federation), with
the service account bound to the worker's SPIFFE ID from the start rather than to the whole pool.

Set the values once:

```
export GCP_PROJECT_ID="your-project-id"
export GCP_PROJECT_NUMBER=$(gcloud projects describe ${GCP_PROJECT_ID} --format="value(projectNumber)")
export POOL_ID="defakto-identity-pool"
export PROVIDER_ID="defakto-oidc-provider"
export SERVICE_ACCOUNT="defakto-conductor-example"
export JWT_ISSUER="<JWT Issuer from step 1>"
export SPIFFE_ID="spiffe://<your-trust-domain>/<cluster>/ns/conductor/sa/conductor-worker"
```

Enable the IAM Service Account Credentials API, which serves the impersonation call:

```
gcloud services enable iamcredentials.googleapis.com --project=${GCP_PROJECT_ID}
```

Create the pool and an OIDC provider that trusts your trust domain's issuer, accepts the
`gcp-demo` audience, and maps the token's `sub` to Google's subject:

```
gcloud iam workload-identity-pools create ${POOL_ID} \
    --project=${GCP_PROJECT_ID} --location="global" \
    --display-name="Defakto Identity Pool"

gcloud iam workload-identity-pools providers create-oidc ${PROVIDER_ID} \
    --project=${GCP_PROJECT_ID} --location="global" \
    --workload-identity-pool=${POOL_ID} \
    --issuer-uri=${JWT_ISSUER} \
    --allowed-audiences="gcp-demo" \
    --attribute-mapping="google.subject=assertion.sub"
```

If a pool and provider for your trust domain already exist, reuse them and add `gcp-demo` to the
provider's allowed audiences.

Create the service account and let the worker's SPIFFE ID, and only that ID, impersonate it:

```
gcloud iam service-accounts create ${SERVICE_ACCOUNT} \
    --project=${GCP_PROJECT_ID} \
    --display-name="Defakto Conductor example"

gcloud iam service-accounts add-iam-policy-binding \
    ${SERVICE_ACCOUNT}@${GCP_PROJECT_ID}.iam.gserviceaccount.com \
    --project=${GCP_PROJECT_ID} \
    --role="roles/iam.workloadIdentityUser" \
    --member="principal://iam.googleapis.com/projects/${GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/subject/${SPIFFE_ID}"
```

The provider checks the issuer, the signature, and the audience. The binding is what limits the
service account to this one worker. A binding on the pool's `principalSet` instead, as the
tutorial's first pass uses, would let any workload in the trust domain that asks for a
`gcp-demo` token act as the service account.

## Step 3: deploy Conductor and the worker

In `k8s/worker.yaml`, set the two environment variables on the `worker` container from the
values in step 2:

```yaml
- {name: GCP_PROVIDER, value: "projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/defakto-identity-pool/providers/defakto-oidc-provider"}
- {name: GCP_SERVICE_ACCOUNT, value: "defakto-conductor-example@<PROJECT_ID>.iam.gserviceaccount.com"}
```

`GCP_PROVIDER` takes a project number, not a project ID. This prints the exact value:

```
gcloud iam workload-identity-pools providers describe ${PROVIDER_ID} \
    --project=${GCP_PROJECT_ID} --location="global" \
    --workload-identity-pool=${POOL_ID} --format="value(name)"
```

Then apply and wait for both deployments:

```
kubectl apply -k k8s/
kubectl -n conductor rollout status deploy/conductor --timeout=300s
kubectl -n conductor rollout status deploy/conductor-worker --timeout=180s
```

The Conductor image is about 430 MB and its JVM takes a minute to start on a first pull. The
worker installs its packages from PyPI in an init container, then registers the
`gcp_federation` workflow itself, so there is nothing to register by hand. Kustomize generates
the worker's ConfigMap with a hash in its name, so an edit to `worker.py` or `requirements.txt`
followed by `kubectl apply -k k8s/` rolls the worker.

Check that the worker started:

```
kubectl -n conductor logs deploy/conductor-worker -c worker
```

It prints `registered gcp_federation; polling gcp_web_identity`.

## Step 4: run the workflow

```
./run-workflow.sh
```

Pass kubectl flags after it to pick a cluster: `./run-workflow.sh --context <context>`. A
successful run prints the worker's SPIFFE ID, the service account it acted as, and when the
access token expires:

```json
{
  "status": "COMPLETED",
  "output": {
    "sub": "spiffe://<your-trust-domain>/<cluster>/ns/conductor/sa/conductor-worker",
    "service_account": "defakto-conductor-example@<PROJECT_ID>.iam.gserviceaccount.com",
    "expires": "<15 minutes after the run>"
  }
}
```

To start runs from the UI instead and see each run's output, forward the UI port and open
<http://localhost:5000>, then **Executions**:

```
kubectl -n conductor port-forward svc/conductor 5000
```

Conductor's API and UI have no authentication in this demo setup. The workflow output carries
only the SPIFFE ID, the service account, and an expiry, never a token.

## Try this: give the worker another identity

In `k8s/worker.yaml`, rename the ServiceAccount and the Deployment's `serviceAccountName` to
`conductor-worker-2`, then `kubectl apply -k k8s/`. The new pod gets
`.../ns/conductor/sa/conductor-worker-2`. The token exchange still succeeds, because the token
is valid and still for `gcp-demo`. The next `./run-workflow.sh` then fails at
`generateAccessToken` with a 403, because the service account's binding names the other SPIFFE
ID. Put the name back and apply again to recover.

## When a run fails

The worker puts Google's error body in the run's failure reason, so `run-workflow.sh` prints it.

| What you see | Where to look |
|---|---|
| The worker log shows a Workload API connection error | The pod lacks the agent socket. Check that the pod carries the label `k8s.spirl.com/spiffe-csi: enabled` and that the `spirl-system` chart's CSI driver runs on the node. |
| `sts.googleapis.com` answers `invalid_target` | `GCP_PROVIDER` names no provider, or a disabled one. Compare it with the `describe` output in step 3. |
| `sts.googleapis.com` answers `invalid_grant` | Google rejected the JWT-SVID. The provider's issuer URI must equal the token's issuer exactly, and its allowed audiences must include `gcp-demo`. |
| `iamcredentials.googleapis.com` answers 403 | The SPIFFE ID in the binding does not match the token's `sub`, or the IAM Service Account Credentials API is disabled. Compare the binding with the SPIFFE ID from step 1. |
| `not done in 30s` from `run-workflow.sh` | The worker is not polling. Read its log with the command in step 3. |

## From this example to production

- Build the worker into your own image instead of installing packages at pod start, and run it
  next to your existing Conductor deployment instead of the demo server in `k8s/conductor.yaml`.
- Use an audience per purpose instead of `gcp-demo`, and set it in two places: the provider's
  allowed audiences and `AUDIENCE` in `worker.py`.
- Grant the service account the roles your task needs, and use `impersonated['accessToken']` as
  the bearer token for your Google API calls, or wrap it in `google.oauth2.credentials.Credentials`
  for the Google client libraries. The worker fetches a new JWT-SVID and access token on every
  run, with a 15-minute lifetime, so nothing long-lived exists to rotate or leak.

## References

- [GCP federation tutorial](https://d.defakto.security/mint/integration/gcp/tutorial-gcp-federation)
- [Workload Identity Federation with other identity providers](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-providers)
- [Conductor documentation](https://docs.conductor-oss.org/index.html)
- [Conductor Python SDK](https://github.com/conductor-oss/python-sdk)
- [py-spiffe](https://github.com/HewlettPackard/py-spiffe), the SPIFFE library the worker uses
