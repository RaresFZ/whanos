#!/usr/bin/env bash
set -euo pipefail

# Fix kubeconfig after network changes or IP address changes
# This script updates the kubeconfig with the current k3d cluster configuration

echo "🔧 Fixing kubeconfig for k3d cluster..."

# Check if k3d is available
if ! command -v k3d &> /dev/null; then
    echo "❌ Error: k3d command not found"
    exit 1
fi

# Check if whanos cluster exists
if ! k3d cluster list | grep -q whanos; then
    echo "❌ Error: k3d cluster 'whanos' not found"
    echo "Available clusters:"
    k3d cluster list
    exit 1
fi

# Update kubeconfig
echo "📝 Updating kubeconfig from k3d cluster..."
k3d kubeconfig merge whanos --kubeconfig-merge-default --kubeconfig-switch-context

# Verify connection
echo "✅ Testing connection..."
if kubectl cluster-info &> /dev/null; then
    echo "✅ Success! kubectl can now connect to the cluster"
    kubectl get nodes
else
    echo "❌ Warning: kubectl still cannot connect to the cluster"
    echo "You may need to restart the k3d cluster:"
    echo "  k3d cluster stop whanos"
    echo "  k3d cluster start whanos"
    exit 1
fi
