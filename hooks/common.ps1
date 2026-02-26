# =============================================================================
# Shared Utilities: Common functions used across all PowerShell hooks
# =============================================================================
# Source this file via: . "$PSScriptRoot/common.ps1"
# This file automatically loads config.ps1.

. "$PSScriptRoot/config.ps1"

# ── Output Helpers ───────────────────────────────────────────────────────────

function Write-Banner {
    param([string]$Title)
    Write-Host "=============================================="
    Write-Host $Title
    Write-Host "=============================================="
}

function Write-Step {
    param([string]$StepNumber, [string]$Message)
    Write-Host ""
    Write-Host ">> Step ${StepNumber}: ${Message}"
}

# ── Prerequisite Checks ─────────────────────────────────────────────────────

function Assert-EnvVars {
    param([string[]]$Required)
    $missing = $Required | Where-Object { -not (Get-Item "env:$_" -ErrorAction SilentlyContinue) }
    if ($missing) {
        Write-Error "The following required environment variables are not set:`n  $($missing -join "`n  ")`nRun 'azd env get-values' to check your environment."
        exit 1
    }
}

function Assert-CliTools {
    param(
        [string[]]$Required = @('az', 'helm', 'kubectl'),
        [string[]]$Optional = @()
    )
    $errorCount = 0
    foreach ($cmd in $Required) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            Write-Host "   ${cmd}: OK"
        }
        else {
            Write-Host "   ${cmd}: MISSING" -ForegroundColor Red
            $errorCount++
        }
    }
    foreach ($cmd in $Optional) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            Write-Host "   ${cmd}: OK"
        }
        else {
            Write-Host "   ${cmd}: not found (optional, but recommended)"
        }
    }
    if ($errorCount -gt 0) {
        Write-Error "$errorCount required tool(s) missing. Install them before proceeding."
        exit 1
    }
}

# ── Azure Providers ─────────────────────────────────────────────────────────

function Register-RequiredProviders {
    param([string[]]$Providers = $Script:REQUIRED_PROVIDERS)
    $providersRegistering = 0
    foreach ($provider in $Providers) {
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

    return $providersRegistering
}

# ── AKS Credentials ────────────────────────────────────────────────────────

function Connect-AksCluster {
    <#
    .SYNOPSIS
        Fetches AKS admin credentials and returns the kubectl context name.
    .OUTPUTS
        [string] The kubectl context name (e.g. "mycluster-admin"), or $null on failure.
    #>
    param(
        [string]$ResourceGroup = $env:AZURE_RESOURCE_GROUP,
        [string]$ClusterName   = $env:AZURE_AKS_CLUSTER_NAME
    )

    az aks get-credentials `
        --resource-group "$ResourceGroup" `
        --name "$ClusterName" `
        --admin `
        --overwrite-existing 2>$null | Out-Null

    return "${ClusterName}-admin"
}

# ── Kubernetes Helpers ──────────────────────────────────────────────────────

function Get-RunningPodCount {
    <#
    .SYNOPSIS
        Returns the number of Running pods in a given namespace.
    #>
    param(
        [string]$Namespace,
        [string]$KubeContext
    )
    try {
        $count = (kubectl --context $KubeContext get pods -n $Namespace `
            --field-selector=status.phase=Running --no-headers 2>$null | Measure-Object -Line).Lines
        return [int]$count
    }
    catch {
        return 0
    }
}

function Get-TotalPodCount {
    <#
    .SYNOPSIS
        Returns the total number of pods in a given namespace.
    #>
    param(
        [string]$Namespace,
        [string]$KubeContext
    )
    try {
        $count = (kubectl --context $KubeContext get pods -n $Namespace `
            --no-headers 2>$null | Measure-Object -Line).Lines
        return [int]$count
    }
    catch {
        return 0
    }
}

function Test-NamespaceExists {
    <#
    .SYNOPSIS
        Returns $true if the given namespace exists in the cluster.
    #>
    param(
        [string]$Namespace,
        [string]$KubeContext
    )
    try {
        $result = kubectl --context $KubeContext get namespace $Namespace --no-headers 2>$null
        return [bool]$result
    }
    catch {
        return $false
    }
}
