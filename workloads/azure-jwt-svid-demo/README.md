# Azure JWT-SVID Federation Demo

This workload fetches a Defakto-issued JWT-SVID and uses it directly to authenticate to Azure via [Workload Identity Federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation), rather than handing the token off to an operator's local shell. It logs its SPIFFE ID to the console, then retries the Azure AD token exchange and a test blob download every 15 seconds until a matching federated credential exists.

Used by the [Azure Federation tutorial](https://d.spirl.com/mint/integration/azure/tutorial-azure-federation).

## Usage

In a Kubernetes cluster with a spirl-agent deployed, substitute your Azure values into the deployment configuration and apply it:

```shell
sed -e "s/<AZURE_TENANT_ID>/${AZURE_TENANT_ID}/" \
    -e "s/<MI_CLIENT_ID>/${MI_CLIENT_ID}/" \
    -e "s/<STORAGE_ACCOUNT_NAME>/${STORAGE_ACCOUNT_NAME}/" \
    -e "s/<CONTAINER_NAME>/${CONTAINER_NAME}/" \
    ./deployment.yaml | kubectl apply -f -
```

Then watch the pod logs:

```shell
kubectl logs -f deployment/azure-jwt-svid-demo
```

The logs will show the workload's SPIFFE ID. Create an Azure federated credential using that SPIFFE ID as the subject; the workload will pick it up on its next retry and print the test file's contents once authentication succeeds.
