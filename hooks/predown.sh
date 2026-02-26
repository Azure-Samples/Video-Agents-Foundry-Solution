#!/bin/bash

# =============================================================================
# Pre-Down Script: Graceful teardown preparation
# =============================================================================

set -e

source "$(dirname "$0")/common.sh"

write_banner "Pre-Down: Graceful Teardown Preparation"

CLEANUP_ERRORS=0

# =====================================================
# Step 1: Destruction warning
# =====================================================
echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!            DESTRUCTIVE OPERATION              !"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo ""
echo "  'azd down' will DESTROY the following resources:"
echo ""
echo "  Resource Group:  ${AZURE_RESOURCE_GROUP:-not set}"
echo "  AKS Cluster:     ${AZURE_AKS_CLUSTER_NAME:-not set}"
echo "  Arc Cluster:     ${AZURE_ARC_CLUSTER_NAME:-not set}"
echo "  VI Account:      ${AZURE_VIDEO_INDEXER_ACCOUNT_ID:-not set}"
echo "  Storage Account: and all stored data"
echo "  Public IP:       ${AZURE_STATIC_IP:-not set}"
echo "  GPU Nodes:       ${VI_VM_SIZE}"
echo ""
echo "  This action CANNOT be undone."
echo "  Re-provisioning takes 25-40 minutes."
echo ""

# Prompt for confirmation
read -r -p "  Type 'destroy' to confirm teardown: " CONFIRM
if [ "$CONFIRM" != "destroy" ]; then
    echo ""
    echo "  Aborted. No resources were modified."
    exit 1
fi

echo ""
echo "  Confirmed. Starting graceful teardown..."

# =====================================================
# Step 2: Get AKS credentials
# =====================================================
echo ""
echo ">> Step 2: Getting AKS cluster credentials..."

HAS_CLUSTER_ACCESS=false
if [ -n "${AZURE_RESOURCE_GROUP:-}" ] && [ -n "${AZURE_AKS_CLUSTER_NAME:-}" ]; then
    KUBE_CONTEXT=$(connect_aks_cluster) && {
        HAS_CLUSTER_ACCESS=true
        echo "   AKS credentials configured."
    } || {
        echo "   WARNING: Could not get AKS credentials."
        echo "   Cluster may already be deleted or unreachable."
        echo "   Skipping Kubernetes-level cleanup."
    }
else
    echo "   WARNING: AKS cluster info not available. Skipping Kubernetes-level cleanup."
fi

# =====================================================
# Step 3: Remove Video Indexer Arc Extension
# =====================================================
echo ""
echo ">> Step 3: Removing Video Indexer Arc Extension..."

ARC_CLUSTER_NAME="${AZURE_ARC_CLUSTER_NAME:-}"
if [ -n "$ARC_CLUSTER_NAME" ] && [ -n "${AZURE_RESOURCE_GROUP:-}" ]; then
    az k8s-extension delete \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --cluster-name "$ARC_CLUSTER_NAME" \
        --cluster-type connectedClusters \
        --name videoindexer \
        --yes 2>/dev/null && {
        echo "   VI Arc Extension: removed"
    } || {
        echo "   VI Arc Extension: skipped (not found or already removed)"
        CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    }

    # Wait for namespace cleanup if cluster is accessible
    if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
        echo "   Waiting for ${NS_VIDEO_INDEXER} namespace cleanup (up to ${TIMEOUT_NS_CLEANUP}s)..."
        kubectl --context "$KUBE_CONTEXT" wait --for=delete namespace/$NS_VIDEO_INDEXER \
            --timeout=${TIMEOUT_NS_CLEANUP}s 2>/dev/null || true
    fi
else
    echo "   Skipped (no Arc cluster configured)"
fi

# =====================================================
# Step 4: Remove Cert Manager Extension
# =====================================================
echo ""
echo ">> Step 4: Removing Cert Manager Extension..."

if [ -n "$ARC_CLUSTER_NAME" ] && [ -n "${AZURE_RESOURCE_GROUP:-}" ]; then
    az k8s-extension delete \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --cluster-name "$ARC_CLUSTER_NAME" \
        --cluster-type connectedClusters \
        --name cert-manager \
        --yes 2>/dev/null && {
        echo "   Cert Manager: removed"
    } || {
        echo "   Cert Manager: skipped (not found or already removed)"
        CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    }
else
    echo "   Skipped (no Arc cluster configured)"
fi

# =====================================================
# Step 5: Remove NVIDIA GPU Operator
# =====================================================
echo ""
echo ">> Step 5: Removing NVIDIA GPU Operator..."

if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
    helm uninstall gpu-operator -n "$NS_GPU_OPERATOR" \
        --kube-context "$KUBE_CONTEXT" 2>/dev/null && {
        echo "   GPU Operator: Helm release removed"
    } || {
        echo "   GPU Operator: skipped (not found or already removed)"
        CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    }

    kubectl --context "$KUBE_CONTEXT" delete namespace "$NS_GPU_OPERATOR" \
        --timeout=${TIMEOUT_NS_DELETE}s 2>/dev/null || true
    echo "   GPU Operator namespace: cleaned up"
else
    echo "   Skipped (no cluster access)"
fi

# =====================================================
# Step 6: Disconnect Arc Cluster
# =====================================================
echo ""
echo ">> Step 6: Disconnecting Azure Arc cluster..."

if [ -n "$ARC_CLUSTER_NAME" ] && [ -n "${AZURE_RESOURCE_GROUP:-}" ]; then
    az connectedk8s delete \
        --name "$ARC_CLUSTER_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --yes 2>/dev/null && {
        echo "   Arc cluster '${ARC_CLUSTER_NAME}': disconnected"
    } || {
        echo "   Arc cluster: skipped (not found or already disconnected)"
        CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    }
else
    echo "   Skipped (no Arc cluster configured)"
fi

# =====================================================
# Step 7: Clean up Ingress and LoadBalancer
# =====================================================
echo ""
echo ">> Step 7: Cleaning up Ingress and LoadBalancer..."

if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
    # Delete NginxIngressController custom resource
    kubectl --context "$KUBE_CONTEXT" delete nginxingresscontroller nginx \
        2>/dev/null || true

    # Delete LoadBalancer services to release public IP
    kubectl --context "$KUBE_CONTEXT" delete svc nginx -n "$NS_APP_ROUTING" \
        2>/dev/null || true

    echo "   Ingress resources: cleaned up"
else
    echo "   Skipped (no cluster access)"
fi

# =====================================================
# Summary
# =====================================================
echo ""
write_banner "Pre-down cleanup complete"
echo ""
echo "  VI Extension:   removed"
echo "  Cert Manager:   removed"
echo "  GPU Operator:   removed"
echo "  Arc Connection: disconnected"
echo "  Ingress/LB:     cleaned up"
echo ""

if [ "$CLEANUP_ERRORS" -gt 0 ]; then
    echo "  ${CLEANUP_ERRORS} cleanup step(s) had warnings."
    echo "  Resource group deletion will clean up remaining resources."
    echo ""
fi

echo "Proceeding with 'azd down' to delete resource group..."
