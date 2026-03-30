# =============================================================================
# Pre-Provision Script: Validate prerequisites before provisioning
# =============================================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/common.ps1"

$totalSteps = 5

Write-FoundryBanner -Phase "Pre-Provision Validation"

# =====================================================
# Step 1: Check Azure CLI authentication
# =====================================================
Log-Step -Number 1 -Total $totalSteps -Title "Checking Azure CLI Authentication"

$accountInfo = $null
try {
    $accountInfo = (az account show --query "name" -o tsv 2>$null)
}
catch {
    $accountInfo = $null
}

if (-not $accountInfo) {
    Log-Error "Not logged in to Azure CLI. Run 'az login' before provisioning."
    exit 1
}

Log-Success "Signed in to account: $accountInfo"

if ($env:AZURE_SUBSCRIPTION_ID) {
    try {
        az account set -s $env:AZURE_SUBSCRIPTION_ID 2>$null
    }
    catch {
        Log-Error "Cannot access subscription '$($env:AZURE_SUBSCRIPTION_ID)'."
        Log-Info "Verify the subscription ID and your access permissions."
        exit 1
    }
    $subName = (az account show --query "name" -o tsv 2>$null)
    Log-Success "Subscription: $subName"
    Write-KeyValue "ID" $env:AZURE_SUBSCRIPTION_ID
}

# =====================================================
# Step 2: Check required CLI tools
# =====================================================
Log-Step -Number 2 -Total $totalSteps -Title "Checking Required CLI Tools"

Assert-CliTools -Required @('az', 'helm', 'kubectl') -Optional @('kubelogin', 'jq')

# =====================================================
# Step 3: Validate required environment variables
# =====================================================
Log-Step -Number 3 -Total $totalSteps -Title "Validating Environment Variables"

$preProvisionVars = @('AZURE_SUBSCRIPTION_ID', 'AZURE_LOCATION', 'AZURE_ENV_NAME')
foreach ($var in $preProvisionVars) {
    $val = [System.Environment]::GetEnvironmentVariable($var)
    if ($val) {
        Write-KeyValue $var $val
    }
    else {
        Write-HealthRow -Name $var -Status "Fail" -Detail "not set"
    }
}
# Use the shared assertion for the actual error check
Assert-EnvVars $preProvisionVars

# =====================================================
# Step 4: Select VM sizes for AKS node pools
#         (includes region availability + GPU quota checks)
# =====================================================
Log-Step -Number 4 -Total $totalSteps -Title "Selecting VM Sizes for AKS Node Pools"

$allVmSizes = Invoke-WithSpinner -Message "Querying VM sizes in $($env:AZURE_LOCATION)" -Action {
    Get-AzVmSizesForRegion -Location $env:AZURE_LOCATION
} -SuccessMessage "Found VM sizes in $($env:AZURE_LOCATION)"

if ($allVmSizes.Count -eq 0) {
    Log-Error "Could not retrieve VM sizes for region '$($env:AZURE_LOCATION)'."
    exit 1
}

Log-Info "$($allVmSizes.Count) VM sizes available"

# Determine current/default values (env var overrides config default)
$currentSystemVm     = if ($env:SYSTEM_VM_SIZE)          { $env:SYSTEM_VM_SIZE }          else { $DEFAULT_SYSTEM_VM_SIZE }
$currentWorkloadVm   = if ($env:WORKLOAD_VM_SIZE)        { $env:WORKLOAD_VM_SIZE }        else { $DEFAULT_WORKLOAD_VM_SIZE }
$currentDeepstreamVm = if ($env:DEEPSTREAM_GPU_VM_SIZE)  { $env:DEEPSTREAM_GPU_VM_SIZE }  else { $DEFAULT_DEEPSTREAM_GPU_SIZE }
$currentInferenceVm  = if ($env:INFERENCE_GPU_VM_SIZE)   { $env:INFERENCE_GPU_VM_SIZE }   else { $DEFAULT_INFERENCE_GPU_SIZE }

# Pick recommended VM sizes per pool (4 families x 3 sizes = ~12 items each)
$systemVmSizes   = Select-VmSizesForMenu -AllSizes $allVmSizes -Prefixes $CPU_VM_PREFIXES -RecommendedFamilies $SYSTEM_RECOMMENDED_FAMILIES   -DefaultSku $currentSystemVm     -SizesPerFamily $SIZES_PER_FAMILY -MaxCores $SYSTEM_MAX_CORES
$workloadVmSizes = Select-VmSizesForMenu -AllSizes $allVmSizes -Prefixes $CPU_VM_PREFIXES -RecommendedFamilies $WORKLOAD_RECOMMENDED_FAMILIES -DefaultSku $currentWorkloadVm   -SizesPerFamily $SIZES_PER_FAMILY -MinCores $WORKLOAD_MIN_CORES
$gpuVmSizes      = Select-VmSizesForMenu -AllSizes $allVmSizes -Prefixes $GPU_VM_PREFIXES -RecommendedFamilies $GPU_RECOMMENDED_FAMILIES      -DefaultSku $currentDeepstreamVm -SizesPerFamily $SIZES_PER_FAMILY

Write-KeyValue "System pool"   "$($systemVmSizes.Count) sizes"
Write-KeyValue "Workload pool" "$($workloadVmSizes.Count) sizes"
Write-KeyValue "GPU pool"      "$($gpuVmSizes.Count) sizes"

$quotaData = Invoke-WithSpinner -Message "Querying GPU quota" -Action {
    Get-AzVmQuotaForRegion -Location $env:AZURE_LOCATION
} -SuccessMessage "GPU quota data retrieved"

Write-Section "Choose a VM SKU for each AKS node pool"
Log-Info "The default is highlighted. Press Enter to accept, C for custom."

# CPU pools (separate lists for system vs workload)
$selectedSystem   = Show-VmSelectionMenu -PoolName "System (CPU)"   -EnvVarName "SYSTEM_VM_SIZE"   -VmSizes $systemVmSizes   -DefaultSku $currentSystemVm   -Location $env:AZURE_LOCATION
$selectedWorkload = Show-VmSelectionMenu -PoolName "Workload (CPU)" -EnvVarName "WORKLOAD_VM_SIZE" -VmSizes $workloadVmSizes -DefaultSku $currentWorkloadVm -Location $env:AZURE_LOCATION

# GPU pools (quota validated inline, node count determines total cores checked)
$selectedDeepstream = Show-VmSelectionMenu -PoolName "Deepstream (GPU)" -EnvVarName "DEEPSTREAM_GPU_VM_SIZE" -VmSizes $gpuVmSizes -DefaultSku $currentDeepstreamVm -Location $env:AZURE_LOCATION -IsGpu -MaxNodes $DEEPSTREAM_GPU_MAX_NODE_COUNT -QuotaData $quotaData
$selectedInference  = Show-VmSelectionMenu -PoolName "Inference (GPU)"  -EnvVarName "INFERENCE_GPU_VM_SIZE"  -VmSizes $gpuVmSizes -DefaultSku $currentInferenceVm  -Location $env:AZURE_LOCATION -IsGpu -MaxNodes $INFERENCE_GPU_MAX_NODE_COUNT  -QuotaData $quotaData

# Update script-scope variables for downstream consumers
$DEEPSTREAM_GPU_VM_SIZE = $selectedDeepstream.Sku
$INFERENCE_GPU_VM_SIZE  = $selectedInference.Sku

# =====================================================
# Step 5: Register required Azure resource providers
# =====================================================
Log-Step -Number 5 -Total $totalSteps -Title "Checking Azure Resource Provider Registrations"

$null = Register-RequiredProviders

# =====================================================
# Summary
# =====================================================
Write-Host ""
Write-BoxBanner -Text "Pre-Provision Validation Passed" -Style Single -Width 50

Write-Section "Configuration Summary"
Write-KeyValue "Subscription"   "$(if ($subName) { $subName } else { $env:AZURE_SUBSCRIPTION_ID })"
Write-KeyValue "Location"       $env:AZURE_LOCATION
Write-KeyValue "Environment"    $env:AZURE_ENV_NAME
Write-KeyValue "System CPU"     $selectedSystem.Sku
Write-KeyValue "Workload CPU"   $selectedWorkload.Sku
Write-KeyValue "Deepstream GPU" "$DEEPSTREAM_GPU_VM_SIZE ($DEEPSTREAM_GPU_MAX_NODE_COUNT node(s))"
Write-KeyValue "Inference GPU"  "$INFERENCE_GPU_VM_SIZE ($INFERENCE_GPU_MAX_NODE_COUNT node(s))"
Write-KeyValue "Providers"      "all registered"
Write-KeyValue "Tools"          "all present"

Write-Host ""
Log-Success "Proceeding with provisioning..."
Write-Host ""
