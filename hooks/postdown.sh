#!/bin/bash

# =============================================================================
# Post-Down Script: Local state cleanup after resource deletion
# =============================================================================

set -e

echo "=============================================="
echo "Post-Down: Local State Cleanup"
echo "=============================================="

# =====================================================
# Step 1: Clean up kubectl context
# =====================================================
echo ""
echo ">> Step 1: Cleaning up kubectl context..."

AKS_CLUSTER="${AZURE_AKS_CLUSTER_NAME:-}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"

if [ -n "$AKS_CLUSTER" ]; then
    # Remove admin context (used by postprovision.sh)
    kubectl config delete-context "${AKS_CLUSTER}-admin" 2>/dev/null && {
        echo "   Removed context: ${AKS_CLUSTER}-admin"
    } || echo "   Context '${AKS_CLUSTER}-admin' not found (already clean)"

    # Remove regular context
    kubectl config delete-context "${AKS_CLUSTER}" 2>/dev/null && {
        echo "   Removed context: ${AKS_CLUSTER}"
    } || true

    # Remove cluster entry
    kubectl config delete-cluster "${AKS_CLUSTER}" 2>/dev/null && {
        echo "   Removed cluster: ${AKS_CLUSTER}"
    } || true

    # Remove user entries
    kubectl config delete-user "clusterAdmin_${RESOURCE_GROUP}_${AKS_CLUSTER}" 2>/dev/null || true
    kubectl config delete-user "clusterUser_${RESOURCE_GROUP}_${AKS_CLUSTER}" 2>/dev/null || true
    echo "   Removed user credentials"

    # Check if deleted context was the active one
    CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "")
    if [ -z "$CURRENT_CTX" ]; then
        echo ""
        echo "   No active kubectl context. Set one with:"
        echo "     kubectl config use-context <context-name>"
    fi
else
    echo "   No AKS cluster name configured. Skipping."
fi

# =====================================================
# Step 2: Clean up azd environment variables
# =====================================================
echo ""
echo ">> Step 2: Cleaning up azd environment variables..."

# Clear resource-specific variables (these reference deleted resources)
VARS_TO_CLEAR="AZURE_AKS_CLUSTER_NAME AZURE_ARC_CLUSTER_NAME AZURE_RESOURCE_GROUP AZURE_STATIC_IP AZURE_DNS_LABEL AZURE_AKS_NODE_RESOURCE_GROUP AZURE_VIDEO_INDEXER_ENDPOINT_URI AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID AZURE_STORAGE_ACCOUNT_NAME AZURE_VIDEO_INDEXER_ACCOUNT_NAME"

echo ""
echo "   Clearing resource-specific variables:"
for var in $VARS_TO_CLEAR; do
    azd env set "$var" "" 2>/dev/null || true
    echo "     ${var}: cleared"
done

# Preserve user-configured variables
echo ""
echo "   Preserved variables (user-configured):"
for var in AZURE_SUBSCRIPTION_ID AZURE_LOCATION AZURE_ENV_NAME AZURE_VIDEO_INDEXER_ACCOUNT_ID AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE; do
    val=$(azd env get-value "$var" 2>/dev/null || echo "")
    if [ -n "$val" ]; then
        echo "     ${var}: ${val}"
    else
        echo "     ${var}: (not set)"
    fi
done

# =====================================================
# Step 3: Verify resource group deletion
# =====================================================
echo ""
echo ">> Step 3: Verifying resource group deletion..."

RG_NAME="${RESOURCE_GROUP}"
if [ -n "$RG_NAME" ]; then
    RG_CHECK=$(az group show -n "$RG_NAME" --query "properties.provisioningState" -o tsv 2>/dev/null || echo "Deleted")
    case "$RG_CHECK" in
        Deleted|"")
            echo "   Resource group '${RG_NAME}': deleted"
            ;;
        Deleting)
            echo "   Resource group '${RG_NAME}': deletion in progress"
            echo "   This can take 5-10 minutes for GPU infrastructure."
            echo "   Monitor with:"
            echo "     az group show -n ${RG_NAME} --query properties.provisioningState"
            ;;
        *)
            echo "   Resource group '${RG_NAME}': ${RG_CHECK}"
            echo "   You may need to manually delete it:"
            echo "     az group delete -n ${RG_NAME} --yes --no-wait"
            ;;
    esac
else
    echo "   No resource group name configured. Skipping."
fi

# =====================================================
# Step 4: Clean up Helm repos
# =====================================================
echo ""
echo ">> Step 4: Cleaning up Helm repos..."

HELM_REPOS=$(helm repo list -o json 2>/dev/null || echo "[]")

if echo "$HELM_REPOS" | grep -q '"nvidia"' 2>/dev/null; then
    helm repo remove nvidia 2>/dev/null && {
        echo "   Removed Helm repo: nvidia"
    } || echo "   Failed to remove nvidia repo"
else
    echo "   nvidia repo: not present (already clean)"
fi

# =====================================================
# Summary
# =====================================================
echo ""
echo "=============================================="
echo "  Video Indexer Arc - Teardown Complete"
echo "=============================================="
echo ""
echo "  Azure Resources:   deleted (or deletion in progress)"
echo "  kubectl Context:   removed"
echo "  Helm Repos:        cleaned"
echo "  azd Environment:   ${AZURE_ENV_NAME:-n/a} (preserved)"
echo ""
echo "  To re-deploy:"
echo "    azd up"
echo ""
echo "  To completely remove the azd environment:"
echo "    azd env delete ${AZURE_ENV_NAME:-<env-name>}"
echo ""
