#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIRED_ISTIO_MINOR="1.21"

ISTIO_VERSION=$(istioctl version --remote=false 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
if ! echo "${ISTIO_VERSION}" | grep -q "^${REQUIRED_ISTIO_MINOR}\."; then
  echo "ERROR: istioctl ${REQUIRED_ISTIO_MINOR}.x required (found: ${ISTIO_VERSION})"
  echo "Install: curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.21.6 sh -"
  exit 1
fi

echo "Installing Istio ${ISTIO_VERSION}..."
istioctl install -y -f "${SCRIPT_DIR}/istio-initial.yaml" --readiness-timeout 10m0s

echo "Waiting for Istio to be ready..."
kubectl wait --for=condition=available --timeout=600s deployment/istiod -n istio-system
kubectl wait --for=condition=available --timeout=600s deployment/istio-ingressgateway -n istio-system

echo "Istio installed successfully"
