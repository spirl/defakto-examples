terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "trust_domain_name" {
  description = "SPIFFE trust domain (e.g. demo.example.com)"
  type        = string
}

variable "cluster_name" {
  description = "Defakto cluster name — used to construct SPIFFE IDs"
  type        = string
}

variable "kubeconfig_context" {
  description = "kubeconfig context to use"
  type        = string
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  namespace        = "envoy-demo"
  server_sa        = "demo-server"
  client_sa        = "demo-client"
  # SPIFFE ID format follows the default Defakto K8s path template:
  #   /{{cluster.name}}/ns/{{kubernetes.pod.namespace}}
  server_spiffe_id = "spiffe://${var.trust_domain_name}/${var.cluster_name}/ns/${local.namespace}/sa/${local.server_sa}"
  client_spiffe_id = "spiffe://${var.trust_domain_name}/${var.cluster_name}/ns/${local.namespace}/sa/${local.client_sa}"
}

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = var.kubeconfig_context
}

# ---------------------------------------------------------------------------
# Namespace + service accounts
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "demo" {
  metadata {
    name = local.namespace
  }
}

resource "kubernetes_service_account" "server" {
  metadata {
    name      = local.server_sa
    namespace = kubernetes_namespace.demo.metadata[0].name
  }
}

resource "kubernetes_service_account" "client" {
  metadata {
    name      = local.client_sa
    namespace = kubernetes_namespace.demo.metadata[0].name
  }
}

# ---------------------------------------------------------------------------
# nginx config — listens on :8080 instead of the default :80
# ---------------------------------------------------------------------------

resource "kubernetes_config_map" "nginx" {
  metadata {
    name      = "nginx-config"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }

  data = {
    "default.conf" = <<-NGINX
      server {
          listen 8080;
          location / {
              add_header Content-Type text/plain;
              return 200 "Hello from demo-server\nClient SPIFFE ID: $http_x_client_spiffe_id\n";
          }
      }
    NGINX
  }
}

# ---------------------------------------------------------------------------
# Envoy config — server
#
# Listener :8443 terminates mTLS via SDS and forwards to nginx on :8080.
# Verifies the client presents the expected SPIFFE ID.
# ---------------------------------------------------------------------------

resource "kubernetes_config_map" "envoy_server" {
  metadata {
    name      = "envoy-server"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }

  data = {
    "envoy.yaml" = <<-YAML
      node:
        id: demo-server
        cluster: demo-server

      admin:
        address:
          socket_address: { address: 127.0.0.1, port_value: 9901 }

      static_resources:
        clusters:

        - name: spiffe_agent_sds
          type: STATIC
          typed_extension_protocol_options:
            envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
              "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
              explicit_http_config:
                http2_protocol_options: {}
          load_assignment:
            cluster_name: spiffe_agent_sds
            endpoints:
            - lb_endpoints:
              - endpoint:
                  address:
                    pipe:
                      path: /spirl-agent-socket/agent.sock

        - name: local_nginx
          type: STATIC
          connect_timeout: 0.25s
          load_assignment:
            cluster_name: local_nginx
            endpoints:
            - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: { address: 127.0.0.1, port_value: 8080 }

        listeners:
        - name: ingress_mtls
          address:
            socket_address: { address: 0.0.0.0, port_value: 8443 }
          filter_chains:
          - transport_socket:
              name: envoy.transport_sockets.tls
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
                require_client_certificate: true
                common_tls_context:
                  tls_certificate_sds_secret_configs:
                  - name: default
                    sds_config:
                      resource_api_version: V3
                      api_config_source:
                        api_type: GRPC
                        transport_api_version: V3
                        grpc_services:
                        - envoy_grpc:
                            cluster_name: spiffe_agent_sds
                  combined_validation_context:
                    default_validation_context:
                      match_subject_alt_names:
                      - exact: "${local.client_spiffe_id}"
                    validation_context_sds_secret_config:
                      name: ROOTCA
                      sds_config:
                        resource_api_version: V3
                        api_config_source:
                          api_type: GRPC
                          transport_api_version: V3
                          grpc_services:
                          - envoy_grpc:
                              cluster_name: spiffe_agent_sds
            filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: ingress_http
                route_config:
                  virtual_hosts:
                  - name: local
                    domains: ["*"]
                    request_headers_to_add:
                    - header:
                        key: x-client-spiffe-id
                        value: "%DOWNSTREAM_PEER_URI_SAN%"
                    routes:
                    - match: { prefix: "/" }
                      route: { cluster: local_nginx }
                http_filters:
                - name: envoy.filters.http.router
                  typed_config:
                    "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  YAML
  }
}

# ---------------------------------------------------------------------------
# Envoy config — client
#
# Listener :9090 accepts plain HTTP from the curl loop and proxies to the
# server service over mTLS, verifying the server's SPIFFE ID.
# ---------------------------------------------------------------------------

resource "kubernetes_config_map" "envoy_client" {
  metadata {
    name      = "envoy-client"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }

  data = {
    "envoy.yaml" = <<-YAML
      node:
        id: demo-client
        cluster: demo-client

      admin:
        address:
          socket_address: { address: 127.0.0.1, port_value: 9901 }

      static_resources:
        clusters:

        - name: spiffe_agent_sds
          type: STATIC
          typed_extension_protocol_options:
            envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
              "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
              explicit_http_config:
                http2_protocol_options: {}
          load_assignment:
            cluster_name: spiffe_agent_sds
            endpoints:
            - lb_endpoints:
              - endpoint:
                  address:
                    pipe:
                      path: /spirl-agent-socket/agent.sock

        - name: demo_server_mtls
          type: STRICT_DNS
          connect_timeout: 1s
          load_assignment:
            cluster_name: demo_server_mtls
            endpoints:
            - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: { address: demo-server, port_value: 8443 }
          transport_socket:
            name: envoy.transport_sockets.tls
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
              common_tls_context:
                tls_certificate_sds_secret_configs:
                - name: default
                  sds_config:
                    resource_api_version: V3
                    api_config_source:
                      api_type: GRPC
                      transport_api_version: V3
                      grpc_services:
                      - envoy_grpc:
                          cluster_name: spiffe_agent_sds
                combined_validation_context:
                  default_validation_context:
                    match_subject_alt_names:
                    - exact: "${local.server_spiffe_id}"
                  validation_context_sds_secret_config:
                    name: ROOTCA
                    sds_config:
                      resource_api_version: V3
                      api_config_source:
                        api_type: GRPC
                        transport_api_version: V3
                        grpc_services:
                        - envoy_grpc:
                            cluster_name: spiffe_agent_sds

        listeners:
        - name: egress_proxy
          address:
            socket_address: { address: 127.0.0.1, port_value: 9090 }
          filter_chains:
          - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: egress_http
                route_config:
                  virtual_hosts:
                  - name: demo_server
                    domains: ["*"]
                    routes:
                    - match: { prefix: "/" }
                      route: { cluster: demo_server_mtls }
                http_filters:
                - name: envoy.filters.http.router
                  typed_config:
                    "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  YAML
  }
}

# ---------------------------------------------------------------------------
# Server deployment
#
# nginx on :8080, Envoy sidecar on :8443 (mTLS termination).
# The k8s.spirl.com/spiffe-csi label triggers the Defakto Admission Controller
# to inject the agent socket into all containers at /spirl-agent-socket/agent.sock.
# ---------------------------------------------------------------------------

resource "kubernetes_deployment" "server" {
  metadata {
    name      = "demo-server"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "demo-server" }
    }
    template {
      metadata {
        labels = {
          app                        = "demo-server"
          "k8s.spirl.com/spiffe-csi" = "enabled"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.server.metadata[0].name

        container {
          name  = "nginx"
          image = "nginx:alpine"
          port { container_port = 8080 }
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/conf.d"
          }
        }

        container {
          name  = "envoy"
          image = "envoyproxy/envoy:v1.32-latest"
          args  = ["envoy", "-c", "/etc/envoy/envoy.yaml"]
          port { container_port = 8443 }
          volume_mount {
            name       = "envoy-config"
            mount_path = "/etc/envoy"
            read_only  = true
          }
        }

        volume {
          name = "envoy-config"
          config_map { name = kubernetes_config_map.envoy_server.metadata[0].name }
        }
        volume {
          name = "nginx-config"
          config_map { name = kubernetes_config_map.nginx.metadata[0].name }
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Client deployment
#
# curl loop hits localhost:9090 → Envoy → mTLS → server.
# ---------------------------------------------------------------------------

resource "kubernetes_deployment" "client" {
  metadata {
    name      = "demo-client"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "demo-client" }
    }
    template {
      metadata {
        labels = {
          app                        = "demo-client"
          "k8s.spirl.com/spiffe-csi" = "enabled"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.client.metadata[0].name

        container {
          name    = "curl"
          image   = "curlimages/curl:latest"
          command = ["sh", "-c", "while true; do echo \"--- $(date)\"; curl -sS --max-time 3 http://localhost:9090/ || echo '[FAILED]'; echo; sleep 5; done"]
        }

        container {
          name  = "envoy"
          image = "envoyproxy/envoy:v1.32-latest"
          args  = ["envoy", "-c", "/etc/envoy/envoy.yaml"]
          volume_mount {
            name       = "envoy-config"
            mount_path = "/etc/envoy"
            read_only  = true
          }
        }

        volume {
          name = "envoy-config"
          config_map { name = kubernetes_config_map.envoy_client.metadata[0].name }
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Service — exposes the server's Envoy mTLS port within the cluster
# ---------------------------------------------------------------------------

resource "kubernetes_service" "server" {
  metadata {
    name      = "demo-server"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }

  spec {
    selector = { app = "demo-server" }
    port {
      name        = "mtls"
      port        = 8443
      target_port = 8443
    }
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "server_spiffe_id" {
  value = local.server_spiffe_id
}

output "client_spiffe_id" {
  value = local.client_spiffe_id
}

output "verify_client_logs" {
  value = "kubectl logs -n ${local.namespace} -l app=demo-client -c curl -f"
}

output "verify_envoy_server_admin" {
  value = "kubectl port-forward -n ${local.namespace} deploy/demo-server 9901:9901"
}
