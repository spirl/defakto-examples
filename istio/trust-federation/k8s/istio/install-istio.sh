#!/usr/bin/env bash
set -e

echo "Installing Istio with SPIRL integration..."
istioctl install -y -f k8s/istio/istio-initial.yaml

echo "Waiting for Istio to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/istiod -n istio-system
kubectl wait --for=condition=available --timeout=300s deployment/istio-ingressgateway -n istio-system

echo "Istio installed successfully"
