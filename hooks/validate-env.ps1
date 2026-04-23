# =============================================================================
# Pre-Up Validation: Validate environment variables before provisioning
# =============================================================================
# Runs as the azd 'preup' hook. Catches misconfigured env vars before Bicep
# starts (which saves time on expensive GPU provisioning failures).
# Pattern adapted from get-started-with-ai-agents/scripts/validate_env_vars.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

$hasError = $false

function Test-EnvVarFormat {
    param(
        [string]$VarName,
        [string]$Pattern,
        [string]$Example
    )
    $value = [Environment]::GetEnvironmentVariable($VarName)
    if ([string]::IsNullOrEmpty($value)) { return }  # Optional — skip if unset

    if ($value -notmatch $Pattern) {
        Write-Host "  [ERROR] Invalid value for '$VarName': '$value'" -ForegroundColor Red
        Write-Host "          Expected format: $Example" -ForegroundColor DarkGray
        $script:hasError = $true
    }
}

Write-Host ""
Write-Host "  Validating environment variables..." -ForegroundColor Cyan
Write-Host ""

# ── UUID format ──────────────────────────────────────────────────────────
$uuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
Test-EnvVarFormat -VarName "AZURE_SUBSCRIPTION_ID" -Pattern $uuidPattern -Example "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
Test-EnvVarFormat -VarName "AZURE_PRINCIPAL_ID" -Pattern $uuidPattern -Example "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# ── VM sizes must start with Standard_ ────────────────────────────────────
$vmPattern = '^Standard_[A-Za-z0-9_]+$'
Test-EnvVarFormat -VarName "SYSTEM_VM_SIZE" -Pattern $vmPattern -Example "Standard_D4a_v4"
Test-EnvVarFormat -VarName "WORKLOAD_VM_SIZE" -Pattern $vmPattern -Example "Standard_D32a_v4"
Test-EnvVarFormat -VarName "DEEPSTREAM_GPU_VM_SIZE" -Pattern $vmPattern -Example "Standard_NC24ads_A100_v4"
Test-EnvVarFormat -VarName "INFERENCE_GPU_VM_SIZE" -Pattern $vmPattern -Example "Standard_NC24ads_A100_v4"

# ── Boolean flags ──────────────────────────────────────────────────────────
$boolPattern = '^(true|false)$'
Test-EnvVarFormat -VarName "CREATE_FOUNDRY_PROJECT" -Pattern $boolPattern -Example "true or false"
Test-EnvVarFormat -VarName "CREATE_ROLE_FOR_USER" -Pattern $boolPattern -Example "true or false"
Test-EnvVarFormat -VarName "MEDIA_STREAMER_ENABLED" -Pattern $boolPattern -Example "true or false"

# ── Storage SKU ────────────────────────────────────────────────────────────
$skuPattern = '^Standard_(LRS|ZRS|GRS)$'
Test-EnvVarFormat -VarName "STORAGE_SKU_NAME" -Pattern $skuPattern -Example "Standard_LRS, Standard_ZRS, or Standard_GRS"

# ── Location must be non-empty if set ──────────────────────────────────────
$locationPattern = '^[a-z0-9]+(-[a-z0-9]+)*$'
Test-EnvVarFormat -VarName "AZURE_LOCATION" -Pattern $locationPattern -Example "eastus2"

if ($hasError) {
    Write-Host ""
    Write-Host "  [FAILED] Environment validation failed. Fix the values above before provisioning." -ForegroundColor Red
    Write-Host "           Use 'azd env set <VAR> <VALUE>' to correct them." -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

Write-Host "  [OK] Environment variables validated successfully." -ForegroundColor Green
Write-Host ""
