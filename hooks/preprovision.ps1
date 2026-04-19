# =============================================================================
# Pre-Provision Script: Validate prerequisites before provisioning
# =============================================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/common.ps1"

$totalSteps = 6

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
    Log-Success "ID" $env:AZURE_SUBSCRIPTION_ID
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

# Validate STORAGE_SKU_NAME against region capabilities if ZRS is requested
$storageSku = if ($env:STORAGE_SKU_NAME) { $env:STORAGE_SKU_NAME } else { 'Standard_LRS' }
if ($storageSku -eq 'Standard_ZRS') {
    Log-Info "Checking ZRS availability in $($env:AZURE_LOCATION)..."
    $zrsAvailable = $false
    try {
        $skuInfo = (az provider show --namespace Microsoft.Storage `
                --query "resourceTypes[?resourceType=='storageAccounts'].zoneMappings[?contains(location, '$($env:AZURE_LOCATION)')].location | [0][0]" `
                -o tsv 2>$null)
        if ($skuInfo) { $zrsAvailable = $true }
    }
    catch { }
    if (-not $zrsAvailable) {
        Log-Warning "Standard_ZRS may not be available in '$($env:AZURE_LOCATION)'."
        Log-Warning "Falling back to Standard_LRS to avoid deployment failure."
        azd env set STORAGE_SKU_NAME Standard_LRS 2>$null
        $storageSku = 'Standard_LRS'
    }
    else {
        Log-Success "ZRS is available in $($env:AZURE_LOCATION)"
    }
}
Write-KeyValue "Storage SKU" $storageSku

# ── Validate Kubernetes version against region capabilities ──────────────
# Pin minors drift from standard support to LTS-only (e.g. 1.32 → LTS).
# If the requested minor is not available on the standard "KubernetesOfficial"
# support plan in this region, auto-fall back to the region's default minor.
$requestedK8s = if ($env:KUBERNETES_VERSION) { $env:KUBERNETES_VERSION } else { '1.34' }
Log-Info "Checking AKS version '$requestedK8s' in $($env:AZURE_LOCATION)..."
$versions = Invoke-AzJson { az aks get-versions --location $env:AZURE_LOCATION -o json }
if ($versions -and $versions.values) {
    $standardVersions = @($versions.values | Where-Object {
            $_.capabilities.supportPlan -contains 'KubernetesOfficial'
        } | ForEach-Object { $_.version })
    $defaultVersion = ($versions.values | Where-Object { $_.isDefault } | Select-Object -First 1).version
    if ($standardVersions -notcontains $requestedK8s) {
        if ($defaultVersion) {
            Log-Warning "Kubernetes '$requestedK8s' is not on standard support in '$($env:AZURE_LOCATION)'."
            Log-Warning "Falling back to region default: '$defaultVersion'."
            [void](Invoke-AzdEnvSet -Name 'KUBERNETES_VERSION' -Value $defaultVersion)
            $env:KUBERNETES_VERSION = $defaultVersion
            $requestedK8s = $defaultVersion
        }
        else {
            Log-Warning "Kubernetes '$requestedK8s' is not on standard support and no default could be resolved."
        }
    }
    Write-KeyValue "Kubernetes version" $requestedK8s
}
else {
    Log-Warning "Could not query AKS versions in '$($env:AZURE_LOCATION)'. Proceeding with '$requestedK8s'."
}

# Persist the resolved CREATE_FOUNDRY_PROJECT value so Bicep + all downstream
# hooks agree on the same boolean. (Bicep's default is true; the hooks default
# to true to match. Without this step, a step that reads $env:... raw would
# see the empty string and take the 'false' branch.)
$resolvedFoundry = if ($CREATE_FOUNDRY_PROJECT) { 'true' } else { 'false' }
if ($env:CREATE_FOUNDRY_PROJECT -ne $resolvedFoundry) {
    try {
        azd env set CREATE_FOUNDRY_PROJECT $resolvedFoundry 2>$null
        $env:CREATE_FOUNDRY_PROJECT = $resolvedFoundry
        Log-Info "CREATE_FOUNDRY_PROJECT resolved to '$resolvedFoundry' (persisted to azd env)."
    }
    catch {
        Log-Warning "Could not persist CREATE_FOUNDRY_PROJECT via 'azd env set'."
    }
}

# =====================================================
# Step 4: Resolve AI Model Quota (if Foundry enabled)
# =====================================================
Log-Step -Number 4 -Total $totalSteps -Title "Checking AI Model Quota"

if ($env:CREATE_FOUNDRY_PROJECT -eq 'false') {
    Log-Info "AI Foundry disabled (CREATE_FOUNDRY_PROJECT=false). Skipping model quota check."
}
else {
    $modelName     = if ($env:AI_MODEL_NAME)     { $env:AI_MODEL_NAME }     else { $DEFAULT_AI_MODEL_NAME }
    $modelCapacity = if ($env:AI_MODEL_CAPACITY)  { [int]$env:AI_MODEL_CAPACITY } else { 1 }

    Resolve-ModelQuota -Location $env:AZURE_LOCATION `
        -Model $modelName `
        -Capacity $modelCapacity
}

# =====================================================
# Step 5: Select VM sizes for AKS node pools
#         (includes region availability + GPU quota checks)
# =====================================================
Log-Step -Number 5 -Total $totalSteps -Title "Selecting VM Sizes for AKS Node Pools"

Log-Info "Querying available VM SKUs in $($env:AZURE_LOCATION)..."
$allVmSizes = Get-AzVmSizesForRegion -Location $env:AZURE_LOCATION

if ($allVmSizes.Count -eq 0) {
    Log-Error "Could not retrieve VM sizes for region '$($env:AZURE_LOCATION)'."
    exit 1
}

Log-Success "Found $($allVmSizes.Count) VM sizes in $($env:AZURE_LOCATION)"

# Determine current/default values (env var overrides config default)
$currentSystemVm     = if ($env:SYSTEM_VM_SIZE)          { $env:SYSTEM_VM_SIZE }          else { $DEFAULT_SYSTEM_VM_SIZE }
$currentWorkloadVm   = if ($env:WORKLOAD_VM_SIZE)        { $env:WORKLOAD_VM_SIZE }        else { $DEFAULT_WORKLOAD_VM_SIZE }
$currentDeepstreamVm = if ($env:DEEPSTREAM_GPU_VM_SIZE)  { $env:DEEPSTREAM_GPU_VM_SIZE }  else { $DEFAULT_DEEPSTREAM_GPU_SIZE }
$currentInferenceVm  = if ($env:INFERENCE_GPU_VM_SIZE)   { $env:INFERENCE_GPU_VM_SIZE }   else { $DEFAULT_INFERENCE_GPU_SIZE }

Log-Info "Querying VM quota in region..."
$quotaData = Get-AzVmQuotaForRegion -Location $env:AZURE_LOCATION
if ($quotaData -and $quotaData.Keys.Count -gt 0) {
    Log-Success "Quota data retrieved for $($quotaData.Keys.Count) VM families"
}
else {
    Log-Warning "Could not retrieve VM quota data for '$($env:AZURE_LOCATION)'. Menus will show all SKUs without quota filtering."
    $quotaData = @{}
}

# Pick recommended VM sizes per pool (4 families x 3 sizes = ~12 items each).
# QuotaData filters out SKUs whose family can't satisfy the pool's max node count.
$systemVmSizes   = Select-VmSizesForMenu -AllSizes $allVmSizes -Prefixes $CPU_VM_PREFIXES -RecommendedFamilies $SYSTEM_RECOMMENDED_FAMILIES   -DefaultSku $currentSystemVm     -SizesPerFamily $SIZES_PER_FAMILY -MaxCores $SYSTEM_MAX_CORES   -QuotaData $quotaData -MaxNodes $SYSTEM_MAX_NODE_COUNT
$workloadVmSizes = Select-VmSizesForMenu -AllSizes $allVmSizes -Prefixes $CPU_VM_PREFIXES -RecommendedFamilies $WORKLOAD_RECOMMENDED_FAMILIES -DefaultSku $currentWorkloadVm   -SizesPerFamily $SIZES_PER_FAMILY -MinCores $WORKLOAD_MIN_CORES -QuotaData $quotaData -MaxNodes $WORKLOAD_MAX_NODE_COUNT
$deepstreamVmSizes = Select-VmSizesForMenu -AllSizes $allVmSizes -Prefixes $GPU_VM_PREFIXES -RecommendedFamilies $GPU_RECOMMENDED_FAMILIES    -DefaultSku $currentDeepstreamVm -SizesPerFamily $SIZES_PER_FAMILY                              -QuotaData $quotaData -MaxNodes $DEEPSTREAM_GPU_MAX_NODE_COUNT
$inferenceVmSizes  = Select-VmSizesForMenu -AllSizes $allVmSizes -Prefixes $GPU_VM_PREFIXES -RecommendedFamilies $GPU_RECOMMENDED_FAMILIES    -DefaultSku $currentInferenceVm  -SizesPerFamily $SIZES_PER_FAMILY                              -QuotaData $quotaData -MaxNodes $INFERENCE_GPU_MAX_NODE_COUNT

# Resolve defaults — if the configured default isn't available, pick the closest match
$currentSystemVm     = Resolve-DefaultSku -DefaultSku $currentSystemVm     -AvailableSizes $systemVmSizes     -PreferCores 4
$currentWorkloadVm   = Resolve-DefaultSku -DefaultSku $currentWorkloadVm   -AvailableSizes $workloadVmSizes   -PreferCores 32
$currentDeepstreamVm = Resolve-DefaultSku -DefaultSku $currentDeepstreamVm -AvailableSizes $deepstreamVmSizes -PreferCores 24
$currentInferenceVm  = Resolve-DefaultSku -DefaultSku $currentInferenceVm  -AvailableSizes $inferenceVmSizes  -PreferCores 24

Write-KeyValue "System pool"     "$($systemVmSizes.Count) sizes (with quota)"
Write-KeyValue "Workload pool"   "$($workloadVmSizes.Count) sizes (with quota)"
Write-KeyValue "Deepstream pool" "$($deepstreamVmSizes.Count) sizes (with quota)"
Write-KeyValue "Inference pool"  "$($inferenceVmSizes.Count) sizes (with quota)"

Write-Section "Choose a VM SKU for each AKS node pool"
Log-Info "The default is highlighted. Press Enter to accept, C for custom."

# CPU pools (quota-filtered lists, node count determines total cores checked)
$selectedSystem   = Show-VmSelectionMenu -PoolName "System (CPU)"   -EnvVarName "SYSTEM_VM_SIZE"   -VmSizes $systemVmSizes   -DefaultSku $currentSystemVm   -Location $env:AZURE_LOCATION -MaxNodes $SYSTEM_MAX_NODE_COUNT   -QuotaData $quotaData
$selectedWorkload = Show-VmSelectionMenu -PoolName "Workload (CPU)" -EnvVarName "WORKLOAD_VM_SIZE" -VmSizes $workloadVmSizes -DefaultSku $currentWorkloadVm -Location $env:AZURE_LOCATION -MaxNodes $WORKLOAD_MAX_NODE_COUNT -QuotaData $quotaData

# GPU pools (quota validated inline, node count determines total cores checked)
$selectedDeepstream = Show-VmSelectionMenu -PoolName "Deepstream (GPU)" -EnvVarName "DEEPSTREAM_GPU_VM_SIZE" -VmSizes $deepstreamVmSizes -DefaultSku $currentDeepstreamVm -Location $env:AZURE_LOCATION -IsGpu -MaxNodes $DEEPSTREAM_GPU_MAX_NODE_COUNT -QuotaData $quotaData
$selectedInference  = Show-VmSelectionMenu -PoolName "Inference (GPU)"  -EnvVarName "INFERENCE_GPU_VM_SIZE"  -VmSizes $inferenceVmSizes  -DefaultSku $currentInferenceVm  -Location $env:AZURE_LOCATION -IsGpu -MaxNodes $INFERENCE_GPU_MAX_NODE_COUNT  -QuotaData $quotaData

# Update script-scope variables for downstream consumers
$DEEPSTREAM_GPU_VM_SIZE = $selectedDeepstream.Sku
$INFERENCE_GPU_VM_SIZE  = $selectedInference.Sku

# =====================================================
# Step 6: Register required Azure resource providers
# =====================================================
Log-Step -Number 6 -Total $totalSteps -Title "Checking Azure Resource Provider Registrations"

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
if ($env:CREATE_FOUNDRY_PROJECT -ne 'false') {
    Write-KeyValue "AI Model"       "$modelName (capacity: $modelCapacity)"
}
Write-KeyValue "Providers"      "all registered"
Write-KeyValue "Tools"          "all present"

Write-Host ""
Log-Success "Proceeding with provisioning..."
Write-Host ""
