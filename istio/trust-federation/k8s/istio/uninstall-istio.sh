#!/usr/bin/env bash

echo "Uninstalling Istio..."
istioctl uninstall --purge -y

echo "Removing istio-system namespace..."
kubectl delete namespace istio-system --ignore-not-found=true

echo "Istio uninstalled successfully"
