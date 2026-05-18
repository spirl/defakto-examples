terraform {
  required_providers {
    spirl = {
      source = "registry.opentofu.org/spirl/spirl"
    }
  }
}

# Required: The name of the kubeconfig context for the Kubernetes cluster
# where workloads and the spirl-agent will be deployed.
variable "agent_cluster_context" {
  type        = string
  description = "Kubeconfig context for the agent cluster"
}

# Required: the issuer URL for the Kubernetes service account token 
# such as https://oidc.eks.us-west-2.amazonaws.com/id/<AWS_ACCOUNT_ID> for an EKS cluster
variable "agent_attestation_issuer_url" {
  type        = string
  description = "Issuer URL for the agent attestation policy"
}

# Optional: the path template for the SPIFFE IDs created for this cluster
# such as "/{{cluster.name}}/ns/{{kubernetes.pod.namespace}}"
variable "cluster_path_template" {
  type        = string
  description = "Path template for the Defakto cluster"
}

# Optional: The name of the Defakto cluster.
# Defaults to "defakto-cluster"
variable "cluster_name" {
  type        = string
  description = "Name of the Defakto cluster"
}

# Optional: The name of the Defakto trust domain.
# Defaults to "example.com"
variable "trust_domain_name" {
  type        = string
  description = "Name of the Defakto trust domain"
}

# Configure the Spirl provider
provider "spirl" {
}

# Provider for agent cluster
provider "helm" {
  alias = "agent_helm"

  kubernetes = {
    config_path    = "~/.kube/config"
    config_context = var.agent_cluster_context
  }
}

provider "kubernetes" {
  alias = "agent_k8s"

  config_path    = "~/.kube/config"
  config_context = var.agent_cluster_context
}

resource "spirl_trust_domain" "test_domain" {
  domain_name = var.trust_domain_name
  self_hosted = false
}

resource "spirl_cluster" "demo_cluster" {
  trust_domain_id = spirl_trust_domain.test_domain.id
  name            = var.cluster_name
  platform        = "k8s"
  path_template   = var.cluster_path_template
}

resource "spirl_cluster_config" "cluster_configs" {
  cluster_id = spirl_cluster.demo_cluster.id

  sections = {
    AgentAttestation = <<-YAML
      section: AgentAttestation
      schema: v1
      spec:
        policies:
          - name: kind_cluster_policy
            requiredAttestors:
              - type: k8s_token
                config:
                  issuerURL: ${var.agent_attestation_issuer_url}
    YAML
  }
}

resource "helm_release" "spirl-system" {
  provider         = helm.agent_helm
  name             = "spirl-system"
  repository       = "oci://ghcr.io/spirl/charts"
  chart            = "spirl-system"
  namespace        = "spirl-system"
  create_namespace = true

  values = [<<-EOT
platform: K8S

agent:
    priorityClassName: "system-node-critical"
    endpoint:
        endpoint: ${spirl_trust_domain.test_domain.spirl_agent_endpoint}
    auth:
        clusterId: ${spirl_cluster.demo_cluster.id}
        attestors:
        - type: k8s_token
EOT
  ]

  # Wait for resources to be ready
  wait          = true
  wait_for_jobs = true
  timeout       = 600
}

resource "kubernetes_deployment_v1" "spirldbg_svid_server" {
  provider = kubernetes.agent_k8s

  depends_on = [helm_release.spirl-system]

  metadata {
    name      = "spirldbg-svid-server"
    namespace = "spirl-system"
    labels = {
      app = "spirldbg-svid-server"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "spirldbg-svid-server"
      }
    }

    template {
      metadata {
        labels = {
          app                        = "spirldbg-svid-server"
          "k8s.spirl.com/spiffe-csi" = "enabled"
        }
      }
      spec {
        container {
          name  = "spirldbg"
          image = "ghcr.io/spirl/spirldbg:v0.0.18"
          args  = ["server", "--debug", "--addr", "localhost:8080"]
        }
      }
    }
  }
}
