# Self-hosted deployment with spirldbg

This directory contains a basic Terraform configuration that deploys:

- a Defakto server
- a Defakto agent
- a `spirldbg` deployment as an example workload

The `spirldbg` workload is included to demonstrate how a workload can receive SVIDs from the Defakto agent.

## Purpose

Use this example as a simple starting point for:

- standing up a minimal Defakto environment with Terraform
- running a sample workload alongside the Defakto components
- verifying SVID delivery to the workload
- agent attestation using the Kubernetes Service Account Token

## How to run

Initialize Terraform:

```sh
terraform init
```

Apply the configuration by setting the required variables:

```sh
terraform apply \
	-var="agent_cluster_context=<agent-cluster-context>" \
	-var="server_cluster_context=<server-cluster-context>" \
	-var="cluster_name=<defakto-cluster-name>" \
	-var="trust_domain_name=<defakto-trust-domain-name>" \
	-var="agent_attestation_issuer_url=<agent-attestation-issuer-url>"
```

Required variables:

- `agent_cluster_context`: kubeconfig context for the cluster where the Defakto agent will be deployed
- `server_cluster_context`: kubeconfig context for the cluster where the Defakto server will be deployed
- `agent_attestation_issuer_url`: the issuer URL for the Kubernetes service account token
- `agent_endpoint`: the domain name and port for the spirl-server. This should be a domain name that you own and configure with an Kubernetes Ingress to route traffic to the spirl-server service

Optional variables:

- `cluster_name`: name of the Defakto cluster
- `trust_domain_name`: trust domain name used by Defakto
- `cluster_path_template`: the path template for the SPIFFE IDs created for this cluster


