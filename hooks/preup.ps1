# =============================================================================
# Pre-Up Script: Deployment preview and environment validation
# =============================================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/common.ps1"

Write-Banner "Pre-Up: Deployment Preview"

# =====================================================
# Step 1: Validate azd environment
# =====================================================
Write-Host ""
Write-Host ">> Step 1: Checking azd environment..."

if (-not $env:AZURE_ENV_NAME) {
    Write-Error "No azd environment detected. Run 'azd init' or 'azd env new <name>' first."
    exit 1
}

Write-Host "   Environment: $($env:AZURE_ENV_NAME)"
Write-Host "   Subscription: $(if ($env:AZURE_SUBSCRIPTION_ID) { $env:AZURE_SUBSCRIPTION_ID } else { 'not set' })"
Write-Host "   Location: $(if ($env:AZURE_LOCATION) { $env:AZURE_LOCATION } else { 'not set' })"

# =====================================================
# Step 2: Detect existing deployment
# =====================================================
Write-Host ""
Write-Host ">> Step 2: Checking for existing deployment..."

if ($env:AZURE_RESOURCE_GROUP) {
    $rgExists = $null
    try {
        $rgExists = (az group show -n $env:AZURE_RESOURCE_GROUP --query "name" -o tsv 2>$null)
    }
    catch {
        $rgExists = $null
    }

    if ($rgExists) {
        $resourceCount = 0
        try {
            $resourceCount = (az resource list -g $env:AZURE_RESOURCE_GROUP --query "length(@)" -o tsv 2>$null)
        }
        catch {
            $resourceCount = 0
        }
        Write-Host "   Existing deployment detected in '$($env:AZURE_RESOURCE_GROUP)'"
        Write-Host "   Resources in group: $resourceCount"

        if ($env:AZURE_AKS_CLUSTER_NAME) {
            $aksState = $null
            try {
                $aksState = (az aks show -g $env:AZURE_RESOURCE_GROUP -n $env:AZURE_AKS_CLUSTER_NAME `
                        --query "provisioningState" -o tsv 2>$null)
            }
            catch {
                $aksState = "not found"
            }
            Write-Host "   AKS cluster: $($env:AZURE_AKS_CLUSTER_NAME) ($aksState)"
        }

        Write-Host ""
        Write-Host "   Running 'azd up' will UPDATE the existing deployment."
    }
    else {
        Write-Host "   Resource group '$($env:AZURE_RESOURCE_GROUP)' not found in Azure."
        Write-Host "   A fresh deployment will be created."
    }
}
else {
    Write-Host "   No prior deployment detected. This will be a fresh deployment."
}

# =====================================================
# Step 3: Deployment summary
# =====================================================
Write-Host ""
Write-Banner "Video Indexer Arc - Deployment Summary"
Write-Host ""
Write-Host "  Environment:  $($env:AZURE_ENV_NAME)"
Write-Host "  Subscription: $(if ($env:AZURE_SUBSCRIPTION_ID) { $env:AZURE_SUBSCRIPTION_ID } else { 'not set' })"
Write-Host "  Location:     $(if ($env:AZURE_LOCATION) { $env:AZURE_LOCATION } else { 'not set' })"
Write-Host ""
Write-Host "  Infrastructure (via azd provision):"
Write-Host "    - AKS cluster with GPU node pool"
Write-Host "      ($VI_VM_SIZE)"
Write-Host "    - Storage Account"
Write-Host "    - Managed Identity"
Write-Host "    - Video Indexer Account"
Write-Host ""
Write-Host "  Post-provision automation:"
Write-Host "    - NVIDIA GPU Operator (via Helm)"
Write-Host "    - Azure Arc cluster connection"
Write-Host "    - Public IP + DNS configuration"
Write-Host "    - Nginx Ingress + App Routing"
Write-Host "    - Cert Manager extension"
Write-Host "    - VI Arc Extension"
Write-Host ""
Write-Host "  Estimated time: 25-40 minutes"
Write-Host "    Bicep provisioning:   ~15-25 min (GPU node pool)"
Write-Host "    Post-provision setup: ~10-15 min"
Write-Host ""
Write-Host "  NOTE: $VI_VM_SIZE GPU VMs incur"
Write-Host "  significant costs while the AKS cluster is running."
Write-Host "  Run 'azd down' when done to stop charges."
Write-Host ""
Write-Host "=============================================="
Write-Host ""
Write-Host "Starting deployment..."
