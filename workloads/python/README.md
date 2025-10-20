# Get an SVID Using the SPIFFE Python Library

This directory has two example Python scripts that use [Python SPIFFE Library](https://pypi.org/project/spiffe/) to get x509 and JWT SVIDs. 

These scripts can be run as workloads in an environment where a spirl-agent is deployed. 

## Usage

### Kubernetes

If you have the [spirl-system helm chart](https://github.com/orgs/spirl/packages/container/package/charts%2Fspirl-system) deployed in a K8s, then deploy a pod that runs the Python script and has the label `k8s.spirl.com/spiffe-csi=enabled`. With this label the `spirl-controller` will inject the socket with the Workload API as a volume mount on the pod and set the environment variable `SPIFFE_ENDPOINT_SOCKET` to point to this socket. The pod should successfully run the Python script.

### Other Environments

Set the `SPIFFE_ENDPOINT_SOCKET` environment variable to the address of the Workload API exposed by the spirl-agent (e.g. unix:///run/spirl/sockets/agent.sock). Then run the Python script. 




 