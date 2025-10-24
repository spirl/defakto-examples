# AWS Load Balancer Configuration for Trust Domain Servers

This guide provides example configurations for exposing trust-domain servers running in Amazon EKS clusters to agents via either an Application Load Balancer (ALB) or Network Load Balancer (NLB).

After deploying a trust-domain server in an EKS cluster, you must set up a load balancer to allow agents to connect to the servers. Both configurations provide TLS termination at the load balancer level, with plaintext connections between the load balancer and the trust-domain servers.

## Common Prerequisites

Before setting up either load balancer, ensure you have:

1. A trust-domain server deployed in your EKS cluster
2. A registered domain name for agent connections
3. A DNS zone where you can create records (Route 53, or external DNS provider)
4. An SSL/TLS certificate for your domain uploaded to AWS Certificate Manager (ACM)
5. Appropriate IAM permissions to create load balancers and manage ACM certificates

## Setting up an Application Load Balancer (ALB)

This configuration sets up an internal ALB with TLS termination. Agents connect to the ALB using TLS, and the ALB connects to the trust-domain servers using plaintext HTTP/gRPC.

### Requirements

* Meet the [prerequisites for setting up an ALB](https://docs.aws.amazon.com/eks/latest/userguide/alb-ingress.html)
* Install and configure the AWS Load Balancer Controller in your EKS cluster

### Configuration Steps

1. **Edit the configuration file**

   In the `ingress.yaml` file, replace the following placeholders:
   * `<TDD_ID>` - Your trust domain deployment ID (appears in multiple locations)
   * `<YOUR-CERT-ARN>` - Your ACM certificate ARN identifier
   * `<AGENT_ENDPOINT>` - The fully qualified domain name agents will use to connect (e.g., `agents.example.com`)

2. **Apply the configuration**

   ```bash
   kubectl apply -f ingress.yaml
   ```

3. **Get the ALB endpoint**

   ```bash
   kubectl get ingress tdd-<TDD_ID>-spirl-server-agent -n tdd-<TDD_ID>
   ```

   Note the `ADDRESS` field - this is your ALB's DNS name.

4. **Configure DNS**

   Create a CNAME record pointing your agent endpoint domain to the ALB DNS name:
   ```
   agents.example.com  CNAME  k8s-tdd12345-xxxxxxxx.us-east-1.elb.amazonaws.com
   ```

### Verify the Deployment

```bash
# Check ingress status
kubectl get ingress tdd-<TDD_ID>-spirl-server-agent -n tdd-<TDD_ID>

# Verify the backend service
kubectl get service tdd-<TDD_ID>-spirl-server-agent -n tdd-<TDD_ID>

# Test connectivity (once DNS propagates)
grpcurl -d '{"service":""}' <AGENT_ENDPOINT>:443 grpc.health.v1.Health/Check
```

## Setting up a Network Load Balancer (NLB)

This configuration sets up an internet-facing NLB with TLS termination. Agents connect to the NLB using TLS, and the NLB connects to the trust-domain servers using plaintext TCP.

### Requirements

* Meet the [prerequisites for setting up an NLB](https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html)

### Configuration Steps

1. **Edit the configuration file**

   In the `service.yaml` file, replace the following placeholders:
   * `<TDD_ID>` - Your trust domain deployment ID (appears in multiple locations)
   * `<YOUR-CERT-ARN>` - Your ACM certificate ARN identifier

2. **Apply the configuration**

   ```bash
   kubectl apply -f service.yaml
   ```

3. **Get the NLB endpoint**

   ```bash
   kubectl get service tdd-<TDD_ID>-spirl-server-agent -n tdd-<TDD_ID>-test-alb
   ```

   Note the `EXTERNAL-IP` field - this is your NLB's DNS name.

4. **Configure DNS**

   Create an A record (alias) or CNAME record pointing your agent endpoint domain to the NLB DNS name:
   ```
   agents.example.com  CNAME  a1234567890abcdef.elb.us-east-1.amazonaws.com
   ```

### Verify the Deployment

```bash
# Check service status
kubectl get service tdd-<TDD_ID>-spirl-server-agent -n tdd-<TDD_ID>-test-alb

# Verify the service is assigned an external IP
kubectl describe service tdd-<TDD_ID>-spirl-server-agent -n tdd-<TDD_ID>-test-alb

# Test connectivity (once DNS propagates)
grpcurl -d '{"service":""}' <AGENT_ENDPOINT>:443 grpc.health.v1.Health/Check
```

## Troubleshooting

### Load balancer not provisioning

- **ALB**: Ensure the AWS Load Balancer Controller is installed and has proper IAM permissions
- **NLB**: Check that your subnets have available IP addresses and proper tags

### Certificate errors

- Verify the certificate ARN is correct and the certificate status is "Issued" in ACM
- Ensure the certificate covers the domain name you're using for the agent endpoint
- Confirm the certificate is in the same AWS region as your EKS cluster

### Connection timeouts

- Verify security groups allow traffic on port 443
- Check that the backend pods are running: `kubectl get pods -n tdd-<TDD_ID>`
- Ensure DNS has propagated: `nslookup <AGENT_ENDPOINT>`

### Health check failures

- Review ALB target group health in the AWS Console
- Check application logs: `kubectl logs -n tdd-<TDD_ID> -l app=spirl-server`
- Verify the health check path is correct for your application