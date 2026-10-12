# Azure Container App Job — SPIFFE ID via MSI Attestation

Demonstrates a Docker container deployed as an Azure Container Apps job that obtains a SPIFFE SVID from a SPIRL Server using Azure Managed Service Identity (MSI) attestation.

The container fetches an MSI token from the Azure IMDS endpoint, passes it to the SPIRL Server via gRPC, and prints the resulting SPIFFE ID.

## Prerequisites

- Azure CLI with the Container Apps extension (`az extension add --name containerapp`)
- The image built from the python directory pushed to a container registry, referenced below as `<IMAGE>`
- A SPIRL Server with a serverless-enabled trust domain

## Steps

### 1. Create a Container Apps environment

```bash
az containerapp env create \
  --name <CONTAINER_APP_ENVIRONMENT> \
  --resource-group <RESOURCE_GROUP> \
  --location <LOCATION>
```

### 2. Create the Container App job

Azure validates the image pull during job creation, but the system-assigned identity can't be granted `AcrPull` until after it exists. To break this cycle, create the job with a placeholder public image first to provision the identity, then update it to the ACR image after assigning the role.

The `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` environment variables are injected automatically by Azure into containers that have a managed identity, which is what the entrypoint uses to fetch the MSI token.

```bash
az containerapp job create \
  --name spirl-azure-job \
  --resource-group <RESOURCE_GROUP> \
  --environment <CONTAINER_APP_ENVIRONMENT> \
  --trigger-type Manual \
  --replica-timeout 300 \
  --image <IMAGE> \
  --env-vars SPIRL_SERVER_ADDRESS=<SPIRL_SERVER_ADDRESS> \
  --mi-system-assigned
```

Replace `<SPIRL_SERVER_ADDRESS>` with the hostname of your SPIRL Server (e.g. `spirl.example.com:443`). 

### 3. Configure the trust domain

The SPIRL Server needs a `ServerlessAttestation` policy that accepts the job's MSI token. Retrieve the values you need from Azure:

```bash
# Azure tenant ID
az account show --query tenantId -o tsv

# Principal ID of the job's managed identity
az containerapp job show \
  --name spirl-azure-job \
  --resource-group <RESOURCE_GROUP> \
  --query "identity.principalId" -o tsv
```

Then apply a configuration to your trust domain using those values:

```yaml
section: ServerlessAttestation
schema: v1
spec:
  policies:
    - name: azure-spirl
      svidPolicy:
        pathTemplate: "/azure/{{azure_msi.identity.principal_id}}"
      requiredAttestors:
        - type: azure_msi
          config:
            tenants:
              - tenantID: "<TENANT_ID>"
                principalID: "<PRINCIPAL_ID>"
                audience: "fb60f99c-7a34-4190-8149-302f77469936"
                issuerURL: "https://login.microsoftonline.com/e5aefa75-2f20-4be6-8bbc-e6000a7935ce/v2.0"
```

Note that `fb60f99c-7a34-4190-8149-302f77469936` is the appID for the Azure AD Token Exchange Endpoint and is the default audience for MSI Tokens
given to a containerapp job.

### 4. Run the job

```bash
az containerapp job start \
  --name spirl-azure-job \
  --resource-group <RESOURCE_GROUP>
```

### 5. Check the logs

List executions to find the latest execution name:

```bash
az containerapp job execution list \
  --name spirl-azure-job \
  --resource-group <RESOURCE_GROUP> \
  --query "[0].name" -o tsv
```

Stream the console logs for that execution:

```bash
az containerapp logs show \
  --name spirl-azure-job \
  --resource-group <RESOURCE_GROUP> \
  --type console \
  --follow
```

The output will contain the gRPC response from the SPIRL Server, including the SPIFFE ID assigned to the job, e.g.:

```
{
  "svids": [
    {
      "spiffe_id": "spiffe://<trust-domain>/az/..."
    }
  ]
}
```
