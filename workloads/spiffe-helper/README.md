# SPIFFE Helper Demo

Using [SPIFFE Helper](https://github.com/spiffe/spiffe-helper), workloads can get an SVID with no code changes. SPIFFE Helper is deployed as a sidecar to a workload and requests an SVID on behalf of the workload. In this demo the SVID is written to a shared volume so that the workload can read it. 

For other SPIFFE Helper examples such as using it with MySQL or Postgres see the [open source examples](https://github.com/spiffe/spiffe-helper/tree/main/examples).

## Usage

In a Kubernetes cluster with a spirl-agent deployed, apply the deployment configuration:

```
kubectl apply -f ./deployment.yaml
```

Then look at the pod logs to see the JWT-SVID.
