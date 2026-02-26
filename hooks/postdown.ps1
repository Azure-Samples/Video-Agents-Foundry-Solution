# =============================================================================
# Post-Down Script: Local state cleanup after resource deletion
# =============================================================================

$ErrorActionPreference = "Stop"

Write-Host "=============================================="
Write-Host "Post-Down: Local State Cleanup"
Write-Host "=============================================="

# =====================================================
# Step 1: Clean up kubectl context
# =====================================================
Write-Host ""
Write-Host ">> Step 1: Cleaning up kubectl context..."

$aksCluster = $env:AZURE_AKS_CLUSTER_NAME
$resourceGroup = $env:AZURE_RESOURCE_GROUP

if ($aksCluster) {
    # Remove admin context (used by postprovision)
    try {
        kubectl config delete-context "$aksCluster-admin" 2>$null
        Write-Host "   Removed context: $aksCluster-admin"
    }
    catch {
        Write-Host "   Context '$aksCluster-admin' not found (already clean)"
    }

    # Remove regular context
    try {
        kubectl config delete-context $aksCluster 2>$null
        Write-Host "   Removed context: $aksCluster"
    }
    catch {
        # May not exist
    }

    # Remove cluster entry
    try {
        kubectl config delete-cluster $aksCluster 2>$null
        Write-Host "   Removed cluster: $aksCluster"
    }
    catch {
        # May not exist
    }

    # Remove user entries
    try {
        kubectl config delete-user "clusterAdmin_${resourceGroup}_${aksCluster}" 2>$null
        kubectl config delete-user "clusterUser_${resourceGroup}_${aksCluster}" 2>$null
        Write-Host "   Removed user credentials"
    }
    catch {
        # May not exist
    }

    # Check if deleted context was the active one
    $currentCtx = $null
    try {
        $currentCtx = kubectl config current-context 2>$null
    }
    catch {
        $currentCtx = $null
    }

    if (-not $currentCtx) {
        Write-Host ""
        Write-Host "   No active kubectl context. Set one with:"
        Write-Host "     kubectl config use-context <context-name>"
    }
}
else {
    Write-Host "   No AKS cluster name configured. Skipping."
}

# =====================================================
# Step 2: Clean up azd environment variables
# =====================================================
Write-Host ""
Write-Host ">> Step 2: Cleaning up azd environment variables..."

# Clear resource-specific variables (these reference deleted resources)
$varsToClear = @(
    'AZURE_AKS_CLUSTER_NAME',
    'AZURE_ARC_CLUSTER_NAME',
    'AZURE_RESOURCE_GROUP',
    'AZURE_STATIC_IP',
    'AZURE_DNS_LABEL',
    'AZURE_AKS_NODE_RESOURCE_GROUP',
    'AZURE_VIDEO_INDEXER_ENDPOINT_URI',
    'AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID',
    'AZURE_STORAGE_ACCOUNT_NAME',
    'AZURE_VIDEO_INDEXER_ACCOUNT_NAME'
)

Write-Host ""
Write-Host "   Clearing resource-specific variables:"
foreach ($var in $varsToClear) {
    try {
        azd env set $var "" 2>$null
    }
    catch {
        # May fail if azd env is already gone
    }
    Write-Host "     ${var}: cleared"
}

# Preserve user-configured variables
$varsToPreserve = @(
    'AZURE_SUBSCRIPTION_ID',
    'AZURE_LOCATION',
    'AZURE_ENV_NAME',
    'AZURE_VIDEO_INDEXER_ACCOUNT_ID',
    'AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE'
)

Write-Host ""
Write-Host "   Preserved variables (user-configured):"
foreach ($var in $varsToPreserve) {
    $val = $null
    try {
        $val = (azd env get-value $var 2>$null)
    }
    catch {
        $val = $null
    }

    if ($val) {
        Write-Host "     ${var}: $val"
    }
    else {
        Write-Host "     ${var}: (not set)"
    }
}

# =====================================================
# Step 3: Verify resource group deletion
# =====================================================
Write-Host ""
Write-Host ">> Step 3: Verifying resource group deletion..."

if ($resourceGroup) {
    $rgState = $null
    try {
        $rgState = (az group show -n $resourceGroup --query "properties.provisioningState" -o tsv 2>$null)
    }
    catch {
        $rgState = $null
    }

    if (-not $rgState) {
        Write-Host "   Resource group '$resourceGroup': deleted"
    }
    elseif ($rgState -eq "Deleting") {
        Write-Host "   Resource group '$resourceGroup': deletion in progress"
        Write-Host "   This can take 5-10 minutes for GPU infrastructure."
        Write-Host "   Monitor with:"
        Write-Host "     az group show -n $resourceGroup --query properties.provisioningState"
    }
    else {
        Write-Host "   Resource group '$resourceGroup': $rgState"
        Write-Host "   You may need to manually delete it:"
        Write-Host "     az group delete -n $resourceGroup --yes --no-wait"
    }
}
else {
    Write-Host "   No resource group name configured. Skipping."
}

# =====================================================
# Step 4: Clean up Helm repos
# =====================================================
Write-Host ""
Write-Host ">> Step 4: Cleaning up Helm repos..."

$helmRepos = $null
try {
    $helmRepos = (helm repo list -o json 2>$null) | ConvertFrom-Json
}
catch {
    $helmRepos = @()
}

if ($helmRepos | Where-Object { $_.name -eq "nvidia" }) {
    try {
        helm repo remove nvidia 2>$null
        Write-Host "   Removed Helm repo: nvidia"
    }
    catch {
        Write-Host "   Failed to remove nvidia repo"
    }
}
else {
    Write-Host "   nvidia repo: not present (already clean)"
}

# =====================================================
# Summary
# =====================================================
Write-Host ""
Write-Host "=============================================="
Write-Host "  Video Indexer Arc - Teardown Complete"
Write-Host "=============================================="
Write-Host ""
Write-Host "  Azure Resources:   deleted (or deletion in progress)"
Write-Host "  kubectl Context:   removed"
Write-Host "  Helm Repos:        cleaned"
Write-Host "  azd Environment:   $(if ($env:AZURE_ENV_NAME) { $env:AZURE_ENV_NAME } else { 'n/a' }) (preserved)"
Write-Host ""
Write-Host "  To re-deploy:"
Write-Host "    azd up"
Write-Host ""
Write-Host "  To completely remove the azd environment:"
Write-Host "    azd env delete $(if ($env:AZURE_ENV_NAME) { $env:AZURE_ENV_NAME } else { '<env-name>' })"
Write-Host ""
