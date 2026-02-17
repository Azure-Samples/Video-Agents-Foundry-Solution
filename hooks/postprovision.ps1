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
# Step 3: Create Public IP and construct Endpoint URI
# =====================================================
Write-Host ""
Write-Host ">> Step 3: Creating Public IP and constructing Video Indexer endpoint URI..."

# Get AKS managed cluster resource group
$AKS_MC_RG = (az aks show `
        --resource-group "$env:AZURE_RESOURCE_GROUP" `
        --name "$env:AZURE_AKS_CLUSTER_NAME" `
        --query "nodeResourceGroup" -o tsv)

Write-Host "   AKS MC resource group: $AKS_MC_RG"

# Generate or reuse DNS label
if ($env:AZURE_DNS_LABEL) {
    $DNS_LABEL = $env:AZURE_DNS_LABEL
    Write-Host "   Reusing existing DNS label: $DNS_LABEL"
}
else {
    $RANDOM_SUFFIX = Get-Random -Minimum 100 -Maximum 999
    $DNS_LABEL = "$($env:AZURE_ENV_NAME)$RANDOM_SUFFIX"
    Write-Host "   Generated DNS label: $DNS_LABEL"
}

$PUBLIC_IP_NAME = "$($env:AZURE_ENV_NAME)-inbound-ip"

# Check if public IP already exists
$PUBLIC_IP_EXISTS = $null
try {
    $PUBLIC_IP_EXISTS = (az network public-ip show `
            --resource-group "$AKS_MC_RG" `
            --name "$PUBLIC_IP_NAME" `
            --query "name" -o tsv 2>$null)
}
catch {
    $PUBLIC_IP_EXISTS = $null
}

if ($PUBLIC_IP_EXISTS) {
    Write-Host "   Public IP '$PUBLIC_IP_NAME' already exists. Skipping creation."
}
else {
    az network public-ip create `
        --resource-group "$AKS_MC_RG" `
        --name "$PUBLIC_IP_NAME" `
        --sku Standard `
        --allocation-method Static `
        --dns-name "$DNS_LABEL"
    Write-Host "   Public IP '$PUBLIC_IP_NAME' created with DNS label '$DNS_LABEL'."
}

# Get the static IP address
$STATIC_IP = (az network public-ip show `
        --resource-group "$AKS_MC_RG" `
        --name "$PUBLIC_IP_NAME" `
        --query "ipAddress" -o tsv)

Write-Host "   Static IP: $STATIC_IP"

# Construct endpoint URI
$VIDEO_INDEXER_ENDPOINT_URI = "https://${DNS_LABEL}.$($env:AZURE_LOCATION).cloudapp.azure.com"
Write-Host "   Endpoint URI: $VIDEO_INDEXER_ENDPOINT_URI"

# Persist to azd env
azd env set AZURE_DNS_LABEL "$DNS_LABEL"
azd env set AZURE_STATIC_IP "$STATIC_IP"
azd env set AZURE_VIDEO_INDEXER_ENDPOINT_URI "$VIDEO_INDEXER_ENDPOINT_URI"

# =====================================================
# Step 4: Deploy VI Arc Extension via Bicep
# =====================================================
Write-Host ""
Write-Host ">> Step 4: Deploying Video Indexer Arc extension..."

az deployment group create `
    --resource-group "$env:AZURE_RESOURCE_GROUP" `
    --template-file ./infra/modules/vi-extension.bicep `
    --parameters `
    arcConnectedClusterName="$ARC_CLUSTER_NAME" `
    accountId="$env:AZURE_VIDEO_INDEXER_ACCOUNT_ID" `
    accountResourceId="$env:AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID" `
    videoIndexerEndpointUri="$VIDEO_INDEXER_ENDPOINT_URI"

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
