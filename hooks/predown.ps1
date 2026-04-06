# =============================================================================
# Pre-Down Cleanup: Remove resources created outside azd's tracked scope
# =============================================================================
# The postprovision hook creates a Public IP in the AKS node resource group
# (MC_ group), which azd down does not track. This hook cleans it up before
# the resource group is deleted.
# =============================================================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "  Pre-down cleanup: removing untracked resources..." -ForegroundColor Cyan
Write-Host ""

# ── Public IP in the AKS node resource group ────────────────────────────────
$AKS_MC_RG = $env:AZURE_AKS_NODE_RESOURCE_GROUP
$PUBLIC_IP_NAME = "$($env:AZURE_ENV_NAME)-inbound-ip"

if (-not $AKS_MC_RG -or -not $env:AZURE_ENV_NAME) {
    Write-Host "  [SKIP] Missing AZURE_AKS_NODE_RESOURCE_GROUP or AZURE_ENV_NAME. Nothing to clean up." -ForegroundColor Yellow
    exit 0
}

$exists = $null
try {
    $exists = (az network public-ip show `
            --resource-group "$AKS_MC_RG" `
            --name "$PUBLIC_IP_NAME" `
            --query "name" -o tsv 2>$null)
}
catch {
    $exists = $null
}

if ($exists) {
    Write-Host "  Deleting public IP '$PUBLIC_IP_NAME' from '$AKS_MC_RG'..."
    az network public-ip delete `
        --resource-group "$AKS_MC_RG" `
        --name "$PUBLIC_IP_NAME" 2>$null
    Write-Host "  [OK] Public IP deleted." -ForegroundColor Green
}
else {
    Write-Host "  [SKIP] Public IP '$PUBLIC_IP_NAME' not found in '$AKS_MC_RG'. Nothing to clean up." -ForegroundColor Yellow
}

# ── Arc-connected cluster ────────────────────────────────────────────────────
$ARC_CLUSTER_NAME = $env:AZURE_ARC_CLUSTER_NAME
$RESOURCE_GROUP = $env:AZURE_RESOURCE_GROUP

if ($ARC_CLUSTER_NAME -and $RESOURCE_GROUP) {
    $arcExists = $null
    try {
        $arcExists = (az connectedk8s show `
                --name "$ARC_CLUSTER_NAME" `
                --resource-group "$RESOURCE_GROUP" `
                --query "name" -o tsv 2>$null)
    }
    catch {
        $arcExists = $null
    }

    if ($arcExists) {
        Write-Host "  Disconnecting Arc cluster '$ARC_CLUSTER_NAME'..."
        az connectedk8s delete `
            --name "$ARC_CLUSTER_NAME" `
            --resource-group "$RESOURCE_GROUP" `
            --yes 2>$null
        Write-Host "  [OK] Arc cluster disconnected." -ForegroundColor Green
    }
    else {
        Write-Host "  [SKIP] Arc cluster '$ARC_CLUSTER_NAME' not found. Nothing to clean up." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "  Pre-down cleanup complete." -ForegroundColor Green
Write-Host ""
