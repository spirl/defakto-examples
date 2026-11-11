# java-spiffe trust bundle rotation

Two copies of a small Java service mTLS-ping each other using the open source
[java-spiffe](https://github.com/spiffe/java-spiffe) SDK (`java-spiffe-core` +
`java-spiffe-provider`, X.509 SVIDs). The goal is to demonstrate that applications
respond quickly to emergency key rotations.

Each pod is both a server and a client:

- `GET /ping` returns `pong from <my id> to <peer id>`. The server requires a client certificate.
- `GET /debug` returns the SVID and trust bundle the SDK currently holds.
- Every `INTERVAL_SECONDS` (default 5) the pod pings `PEER_URL` and logs one line with the
  result and the SDK's current state.

The `X509Source` and `SSLContext` are built once at startup and never rebuilt, the same way a
long-running service uses them. Each ping opens a new connection and a full TLS handshake
(no keep-alive, TLS sessions expire after 1s), so every ping checks the peer against the bundle
the SDK holds at that moment.

## Deploy

This example assumes the cluster already runs the Defakto agent and controller. The pods carry the
`k8s.spirl.com/spiffe-csi: enabled` label, so the controller adds the Workload API socket
volume and `SPIFFE_ENDPOINT_SOCKET` for you.

```bash
docker build -t java-spiffe-pingpong:dev .
kind load docker-image java-spiffe-pingpong:dev   # or push to a registry and edit k8s.yaml
kubectl apply -f k8s.yaml
kubectl -n java-pingpong logs -f deploy/ping-a
```

On a healthy cluster the logs look like this:

```
... PING OK 200 pong from spiffe://td/ns/java-pingpong/sa/ping-b to spiffe://td/ns/java-pingpong/sa/ping-a | svid[serial=.. exp=.. issuer=3f9a..] bundle[3f9a.. exp=.., 81cc.. exp=..]
```

## Demonstration

1. Tail the logs of both deployments.
2. Rotate the signing key (see ./rotate.sh).
3. Watch for:
   - `INFO io.spiffe.workloadapi.DefaultX509Source: Received X509Context update` – the SDK got a push
     from the agent.
   - `SVID UPDATED old -> new` / `BUNDLE UPDATED old -> new` – what the `X509Source` holds actually
     changed (checked every second). A push with no matching `BUNDLE UPDATED` means the agent sent
     the same bundle again.
   - `PING FAIL ...` – note whether `bundle[...]` still lists the old authorities only, and
     whether `issuer=` (the CA that signed our SVID) appears in our own `bundle[...]`.
4. Restart one pod (`kubectl -n java-pingpong rollout restart deploy/ping-a`) and compare its
   `bundle[...]` with the one the long-running pod reports.

`kubectl -n java-pingpong exec deploy/ping-a -- curl` won't work (no curl in the image, and the
server needs a client cert). Use the logs, which show the same information as `/debug`.
