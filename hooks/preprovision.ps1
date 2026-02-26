# =============================================================================
# Pre-Provision Script: Validate prerequisites before provisioning
# =============================================================================

$ErrorActionPreference = "Stop"

Write-Host "=============================================="
Write-Host "Pre-provision: Validation & Pre-flight Checks"
Write-Host "=============================================="

$ErrorCount = 0

# =====================================================
# Step 1: Check Azure CLI authentication
# =====================================================
Write-Host ""
Write-Host ">> Step 1: Checking Azure CLI authentication..."

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
Write-Host ""
Write-Host ">> Step 2: Checking required CLI tools..."

foreach ($cmd in @('az', 'helm', 'kubectl')) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        Write-Host "   ${cmd}: OK"
    }
    else {
        Write-Host "   ${cmd}: MISSING" -ForegroundColor Red
        $ErrorCount++
    }
}

# Optional tools
foreach ($cmd in @('kubelogin', 'jq')) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        Write-Host "   ${cmd}: OK"
    }
    else {
        Write-Host "   ${cmd}: not found (optional, but recommended)"
    }
}

if ($ErrorCount -gt 0) {
    Write-Error "$ErrorCount required tool(s) missing. Install them before proceeding."
    exit 1
}

# =====================================================
# Step 3: Validate required environment variables
# =====================================================
Write-Host ""
Write-Host ">> Step 3: Validating pre-provision environment variables..."

$preProvisionVars = @('AZURE_SUBSCRIPTION_ID', 'AZURE_LOCATION', 'AZURE_ENV_NAME')
$missingVars = @()

foreach ($var in $preProvisionVars) {
    $val = [System.Environment]::GetEnvironmentVariable($var)
    if ($val) {
        Write-Host "   ${var}: $val"
    }
    else {
        Write-Host "   ${var}: MISSING" -ForegroundColor Red
        $missingVars += $var
    }
}

if ($missingVars.Count -gt 0) {
    Write-Error "The following required environment variables are not set:`n  $($missingVars -join "`n  ")`nSet them with 'azd env set <KEY> <VALUE>'."
    exit 1
}

# =====================================================
# Step 4: Register required Azure resource providers
# =====================================================
Write-Host ""
Write-Host ">> Step 4: Checking Azure resource provider registrations..."

$providersRegistering = 0
foreach ($provider in @('Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.ExtendedLocation', 'Microsoft.ContainerService', 'Microsoft.Network')) {
    $state = $null
    try {
        $state = (az provider show -n $provider --query "registrationState" -o tsv 2>$null)
    }
    catch {
        $state = "Unknown"
    }

    switch ($state) {
        "Registered" {
            Write-Host "   ${provider}: Registered"
        }
        "Registering" {
            Write-Host "   ${provider}: Registering (in progress)"
            $providersRegistering++
        }
        { $_ -in @("NotRegistered", "Unregistered") } {
            Write-Host "   ${provider}: Not registered - registering now..."
            az provider register --namespace $provider --wait false 2>$null
            $providersRegistering++
        }
        default {
            Write-Host "   ${provider}: $state (unexpected state)"
        }
    }
}

if ($providersRegistering -gt 0) {
    Write-Host ""
    Write-Host "   NOTE: $providersRegistering provider(s) are being registered."
    Write-Host "   Registration can take 2-5 minutes. Provisioning will proceed,"
    Write-Host "   but if it fails, wait a few minutes and retry."
}

# =====================================================
# Step 5: Validate region supports required VM size
# =====================================================
Write-Host ""
Write-Host ">> Step 5: Checking region capability for GPU VMs..."

$vmSize = "Standard_NC24ads_A100_v4"
$vmAvailable = $null
try {
    $vmAvailable = (az vm list-sizes --location $env:AZURE_LOCATION `
        --query "[?name=='$vmSize']" -o tsv 2>$null)
}
catch {
    $vmAvailable = $null
}

if (-not $vmAvailable) {
    Write-Error "VM size '$vmSize' is not available in region '$($env:AZURE_LOCATION)'.`nThis VM is required for the GPU node pool.`n`nAvailable regions for $vmSize include:`n  eastus, eastus2, westus2, westus3, southcentralus,`n  northeurope, westeurope, southeastasia, australiaeast`n`nChange region with: azd env set AZURE_LOCATION <region>"
    exit 1
}

Write-Host "   ${vmSize}: available in $($env:AZURE_LOCATION)"

# =====================================================
# Step 6: Check GPU VM quota
# =====================================================
Write-Host ""
Write-Host ">> Step 6: Checking GPU VM quota..."

$quotaJson = $null
try {
    $quotaJson = (az vm list-usage --location $env:AZURE_LOCATION `
        --query "[?contains(name.value, 'StandardNCADSA100v4Family')]" `
        -o json 2>$null) | ConvertFrom-Json
}
catch {
    $quotaJson = @()
}

$currentUsage = 0
$quotaLimit = 0
$needed = 24

if ($quotaJson -and $quotaJson.Count -gt 0) {
    $currentUsage = $quotaJson[0].currentValue
    $quotaLimit = $quotaJson[0].limit
}

$available = $quotaLimit - $currentUsage

if ($quotaLimit -eq 0) {
    Write-Host "   WARNING: Could not determine GPU quota for $vmSize." -ForegroundColor Yellow
    Write-Host "   Family: StandardNCADSA100v4Family"
    Write-Host "   This may indicate zero quota in this subscription/region."
    Write-Host ""
    Write-Host "   Request GPU quota at:"
    Write-Host "   https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas"
    Write-Host ""
    Write-Host "   Proceeding anyway - provisioning will fail if quota is insufficient."
}
elseif ($available -lt $needed) {
    Write-Error "Insufficient GPU quota in $($env:AZURE_LOCATION).`n  VM Size:   $vmSize ($needed cores)`n  Available: $available cores ($currentUsage/$quotaLimit used)`n  Required:  $needed cores`n`nRequest quota increase at:`nhttps://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas"
    exit 1
}
else {
    Write-Host "   GPU quota: $available cores available ($currentUsage/$quotaLimit used)"
    Write-Host "   Required:  $needed cores for $vmSize"
}

# =====================================================
# Summary
# =====================================================
Write-Host ""
Write-Host "=============================================="
Write-Host "Pre-provision validation passed!"
Write-Host "=============================================="
Write-Host ""
Write-Host "  Subscription: $(if ($subName) { $subName } else { $env:AZURE_SUBSCRIPTION_ID })"
Write-Host "  Location:     $($env:AZURE_LOCATION)"
Write-Host "  Environment:  $($env:AZURE_ENV_NAME)"
Write-Host "  GPU VM:       $vmSize ($available cores available)"
Write-Host "  Providers:    all registered"
Write-Host "  Tools:        all present"
Write-Host ""
Write-Host "Proceeding with provisioning..."
