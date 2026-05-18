# SaaS Deployment with spirldbg

This directory contains a basic Terraform configuration that deploys:

- a Defakto agent
- a `spirldbg` deployment as an example workload

using the Defakto SaaS Trust Domain Server.

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
	-var="agent_attestation_issuer_url=<agent-attestation-issuer-url>"
```

Required variables:

- `agent_cluster_context`: kubeconfig context for the cluster where the Defakto agent will be deployed
- `agent_attestation_issuer_url`: the issuer URL for the Kubernetes service account token

Optional variables:

- `cluster_name`: name of the Defakto cluster
- `trust_domain_name`: trust domain name used by Defakto
- `cluster_path_template`: the path template for the SPIFFE IDs created for this cluster


