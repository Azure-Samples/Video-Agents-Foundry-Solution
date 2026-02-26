# =============================================================================
# Pre-Provision Script: Validate prerequisites before provisioning
# =============================================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/common.ps1"

Write-Banner "Pre-provision: Validation & Pre-flight Checks"

# =====================================================
# Step 1: Check Azure CLI authentication
# =====================================================
Write-Step "1" "Checking Azure CLI authentication..."

$accountInfo = $null
try {
    $accountInfo = (az account show --query "name" -o tsv 2>$null)
}
catch {
    $accountInfo = $null
}

if (-not $accountInfo) {
    Write-Error "Not logged in to Azure CLI. Run 'az login' before provisioning."
    exit 1
}

Write-Host "   Signed in to account: $accountInfo"

if ($env:AZURE_SUBSCRIPTION_ID) {
    try {
        az account set -s $env:AZURE_SUBSCRIPTION_ID 2>$null
    }
    catch {
        Write-Error "Cannot access subscription '$($env:AZURE_SUBSCRIPTION_ID)'. Verify the subscription ID and your access permissions."
        exit 1
    }
    $subName = (az account show --query "name" -o tsv 2>$null)
    Write-Host "   Subscription: $subName ($($env:AZURE_SUBSCRIPTION_ID))"
}

# =====================================================
# Step 2: Check required CLI tools
# =====================================================
Write-Step "2" "Checking required CLI tools..."

Assert-CliTools -Required @('az', 'helm', 'kubectl') -Optional @('kubelogin', 'jq')

# =====================================================
# Step 3: Validate required environment variables
# =====================================================
Write-Step "3" "Validating pre-provision environment variables..."

$preProvisionVars = @('AZURE_SUBSCRIPTION_ID', 'AZURE_LOCATION', 'AZURE_ENV_NAME')
foreach ($var in $preProvisionVars) {
    $val = [System.Environment]::GetEnvironmentVariable($var)
    if ($val) {
        Write-Host "   ${var}: $val"
    }
    else {
        Write-Host "   ${var}: MISSING" -ForegroundColor Red
    }
}
# Use the shared assertion for the actual error check
Assert-EnvVars $preProvisionVars

# =====================================================
# Step 4: Register required Azure resource providers
# =====================================================
Write-Step "4" "Checking Azure resource provider registrations..."

$null = Register-RequiredProviders

# =====================================================
# Step 5: Validate region supports required VM size
# =====================================================
Write-Step "5" "Checking region capability for GPU VMs..."

$vmAvailable = $null
try {
    $vmAvailable = (az vm list-sizes --location $env:AZURE_LOCATION `
        --query "[?name=='$VI_VM_SIZE']" -o tsv 2>$null)
}
catch {
    $vmAvailable = $null
}

if (-not $vmAvailable) {
    Write-Error "VM size '$VI_VM_SIZE' is not available in region '$($env:AZURE_LOCATION)'.`nThis VM is required for the GPU node pool.`n`nAvailable regions for $VI_VM_SIZE include:`n  eastus, eastus2, westus2, westus3, southcentralus,`n  northeurope, westeurope, southeastasia, australiaeast`n`nChange region with: azd env set AZURE_LOCATION <region>"
    exit 1
}

Write-Host "   ${VI_VM_SIZE}: available in $($env:AZURE_LOCATION)"

# =====================================================
# Step 6: Check GPU VM quota
# =====================================================
Write-Step "6" "Checking GPU VM quota..."

$quotaJson = $null
try {
    $quotaJson = (az vm list-usage --location $env:AZURE_LOCATION `
        --query "[?contains(name.value, '$VI_GPU_QUOTA_FAMILY')]" `
        -o json 2>$null) | ConvertFrom-Json
}
catch {
    $quotaJson = @()
}

$currentUsage = 0
$quotaLimit = 0

if ($quotaJson -and $quotaJson.Count -gt 0) {
    $currentUsage = $quotaJson[0].currentValue
    $quotaLimit = $quotaJson[0].limit
}

$available = $quotaLimit - $currentUsage

if ($quotaLimit -eq 0) {
    Write-Host "   WARNING: Could not determine GPU quota for $VI_VM_SIZE." -ForegroundColor Yellow
    Write-Host "   Family: $VI_GPU_QUOTA_FAMILY"
    Write-Host "   This may indicate zero quota in this subscription/region."
    Write-Host ""
    Write-Host "   Request GPU quota at:"
    Write-Host "   $QUOTA_URL"
    Write-Host ""
    Write-Host "   Proceeding anyway - provisioning will fail if quota is insufficient."
}
elseif ($available -lt $VI_GPU_CORES_NEEDED) {
    Write-Error "Insufficient GPU quota in $($env:AZURE_LOCATION).`n  VM Size:   $VI_VM_SIZE ($VI_GPU_CORES_NEEDED cores)`n  Available: $available cores ($currentUsage/$quotaLimit used)`n  Required:  $VI_GPU_CORES_NEEDED cores`n`nRequest quota increase at:`n$QUOTA_URL"
    exit 1
}
else {
    Write-Host "   GPU quota: $available cores available ($currentUsage/$quotaLimit used)"
    Write-Host "   Required:  $VI_GPU_CORES_NEEDED cores for $VI_VM_SIZE"
}

# =====================================================
# Summary
# =====================================================
Write-Host ""
Write-Banner "Pre-provision validation passed!"
Write-Host ""
Write-Host "  Subscription: $(if ($subName) { $subName } else { $env:AZURE_SUBSCRIPTION_ID })"
Write-Host "  Location:     $($env:AZURE_LOCATION)"
Write-Host "  Environment:  $($env:AZURE_ENV_NAME)"
Write-Host "  GPU VM:       $VI_VM_SIZE ($available cores available)"
Write-Host "  Providers:    all registered"
Write-Host "  Tools:        all present"
Write-Host ""
Write-Host "Proceeding with provisioning..."
