#!/bin/bash

# =============================================================================
# Pre-Down Cleanup: Remove resources created outside azd's tracked scope
# =============================================================================
# The postprovision hook creates a Public IP in the AKS node resource group
# (MC_ group), which azd down does not track. This hook cleans it up before
# the resource group is deleted.
# =============================================================================

set -e

echo ""
echo "  Pre-down cleanup: removing untracked resources..."
echo ""

# ── Public IP in the AKS node resource group ────────────────────────────────
AKS_MC_RG="${AZURE_AKS_NODE_RESOURCE_GROUP}"
PUBLIC_IP_NAME="${AZURE_ENV_NAME}-inbound-ip"

if [ -z "$AKS_MC_RG" ] || [ -z "$AZURE_ENV_NAME" ]; then
    echo "  [SKIP] Missing AZURE_AKS_NODE_RESOURCE_GROUP or AZURE_ENV_NAME. Nothing to clean up."
    exit 0
fi

IP_EXISTS=$(az network public-ip show \
    --resource-group "$AKS_MC_RG" \
    --name "$PUBLIC_IP_NAME" \
    --query "name" -o tsv 2>/dev/null || true)

if [ -n "$IP_EXISTS" ]; then
    echo "  Deleting public IP '$PUBLIC_IP_NAME' from '$AKS_MC_RG'..."
    az network public-ip delete \
        --resource-group "$AKS_MC_RG" \
        --name "$PUBLIC_IP_NAME" 2>/dev/null
    echo "  [OK] Public IP deleted."
else
    echo "  [SKIP] Public IP '$PUBLIC_IP_NAME' not found in '$AKS_MC_RG'. Nothing to clean up."
fi

# ── Arc-connected cluster ────────────────────────────────────────────────────
ARC_CLUSTER_NAME="${AZURE_ARC_CLUSTER_NAME}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}"

if [ -n "$ARC_CLUSTER_NAME" ] && [ -n "$RESOURCE_GROUP" ]; then
    ARC_EXISTS=$(az connectedk8s show \
        --name "$ARC_CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "name" -o tsv 2>/dev/null || true)

    if [ -n "$ARC_EXISTS" ]; then
        echo "  Disconnecting Arc cluster '$ARC_CLUSTER_NAME'..."
        az connectedk8s delete \
            --name "$ARC_CLUSTER_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --yes 2>/dev/null
        echo "  [OK] Arc cluster disconnected."
    else
        echo "  [SKIP] Arc cluster '$ARC_CLUSTER_NAME' not found. Nothing to clean up."
    fi
fi

echo ""
echo "  Pre-down cleanup complete."
echo ""
