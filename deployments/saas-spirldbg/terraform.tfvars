# The kubeconfig context for the Kubernetes cluster where workloads and the spirl-agent will be deployed
agent_cluster_context = ""

# The issuer URL for the Kubernetes service account token (e.g., https://oidc.eks.us-west-2.amazonaws.com/id/<AWS_ACCOUNT_ID> for EKS)
agent_attestation_issuer_url = ""

# The path template for the SPIFFE IDs created for this cluster
cluster_path_template = "/{{cluster.name}}/ns/{{kubernetes.pod.namespace}}/sa/{{kubernetes.pod.service_account}}"

# The name of the Defakto cluster
cluster_name = "defakto-cluster"

# The name of the Defakto trust domain
trust_domain_name = "example.com"
