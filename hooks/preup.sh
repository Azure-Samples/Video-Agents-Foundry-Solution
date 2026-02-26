#!/bin/bash

# =============================================================================
# Pre-Up Script: Deployment preview and environment validation
# =============================================================================

set -e

echo "=============================================="
echo "Pre-Up: Deployment Preview"
echo "=============================================="

# =====================================================
# Step 1: Validate azd environment
# =====================================================
echo ""
echo ">> Step 1: Checking azd environment..."

if [ -z "${AZURE_ENV_NAME:-}" ]; then
    echo "   ERROR: No azd environment detected." >&2
    echo "   Run 'azd init' or 'azd env new <name>' first." >&2
    exit 1
fi

echo "   Environment: ${AZURE_ENV_NAME}"
echo "   Subscription: ${AZURE_SUBSCRIPTION_ID:-not set}"
echo "   Location: ${AZURE_LOCATION:-not set}"

# =====================================================
# Step 2: Detect existing deployment
# =====================================================
echo ""
echo ">> Step 2: Checking for existing deployment..."

if [ -n "${AZURE_RESOURCE_GROUP:-}" ]; then
    RG_EXISTS=$(az group show -n "$AZURE_RESOURCE_GROUP" --query "name" -o tsv 2>/dev/null || true)
    if [ -n "$RG_EXISTS" ]; then
        RESOURCE_COUNT=$(az resource list -g "$AZURE_RESOURCE_GROUP" --query "length(@)" -o tsv 2>/dev/null || echo "0")
        echo "   Existing deployment detected in '${AZURE_RESOURCE_GROUP}'"
        echo "   Resources in group: ${RESOURCE_COUNT}"

        # Check AKS cluster
        if [ -n "${AZURE_AKS_CLUSTER_NAME:-}" ]; then
            AKS_STATE=$(az aks show -g "$AZURE_RESOURCE_GROUP" -n "$AZURE_AKS_CLUSTER_NAME" \
                --query "provisioningState" -o tsv 2>/dev/null || echo "not found")
            echo "   AKS cluster: ${AZURE_AKS_CLUSTER_NAME} (${AKS_STATE})"
        fi

        echo ""
        echo "   Running 'azd up' will UPDATE the existing deployment."
    else
        echo "   Resource group '${AZURE_RESOURCE_GROUP}' not found in Azure."
        echo "   A fresh deployment will be created."
    fi
else
    echo "   No prior deployment detected. This will be a fresh deployment."
fi

# =====================================================
# Step 3: Deployment summary
# =====================================================
echo ""
echo "=============================================="
echo "  Video Indexer Arc - Deployment Summary"
echo "=============================================="
echo ""
echo "  Environment:  ${AZURE_ENV_NAME}"
echo "  Subscription: ${AZURE_SUBSCRIPTION_ID:-not set}"
echo "  Location:     ${AZURE_LOCATION:-not set}"
echo ""
echo "  Infrastructure (via azd provision):"
echo "    - AKS cluster with GPU node pool"
echo "      (Standard_NC24ads_A100_v4)"
echo "    - Storage Account"
echo "    - Managed Identity"
echo "    - Video Indexer Account"
echo "    - Policy Exemptions"
echo ""
echo "  Post-provision automation:"
echo "    - NVIDIA GPU Operator (via Helm)"
echo "    - Azure Arc cluster connection"
echo "    - Public IP + DNS configuration"
echo "    - Nginx Ingress + App Routing"
echo "    - Cert Manager extension"
echo "    - VI Arc Extension"
echo ""
echo "  Estimated time: 25-40 minutes"
echo "    Bicep provisioning:   ~15-25 min (GPU node pool)"
echo "    Post-provision setup: ~10-15 min"
echo ""
echo "  NOTE: Standard_NC24ads_A100_v4 GPU VMs incur"
echo "  significant costs while the AKS cluster is running."
echo "  Run 'azd down' when done to stop charges."
echo ""
echo "=============================================="
echo ""
echo "Starting deployment..."
