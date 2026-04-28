terraform {
  required_providers {
    spirl = {
      source = "registry.opentofu.org/spirl/spirl"
    }
  }
}

# Required: The name of the kubeconfig context for the Kubernetes cluster
# where the spirl-server will be deployed.
variable "server_cluster_context" {
  type   = string
  default = ""
  description = "Kubeconfig context for the server cluster"
}

# Required: The name of the kubeconfig context for the Kubernetes cluster
# where workloads and the spirl-agent will be deployed.
variable "agent_cluster_context" {
  type   = string
  default = ""
  description = "Kubeconfig context for the agent cluster"
}

# Optional: The name of the Defakto cluster.
# Defaults to "defakto-cluster"
variable "cluster_name" {
  type   = string
  default = "defakto-cluster"
  description = "Name of the Defakto cluster"
}

# Optional: The name of the Defakto trust domain.
# Defaults to "example.com"
variable "trust_domain_name" {
  type   = string
  default = "example.com"
  description = "Name of the Defakto trust domain"
}

# Required: the issuer URL for the Kubernetes service account token 
# such as https://oidc.eks.us-west-2.amazonaws.com/id/<AWS_ACCOUNT_ID> for an EKS cluster
variable "agent_attestation_issuer_url" {
  type   = string
  default = ""
  description = "Issuer URL for the agent attestation policy"
}

# Optional: the path template for the SPIFFE IDs created for this cluster
# such as "/{{cluster.name}}/ns/{{kubernetes.pod.namespace}}"
variable "cluster_path_template" {
  type   = string
  default = ""
  description = "Path template for the Defakto cluster"
}

# Required: The domain name and port for the spirl-server. This should be a
# domain name that you own and configure with an Kubernetes Ingress to route
# traffic to the spirl-server service. 
variable "agent_endpoint" {
  type   = string
  default = ""
  description = "Endpoint for the agent to connect to the server"
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

# Provider for trust-domain cluster
provider "helm" {
  alias = "server_helm"

  kubernetes = {
    config_path    = "~/.kube/config"
    config_context = var.server_cluster_context
  }
}

provider "kubernetes" {
  alias = "agent_k8s"

  config_path    = "~/.kube/config"
  config_context = var.agent_cluster_context
}


# FOR DEMONSTRATION PURPOSES ONLY
# In production, you should generate a key pair using openssh and store the private key securely
resource "spirl_key_pair" "trust_domain_deployment" {
  algorithm = "ed25519"
}

resource "spirl_trust_domain" "test_domain" {
  domain_name = var.trust_domain_name
}

resource "spirl_trust_domain_deployment" "test_tdd" {
  trust_domain_id = spirl_trust_domain.test_domain.id
  name            = "test-deployment"
  keys = {
    "demo-key-1" = {
      active     = true
      public_key = spirl_key_pair.trust_domain_deployment.public_key_pem
    }
  }
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

resource "helm_release" "spirl-server" {
  provider         = helm.server_helm
  name             = spirl_trust_domain_deployment.test_tdd.id
  repository       = "oci://ghcr.io/spirl/charts"
  chart            = "spirl-server"
  namespace        = spirl_trust_domain_deployment.test_tdd.id
  create_namespace = true

  values = [<<-EOT
        controlPlane:
          auth:
            key:
              id: "${spirl_trust_domain_deployment.test_tdd.keys["demo-key-1"].id}"
              pem: ""
        trustDomainDeployment:
          trustDomainName: "${spirl_trust_domain.test_domain.domain_name}"
          trustDomainID: "${spirl_trust_domain.test_domain.id}"
          id: "${spirl_trust_domain_deployment.test_tdd.id}"
          name: "${spirl_trust_domain_deployment.test_tdd.name}"
EOT
  ]

  # Set the PEM key separately as a sensitive value
  set_sensitive = [
    {
      name  = "controlPlane.auth.key.pem"
      value = spirl_key_pair.trust_domain_deployment.private_key_pem
      type  = "string"
    }
  ]
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
        endpoint: ${var.agent_endpoint}
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
