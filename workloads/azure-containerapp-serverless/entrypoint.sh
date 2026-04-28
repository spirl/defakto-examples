#!/bin/sh
set -e

MSI_TOKEN=$(curl "$IDENTITY_ENDPOINT?resource=https://storage.azure.com/&api-version=2019-08-01" \
  -H "X-IDENTITY-HEADER: $IDENTITY_HEADER" | jq -r '.access_token')

MSI_BYTES=$(printf '{"token": "%s"}' "$MSI_TOKEN" | base64 | tr -d '\n')

grpcurl \
  -d "{\"attestations\": [{\"method_type\": \"azure_msi\", \"method_version\": \"1.0\", \"evidence\": \"$MSI_BYTES\"}]}" \
  $SPIRL_SERVER_ADDRESS \
  com.spirl.serverless.alpha.SpiffeWorkloadAPI/FetchX509SVID
