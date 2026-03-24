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
# Step 5: Validate region supports required VM sizes
# =====================================================
Write-Step "5" "Checking region capability for GPU VMs..."

$gpuVmCores = @{}

foreach ($gpuVm in @($DEEPSTREAM_GPU_VM_SIZE, $INFERENCE_GPU_VM_SIZE)) {
    $vmInfo = $null
    try {
        $vmInfo = (az vm list-sizes --location $env:AZURE_LOCATION `
                --query "[?name=='$gpuVm'] | [0]" -o json 2>$null) | ConvertFrom-Json
    }
    catch {
        $vmInfo = $null
    }

    if (-not $vmInfo) {
        Write-Error "VM size '$gpuVm' is not available in region '$($env:AZURE_LOCATION)'.`nThis VM is required for a GPU node pool.`n`nChange region with: azd env set AZURE_LOCATION <region>"
        exit 1
    }

    $gpuVmCores[$gpuVm] = $vmInfo.numberOfCores
    Write-Host "   ${gpuVm}: available in $($env:AZURE_LOCATION) ($($vmInfo.numberOfCores) cores)"
}

# =====================================================
# Step 6: Check GPU VM quota
# =====================================================
Write-Step "6" "Checking GPU VM quota..."

$allPassed = $true

function Test-GpuQuota {
    param (
        [string]$PoolName,
        [string]$VmSize,
        [string]$Family,
        [int]$MaxNodes
    )

    $CoresPerVm = $gpuVmCores[$VmSize]
    $coresNeeded = $CoresPerVm * $MaxNodes

    $quotaJson = @()
    try {
        $raw = (az vm list-usage --location $env:AZURE_LOCATION `
                --query "[?contains(name.value, '$Family')]" `
                -o json 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "az vm list-usage failed: $raw"
        }
        $quotaJson = $raw | ConvertFrom-Json
    }
    catch {
        Write-Host "   [$PoolName] ERROR: Failed to query GPU quota — $_" -ForegroundColor Red
        return $false
    }

    $currentUsage = 0
    $quotaLimit = 0

    if ($quotaJson -and $quotaJson.Count -gt 0) {
        $currentUsage = $quotaJson[0].currentValue
        $quotaLimit = $quotaJson[0].limit
    }

    $available = $quotaLimit - $currentUsage

    Write-Host "   [$PoolName] $VmSize — $MaxNodes node(s) x $CoresPerVm cores = $coresNeeded cores needed"

    if ($quotaLimit -eq 0) {
        Write-Host "   [$PoolName] ERROR: No GPU quota found for family '$Family' in region '$($env:AZURE_LOCATION)'." -ForegroundColor Red
        Write-Host "   This typically means zero quota is allocated for this subscription/region."
        Write-Host "   Request GPU quota at: $QUOTA_URL"
        Write-Host "   For step-by-step instructions, see: $GPU_QUOTA_DOC_URL"
        return $false
    }
    elseif ($available -lt $coresNeeded) {
        Write-Host "   [$PoolName] ERROR: Insufficient quota — $available cores available, $coresNeeded required ($currentUsage/$quotaLimit used)" -ForegroundColor Red
        Write-Host "   Request quota increase at: $QUOTA_URL"
        Write-Host "   For step-by-step instructions, see: $GPU_QUOTA_DOC_URL"
        return $false
    }
    else {
        Write-Host "   [$PoolName] OK — $available cores available ($currentUsage/$quotaLimit used)"
    }

    return $true
}

if (-not (Test-GpuQuota -PoolName "Deepstream" -VmSize $DEEPSTREAM_GPU_VM_SIZE -Family $DEEPSTREAM_GPU_QUOTA_FAMILY -MaxNodes $DEEPSTREAM_GPU_MAX_NODE_COUNT)) {
    $allPassed = $false
}
if (-not (Test-GpuQuota -PoolName "Inference" -VmSize $INFERENCE_GPU_VM_SIZE -Family $INFERENCE_GPU_QUOTA_FAMILY -MaxNodes $INFERENCE_GPU_MAX_NODE_COUNT)) {
    $allPassed = $false
}

if (-not $allPassed) {
    exit 1
}

# =====================================================
# Summary
# =====================================================
Write-Host ""
Write-Banner "Pre-provision validation passed!"
Write-Host ""
Write-Host "  Subscription:    $(if ($subName) { $subName } else { $env:AZURE_SUBSCRIPTION_ID })"
Write-Host "  Location:        $($env:AZURE_LOCATION)"
Write-Host "  Environment:     $($env:AZURE_ENV_NAME)"
Write-Host "  Deepstream GPU:  $DEEPSTREAM_GPU_VM_SIZE ($DEEPSTREAM_GPU_MAX_NODE_COUNT node(s))"
Write-Host "  Inference GPU:   $INFERENCE_GPU_VM_SIZE ($INFERENCE_GPU_MAX_NODE_COUNT node(s))"
Write-Host "  Providers:       all registered"
Write-Host "  Tools:           all present"
Write-Host ""
Write-Host "Proceeding with provisioning..."
