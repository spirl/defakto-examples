#!/bin/bash
# Check if bookinfo pods have Istio sidecars

echo "Checking if bookinfo pods have sidecars..."
echo ""

for deployment in productpage-v1 details-v1 reviews-v2 reviews-v3 ratings-v1; do
  echo "=== $deployment ==="
  containers=$(kubectl get pod -n bookinfo -l app=${deployment%-*} -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null)

  if [[ $containers == *"istio-proxy"* ]]; then
    echo "✓ Has sidecar (istio-proxy container present)"
  else
    echo "✗ No sidecar (containers: $containers)"
  fi
  echo ""
done
