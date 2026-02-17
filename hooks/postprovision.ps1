# =============================================================================
# Post-Provision Script: Connect AKS to Azure Arc and deploy VI extension
# =============================================================================

$ErrorActionPreference = "Stop"

Write-Host "=============================================="
Write-Host "Post-provision: Video Indexer Arc Setup"
Write-Host "=============================================="

if ($env:CREATE_IN_LOCAL -eq "false") {
    Write-Host "Skipping postprovision script for non local."
    exit 0
}

# Check if the Azure CLI is authenticated
$EXPIRED_TOKEN = (az ad signed-in-user show --query 'id' -o tsv 2>$null)

if (-not $EXPIRED_TOKEN) {
    Write-Host "No Azure user signed in. Please login."
    az login -o none
}

az account set -s $env:AZURE_SUBSCRIPTION_ID

# =====================================================
# Step 1: Get AKS credentials
# =====================================================
Write-Host ""
Write-Host ">> Step 1: Getting AKS cluster credentials..."
az aks get-credentials `
    --resource-group "$env:AZURE_RESOURCE_GROUP" `
    --name "$env:AZURE_AKS_CLUSTER_NAME" `
    --overwrite-existing

Write-Host "   AKS credentials configured."

# =====================================================
# Step 2: Connect AKS to Azure Arc
# =====================================================
$ARC_CLUSTER_NAME = "arc-$env:AZURE_AKS_CLUSTER_NAME"
Write-Host ""
Write-Host ">> Step 2: Connecting AKS cluster to Azure Arc as '$ARC_CLUSTER_NAME'..."

# Check if already connected
$ARC_EXISTS = $null
try {
    $ARC_EXISTS = (az connectedk8s show `
            --name "$ARC_CLUSTER_NAME" `
            --resource-group "$env:AZURE_RESOURCE_GROUP" `
            --query "name" -o tsv 2>$null)
}
catch {
    $ARC_EXISTS = $null
}

if ($ARC_EXISTS) {
    Write-Host "   Arc-connected cluster '$ARC_CLUSTER_NAME' already exists. Skipping."
}
else {
    az connectedk8s connect `
        --name "$ARC_CLUSTER_NAME" `
        --resource-group "$env:AZURE_RESOURCE_GROUP" `
        --location "$env:AZURE_LOCATION"
    Write-Host "   AKS cluster connected to Azure Arc."
}

# Save the Arc cluster name to azd env
azd env set AZURE_ARC_CLUSTER_NAME "$ARC_CLUSTER_NAME"

# =====================================================
# Step 3: Deploy VI Arc Extension via Bicep
# =====================================================
Write-Host ""
Write-Host ">> Step 3: Deploying Video Indexer Arc extension..."

az deployment group create `
    --resource-group "$env:AZURE_RESOURCE_GROUP" `
    --template-file ./infra/modules/vi-extension.bicep `
    --parameters `
    arcConnectedClusterName="$ARC_CLUSTER_NAME" `
    accountId="$env:AZURE_VIDEO_INDEXER_ACCOUNT_ID" `
    accountResourceId="$env:AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID"

Write-Host "   Video Indexer Arc extension deployed."

# =====================================================
# Summary
# =====================================================
Write-Host ""
Write-Host "=============================================="
Write-Host "Post-provision completed successfully!"
Write-Host "=============================================="
Write-Host ""
Write-Host "Resources created:"
Write-Host "  - AKS Cluster:      $env:AZURE_AKS_CLUSTER_NAME"
Write-Host "  - Arc Cluster:      $ARC_CLUSTER_NAME"
Write-Host "  - VI Account:       $env:AZURE_VIDEO_INDEXER_ACCOUNT_NAME"
Write-Host "  - Storage Account:  $env:AZURE_STORAGE_ACCOUNT_NAME"
Write-Host ""
