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
# Step 4: Select VM sizes for AKS node pools
#         (includes region availability + GPU quota checks)
# =====================================================
Write-Step "4" "Selecting VM sizes for AKS node pools..."

Write-Host "   Choose a VM SKU for each AKS node pool."
Write-Host "   The default is highlighted — press Enter to accept it."
Write-Host ""

# Determine current/default values (env var overrides config default)
$currentSystemVm     = if ($env:SYSTEM_VM_SIZE)          { $env:SYSTEM_VM_SIZE }          else { $DEFAULT_SYSTEM_VM_SIZE }
$currentWorkloadVm   = if ($env:WORKLOAD_VM_SIZE)        { $env:WORKLOAD_VM_SIZE }        else { $DEFAULT_WORKLOAD_VM_SIZE }
$currentDeepstreamVm = if ($env:DEEPSTREAM_GPU_VM_SIZE)  { $env:DEEPSTREAM_GPU_VM_SIZE }  else { $DEFAULT_DEEPSTREAM_GPU_SIZE }
$currentInferenceVm  = if ($env:INFERENCE_GPU_VM_SIZE)   { $env:INFERENCE_GPU_VM_SIZE }   else { $DEFAULT_INFERENCE_GPU_SIZE }

# CPU pools
$selectedSystem   = Show-VmSelectionMenu -PoolName "System (CPU)"   -EnvVarName "SYSTEM_VM_SIZE"   -Catalog $CPU_VM_CATALOG -DefaultSku $currentSystemVm   -Location $env:AZURE_LOCATION
$selectedWorkload = Show-VmSelectionMenu -PoolName "Workload (CPU)" -EnvVarName "WORKLOAD_VM_SIZE" -Catalog $CPU_VM_CATALOG -DefaultSku $currentWorkloadVm -Location $env:AZURE_LOCATION

# GPU pools (availability + quota validated inline, node count determines total cores checked)
$selectedDeepstream = Show-VmSelectionMenu -PoolName "Deepstream (GPU)" -EnvVarName "DEEPSTREAM_GPU_VM_SIZE" -Catalog $GPU_VM_CATALOG -DefaultSku $currentDeepstreamVm -Location $env:AZURE_LOCATION -IsGpu -MaxNodes $DEEPSTREAM_GPU_MAX_NODE_COUNT
$selectedInference  = Show-VmSelectionMenu -PoolName "Inference (GPU)"  -EnvVarName "INFERENCE_GPU_VM_SIZE"  -Catalog $GPU_VM_CATALOG -DefaultSku $currentInferenceVm  -Location $env:AZURE_LOCATION -IsGpu -MaxNodes $INFERENCE_GPU_MAX_NODE_COUNT

# Update script-scope variables for downstream consumers
$DEEPSTREAM_GPU_VM_SIZE = $selectedDeepstream.Sku
$INFERENCE_GPU_VM_SIZE  = $selectedInference.Sku

# =====================================================
# Step 5: Register required Azure resource providers
# =====================================================
Write-Step "5" "Checking Azure resource provider registrations..."

$null = Register-RequiredProviders

# =====================================================
# Summary
# =====================================================
Write-Host ""
Write-Banner "Pre-provision validation passed!"
Write-Host ""
Write-Host "  Subscription:    $(if ($subName) { $subName } else { $env:AZURE_SUBSCRIPTION_ID })"
Write-Host "  Location:        $($env:AZURE_LOCATION)"
Write-Host "  Environment:     $($env:AZURE_ENV_NAME)"
Write-Host "  System CPU:      $($selectedSystem.Sku)"
Write-Host "  Workload CPU:    $($selectedWorkload.Sku)"
Write-Host "  Deepstream GPU:  $DEEPSTREAM_GPU_VM_SIZE ($DEEPSTREAM_GPU_MAX_NODE_COUNT node(s))"
Write-Host "  Inference GPU:   $INFERENCE_GPU_VM_SIZE ($INFERENCE_GPU_MAX_NODE_COUNT node(s))"
Write-Host "  Providers:       all registered"
Write-Host "  Tools:           all present"
Write-Host ""
Write-Host "Proceeding with provisioning..."
