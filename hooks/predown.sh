#!/bin/bash

# =============================================================================
# Pre-Down Script: Graceful teardown preparation
# =============================================================================

set -e

source "$(dirname "$0")/common.sh"

write_banner "Pre-Down: Graceful Teardown Preparation"

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
echo "  Confirmed. Proceeding with 'azd down' to delete resource group..."
echo "  All resources (extensions, Arc cluster, GPU operator, ingress) will be"
echo "  removed automatically when the resource group is deleted."
