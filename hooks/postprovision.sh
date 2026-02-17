#!/bin/sh

# =============================================================================
# Post-Provision Script: Connect AKS to Azure Arc and deploy VI extension
# =============================================================================

set -e

echo "=============================================="
echo "Post-provision: Video Indexer Arc Setup"
echo "=============================================="

if [ "$CREATE_IN_LOCAL" = "false" ]; then
    echo "Skipping postprovision.sh script execution as it is not in local."
    exit 0
fi

# Check if the Azure CLI is authenticated
EXPIRED_TOKEN=$(az ad signed-in-user show --query 'id' -o tsv 2>/dev/null || true)

if [ -z "$EXPIRED_TOKEN" ]; then
    echo "No Azure user signed in. Please login."
    az login -o none
fi

az account set -s $AZURE_SUBSCRIPTION_ID

# =====================================================
# Step 1: Get AKS credentials
# =====================================================
echo ""
echo ">> Step 1: Getting AKS cluster credentials..."
az aks get-credentials \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_AKS_CLUSTER_NAME" \
    --overwrite-existing

echo "   AKS credentials configured."

# =====================================================
# Step 2: Connect AKS to Azure Arc
# =====================================================
ARC_CLUSTER_NAME="arc-${AZURE_AKS_CLUSTER_NAME}"
echo ""
echo ">> Step 2: Connecting AKS cluster to Azure Arc as '${ARC_CLUSTER_NAME}'..."

# Check if already connected
ARC_EXISTS=$(az connectedk8s show \
    --name "$ARC_CLUSTER_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query "name" -o tsv 2>/dev/null || true)

if [ -n "$ARC_EXISTS" ]; then
    echo "   Arc-connected cluster '$ARC_CLUSTER_NAME' already exists. Skipping."
else
    az connectedk8s connect \
        --name "$ARC_CLUSTER_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --location "$AZURE_LOCATION"
    echo "   AKS cluster connected to Azure Arc."
fi

# Save the Arc cluster name to azd env
azd env set AZURE_ARC_CLUSTER_NAME "$ARC_CLUSTER_NAME"

# =====================================================
# Step 3: Create Public IP and construct Endpoint URI
# =====================================================
echo ""
echo ">> Step 3: Creating Public IP and constructing Video Indexer endpoint URI..."

# Get AKS managed cluster resource group
AKS_MC_RG=$(az aks show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_AKS_CLUSTER_NAME" \
    --query "nodeResourceGroup" -o tsv)

echo "   AKS MC resource group: ${AKS_MC_RG}"

# Generate or reuse DNS label
if [ -n "$AZURE_DNS_LABEL" ]; then
    DNS_LABEL="$AZURE_DNS_LABEL"
    echo "   Reusing existing DNS label: ${DNS_LABEL}"
else
    RANDOM_SUFFIX=$(shuf -i 100-999 -n 1)
    DNS_LABEL="${AZURE_ENV_NAME}${RANDOM_SUFFIX}"
    echo "   Generated DNS label: ${DNS_LABEL}"
fi

PUBLIC_IP_NAME="${AZURE_ENV_NAME}-inbound-ip"

# Check if public IP already exists
PUBLIC_IP_EXISTS=$(az network public-ip show \
    --resource-group "$AKS_MC_RG" \
    --name "$PUBLIC_IP_NAME" \
    --query "name" -o tsv 2>/dev/null || true)

if [ -n "$PUBLIC_IP_EXISTS" ]; then
    echo "   Public IP '${PUBLIC_IP_NAME}' already exists. Skipping creation."
else
    az network public-ip create \
        --resource-group "$AKS_MC_RG" \
        --name "$PUBLIC_IP_NAME" \
        --sku Standard \
        --allocation-method Static \
        --dns-name "$DNS_LABEL"
    echo "   Public IP '${PUBLIC_IP_NAME}' created with DNS label '${DNS_LABEL}'."
fi

# Get the static IP address
STATIC_IP=$(az network public-ip show \
    --resource-group "$AKS_MC_RG" \
    --name "$PUBLIC_IP_NAME" \
    --query "ipAddress" -o tsv)

echo "   Static IP: ${STATIC_IP}"

# Construct endpoint URI
VIDEO_INDEXER_ENDPOINT_URI="https://${DNS_LABEL}.${AZURE_LOCATION}.cloudapp.azure.com"
echo "   Endpoint URI: ${VIDEO_INDEXER_ENDPOINT_URI}"

# Persist to azd env
azd env set AZURE_DNS_LABEL "${DNS_LABEL}"
azd env set AZURE_STATIC_IP "${STATIC_IP}"
azd env set AZURE_VIDEO_INDEXER_ENDPOINT_URI "${VIDEO_INDEXER_ENDPOINT_URI}"

# =====================================================
# Step 4: Deploy VI Arc Extension via Bicep
# =====================================================
echo ""
echo ">> Step 4: Deploying Video Indexer Arc extension..."

az deployment group create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --template-file ./infra/modules/vi-extension.bicep \
    --parameters \
        arcConnectedClusterName="$ARC_CLUSTER_NAME" \
        accountId="$AZURE_VIDEO_INDEXER_ACCOUNT_ID" \
        accountResourceId="$AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID" \
        videoIndexerEndpointUri="$VIDEO_INDEXER_ENDPOINT_URI"

echo "   Video Indexer Arc extension deployed."

# =====================================================
# Summary
# =====================================================
echo ""
echo "=============================================="
echo "Post-provision completed successfully!"
echo "=============================================="
echo ""
echo "Resources created:"
echo "  - AKS Cluster:      $AZURE_AKS_CLUSTER_NAME"
echo "  - Arc Cluster:      $ARC_CLUSTER_NAME"
echo "  - VI Account:       $AZURE_VIDEO_INDEXER_ACCOUNT_NAME"
echo "  - Storage Account:  $AZURE_STORAGE_ACCOUNT_NAME"
echo ""
