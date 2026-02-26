# =============================================================================
# Pre-Down Script: Graceful teardown preparation
# =============================================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/common.ps1"

Write-Banner "Pre-Down: Graceful Teardown Preparation"

# =====================================================
# Step 1: Destruction warning
# =====================================================
Write-Host ""
Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
Write-Host "!            DESTRUCTIVE OPERATION              !" -ForegroundColor Red
Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
Write-Host ""
Write-Host "  'azd down' will DESTROY the following resources:"
Write-Host ""
Write-Host "  Resource Group:  $(if ($env:AZURE_RESOURCE_GROUP) { $env:AZURE_RESOURCE_GROUP } else { 'not set' })"
Write-Host "  AKS Cluster:     $(if ($env:AZURE_AKS_CLUSTER_NAME) { $env:AZURE_AKS_CLUSTER_NAME } else { 'not set' })"
Write-Host "  Arc Cluster:     $(if ($env:AZURE_ARC_CLUSTER_NAME) { $env:AZURE_ARC_CLUSTER_NAME } else { 'not set' })"
Write-Host "  VI Account:      $(if ($env:AZURE_VIDEO_INDEXER_ACCOUNT_ID) { $env:AZURE_VIDEO_INDEXER_ACCOUNT_ID } else { 'not set' })"
Write-Host "  Storage Account: and all stored data"
Write-Host "  Public IP:       $(if ($env:AZURE_STATIC_IP) { $env:AZURE_STATIC_IP } else { 'not set' })"
Write-Host "  GPU Nodes:       $VI_VM_SIZE"
Write-Host ""
Write-Host "  This action CANNOT be undone."
Write-Host "  Re-provisioning takes 25-40 minutes."
Write-Host ""

# Prompt for confirmation
$confirm = Read-Host "  Type 'destroy' to confirm teardown"
if ($confirm -ne "destroy") {
    Write-Host ""
    Write-Host "  Aborted. No resources were modified."
    exit 1
}

Write-Host ""
Write-Host "  Confirmed. Proceeding with 'azd down' to delete resource group..."
Write-Host "  All resources (extensions, Arc cluster, GPU operator, ingress) will be"
Write-Host "  removed automatically when the resource group is deleted."
