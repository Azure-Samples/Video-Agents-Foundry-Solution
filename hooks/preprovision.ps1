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
    Log-Success "ID: $env:AZURE_SUBSCRIPTION_ID"
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
Write-KeyValue "CREATE_IN_LOCAL" $(if ($env:CREATE_IN_LOCAL) { $env:CREATE_IN_LOCAL } else { "(unset)" })
Write-KeyValue "Mode" $(if ($INTERACTIVE) { "interactive" } else { "non-interactive" })
# Use the shared assertion for the actual error check
Assert-EnvVars $preProvisionVars

# Validate STORAGE_SKU_NAME against region capabilities if ZRS is requested
$storageSku = if ($env:STORAGE_SKU_NAME) { $env:STORAGE_SKU_NAME } else { 'Standard_LRS' }
if ($storageSku -eq 'Standard_ZRS') {
    Log-Info "Checking ZRS availability in $($env:AZURE_LOCATION)..."
    $zrsAvailable = $false
    try {
        $skuInfo = (az storage account list-skus --location $env:AZURE_LOCATION `
                --query "[?name=='Standard_ZRS'].name | [0]" `
                -o tsv 2>$null)
        if (-not [string]::IsNullOrWhiteSpace($skuInfo)) { $zrsAvailable = $true }
    }
    catch { $zrsAvailable = $false }
    if (-not $zrsAvailable) {
        Log-Warning "Requested Standard_ZRS is not available in '$($env:AZURE_LOCATION)'."
        Log-Warning "Falling back to Standard_LRS to avoid deployment failure."
        azd env set STORAGE_SKU_NAME Standard_LRS 2>$null
        $storageSku = 'Standard_LRS'
    }
    else {
        Log-Success "ZRS is available in $($env:AZURE_LOCATION)"
    }
}
Write-KeyValue "STORAGE_SKU" $storageSku

# ── Validate Kubernetes version against region capabilities ──────────────
# Pin minors drift from standard support to LTS-only (e.g. 1.32 → LTS).
# If the requested minor is not available on the standard "KubernetesOfficial"
# support plan in this region, auto-fall back to the region's default minor.
$requestedK8s = if ($env:KUBERNETES_VERSION) { $env:KUBERNETES_VERSION } else { '1.34' }
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
    Write-KeyValue "KUBERNETES_VERSION" $requestedK8s
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
        Write-KeyValue "CREATE_FOUNDRY_PROJECT" $resolvedFoundry
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

$cpuCount = @($allVmSizes | Where-Object { $n = $_.Name; ($CPU_VM_PREFIXES | Where-Object { $n.StartsWith($_) }).Count -gt 0 }).Count
$gpuCount = @($allVmSizes | Where-Object { $n = $_.Name; ($GPU_VM_PREFIXES | Where-Object { $n.StartsWith($_) }).Count -gt 0 }).Count
Log-Success "Found VM SKUs in $($env:AZURE_LOCATION)"
Log-Info "$cpuCount CPU + $gpuCount GPU sizes available"

if ($cpuCount -eq 0 -and $gpuCount -eq 0) {
    Log-Error "No VM sizes are available in '$($env:AZURE_LOCATION)' for this subscription."
    Log-Info "This usually means the region has restrictive SKU policies for your subscription."
    Log-Info "Try a different region: run 'azd env set AZURE_LOCATION <region>' and re-run 'azd up'."
    Log-Info "Recommended regions: eastus2, westus3, southcentralus, northeurope"
    exit 1
}

if ($cpuCount -eq 0) {
    Log-Error "No CPU VM sizes (D/E/F-series) are available in '$($env:AZURE_LOCATION)'."
    Log-Info "AKS requires CPU nodes for system and workload pools."
    Log-Info "Try a different region: run 'azd env set AZURE_LOCATION <region>' and re-run 'azd up'."
    Log-Info "Recommended regions: eastus2, westus3, southcentralus, northeurope"
    exit 1
}

if ($gpuCount -eq 0) {
    Log-Warning "No GPU VM sizes (NC/NV/ND-series) are available in '$($env:AZURE_LOCATION)'."
    Log-Info "GPU pools are required for video processing. Consider a region with GPU support."
    Log-Info "Try: run 'azd env set AZURE_LOCATION <region>' and re-run 'azd up'."
    Log-Info "Recommended GPU regions: eastus2, westus3, southcentralus, northeurope"
    exit 1
}

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

# Resolve defaults — in interactive mode, pick closest available if default unavailable.
# In non-interactive mode, skip fallback — validation will fail hard if SKU doesn't exist.
if ($INTERACTIVE) {
    $currentSystemVm     = Resolve-DefaultSku -DefaultSku $currentSystemVm     -AvailableSizes $systemVmSizes     -PreferCores 4
    $currentWorkloadVm   = Resolve-DefaultSku -DefaultSku $currentWorkloadVm   -AvailableSizes $workloadVmSizes   -PreferCores 32
    $currentDeepstreamVm = Resolve-DefaultSku -DefaultSku $currentDeepstreamVm -AvailableSizes $deepstreamVmSizes -PreferCores 6
    $currentInferenceVm  = Resolve-DefaultSku -DefaultSku $currentInferenceVm  -AvailableSizes $inferenceVmSizes  -PreferCores 40
}

Write-KeyValue "System pool"     "$($systemVmSizes.Count) sizes (with quota)"
Write-KeyValue "Workload pool"   "$($workloadVmSizes.Count) sizes (with quota)"
Write-KeyValue "Deepstream pool" "$($deepstreamVmSizes.Count) sizes (with quota)"
Write-KeyValue "Inference pool"  "$($inferenceVmSizes.Count) sizes (with quota)"

if ($INTERACTIVE) {
    Write-Section "Choose a VM SKU for each AKS node pool"
    Log-Info "The default is highlighted. Press Enter to accept, C for custom."

    # CPU pools (quota-filtered lists, node count determines total cores checked)
    $selectedSystem   = Show-VmSelectionMenu -PoolName "System (CPU)"   -EnvVarName "SYSTEM_VM_SIZE"   -VmSizes $systemVmSizes   -DefaultSku $currentSystemVm   -Location $env:AZURE_LOCATION -MaxNodes $SYSTEM_MAX_NODE_COUNT   -QuotaData $quotaData
    $selectedWorkload = Show-VmSelectionMenu -PoolName "Workload (CPU)" -EnvVarName "WORKLOAD_VM_SIZE" -VmSizes $workloadVmSizes -DefaultSku $currentWorkloadVm -Location $env:AZURE_LOCATION -MaxNodes $WORKLOAD_MAX_NODE_COUNT -QuotaData $quotaData

    # GPU pools (quota validated inline, node count determines total cores checked)
    $selectedDeepstream = Show-VmSelectionMenu -PoolName "Deepstream (GPU)" -EnvVarName "DEEPSTREAM_GPU_VM_SIZE" -VmSizes $deepstreamVmSizes -DefaultSku $currentDeepstreamVm -Location $env:AZURE_LOCATION -IsGpu -MaxNodes $DEEPSTREAM_GPU_MAX_NODE_COUNT -QuotaData $quotaData
    $selectedInference  = Show-VmSelectionMenu -PoolName "Inference (GPU)"  -EnvVarName "INFERENCE_GPU_VM_SIZE"  -VmSizes $inferenceVmSizes  -DefaultSku $currentInferenceVm  -Location $env:AZURE_LOCATION -IsGpu -MaxNodes $INFERENCE_GPU_MAX_NODE_COUNT  -QuotaData $quotaData
}
else {
    # Non-interactive: validate configured SKUs exist and have quota, fail if not.
    Log-Info "Non-interactive mode (CREATE_IN_LOCAL=false). Validating configured VM sizes."

    # Validate each configured SKU exists in region
    $vmChecks = @(
        @{ Label = 'System CPU';     Sku = $currentSystemVm;     Pool = $allVmSizes; EnvVar = 'SYSTEM_VM_SIZE';            MaxNodes = $SYSTEM_MAX_NODE_COUNT }
        @{ Label = 'Workload CPU';   Sku = $currentWorkloadVm;   Pool = $allVmSizes; EnvVar = 'WORKLOAD_VM_SIZE';          MaxNodes = $WORKLOAD_MAX_NODE_COUNT }
        @{ Label = 'Deepstream GPU'; Sku = $currentDeepstreamVm; Pool = $allVmSizes; EnvVar = 'DEEPSTREAM_GPU_VM_SIZE';    MaxNodes = $DEEPSTREAM_GPU_MAX_NODE_COUNT; IsGpu = $true }
        @{ Label = 'Inference GPU';  Sku = $currentInferenceVm;  Pool = $allVmSizes; EnvVar = 'INFERENCE_GPU_VM_SIZE';     MaxNodes = $INFERENCE_GPU_MAX_NODE_COUNT;  IsGpu = $true }
    )

    $errors = @()
    foreach ($check in $vmChecks) {
        $match = $check.Pool | Where-Object { $_.Name -eq $check.Sku } | Select-Object -First 1
        if (-not $match) {
            $errors += "'$($check.Sku)' ($($check.Label)) is not available in region '$($env:AZURE_LOCATION)'. Set $($check.EnvVar) to a valid SKU."
            continue
        }
        Write-KeyValue $check.Label "$($check.Sku) ($($match.Cores) vCPUs)"

        # Quota check — use GPU_QUOTA_FAMILY_MAP for GPU SKUs, SKU family field for CPU
        $family = $null
        if ($check.IsGpu) {
            $family = Get-QuotaFamilyForVm -VmSize $check.Sku
        }
        elseif ($match.Family) {
            $family = $match.Family
        }

        if (-not $family) {
            if ($check.IsGpu) {
                $errors += "'$($check.Sku)' ($($check.Label)): could not resolve quota family. Cannot verify quota in non-interactive mode."
            }
            # CPU without family: skip quota check (non-critical)
            continue
        }

        if ($quotaData.Count -eq 0 -or -not $quotaData.ContainsKey($family)) {
            if ($check.IsGpu) {
                $errors += "'$($check.Sku)' ($($check.Label)): quota data unavailable for '$family'. Cannot verify quota in non-interactive mode."
            }
            else {
                Log-Warning "'$($check.Sku)' ($($check.Label)): quota data unavailable for '$family'. Skipping CPU quota check."
            }
            continue
        }

        $needed = $match.Cores * $check.MaxNodes
        if ($quotaData[$family].Available -lt $needed) {
            $errors += "'$($check.Sku)' ($($check.Label)): insufficient quota for '$family' — need $needed cores, have $($quotaData[$family].Available). Request quota at: $QUOTA_URL"
        }
        else {
            $quotaData[$family].Available -= $needed
        }
    }

    if ($errors.Count -gt 0) {
        foreach ($err in $errors) { Log-Error $err }
        exit 1
    }

    $selectedSystem     = @{ Sku = $currentSystemVm;     Cores = 0; Family = $null }
    $selectedWorkload   = @{ Sku = $currentWorkloadVm;   Cores = 0; Family = $null }
    $selectedDeepstream = @{ Sku = $currentDeepstreamVm; Cores = 0; Family = $null }
    $selectedInference  = @{ Sku = $currentInferenceVm;  Cores = 0; Family = $null }

    # Persist to azd env
    foreach ($pair in @(@('SYSTEM_VM_SIZE', $currentSystemVm), @('WORKLOAD_VM_SIZE', $currentWorkloadVm), @('DEEPSTREAM_GPU_VM_SIZE', $currentDeepstreamVm), @('INFERENCE_GPU_VM_SIZE', $currentInferenceVm))) {
        try { azd env set $pair[0] $pair[1] 2>$null } catch {}
    }
}

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
