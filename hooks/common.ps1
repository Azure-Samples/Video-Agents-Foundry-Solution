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

# ── VM Size Availability ──────────────────────────────────────────────────

function Test-VmAvailability {
    <#
    .SYNOPSIS
        Checks if a VM size is available in the given Azure region.
    .OUTPUTS
        Hashtable with keys: Available (bool), Cores (int or $null)
    #>
    param(
        [string]$VmSize,
        [string]$Location
    )
    try {
        $vmInfo = (az vm list-sizes --location $Location `
                --query "[?name=='$VmSize'] | [0]" -o json 2>$null) | ConvertFrom-Json
        if ($vmInfo) {
            return @{ Available = $true; Cores = [int]$vmInfo.numberOfCores }
        }
    }
    catch { }
    return @{ Available = $false; Cores = $null }
}

function Test-VmQuota {
    <#
    .SYNOPSIS
        Checks GPU quota for a given family in a region.
    .OUTPUTS
        Hashtable with keys: Limit (int), CurrentUsage (int), Available (int)
        Returns $null on error.
    #>
    param(
        [string]$Family,
        [string]$Location
    )
    if (-not $Family) { return $null }
    try {
        $raw = (az vm list-usage --location $Location `
                --query "[?name.value=='$Family'] | [0]" `
                -o json 2>$null)
        if ($raw -and $raw -ne "null") {
            $q = $raw | ConvertFrom-Json
            if ($q) {
                return @{
                    Limit        = [int]$q.limit
                    CurrentUsage = [int]$q.currentValue
                    Available    = [int]$q.limit - [int]$q.currentValue
                }
            }
        }
    }
    catch { }
    return $null
}

function Assert-VmQuota {
    <#
    .SYNOPSIS
        Checks GPU quota for a pool, prints a formatted status line, and returns
        a result string: "ok", "zero", "low", or "error".
        Caller decides whether to block or prompt.
    .PARAMETER Label
        Display label, e.g. "Deepstream" or "Deepstream (GPU)".
    .PARAMETER Family
        Quota family name.  If empty/null the check is skipped and "skip" is returned.
    .PARAMETER Location
        Azure region.
    .PARAMETER CoresNeeded
        Total cores the caller expects to consume (CoresPerVm * MaxNodes).
    #>
    param(
        [string]$Label,
        [string]$Family,
        [string]$Location,
        [int]$CoresNeeded
    )

    if (-not $Family) {
        Write-Host "   [$Label] Skipping quota check (no quota family)" -ForegroundColor Yellow
        return "skip"
    }

    Write-Host "   [$Label] Checking quota for '$Family'..." -NoNewline
    $quota = Test-VmQuota -Family $Family -Location $Location

    if ($null -eq $quota) {
        Write-Host " UNKNOWN (query failed)" -ForegroundColor Yellow
        return "error"
    }

    if ($quota.Limit -eq 0) {
        Write-Host " ZERO QUOTA" -ForegroundColor Red
        Write-Host "   [$Label] No quota allocated for '$Family' in '$Location'." -ForegroundColor Red
        Write-Host "   Request GPU quota at: $QUOTA_URL"
        Write-Host "   For step-by-step instructions, see: $GPU_QUOTA_DOC_URL"
        return "zero"
    }

    if ($CoresNeeded -gt 0 -and $quota.Available -lt $CoresNeeded) {
        Write-Host " LOW ($($quota.Available) cores free, need $CoresNeeded)" -ForegroundColor Yellow
        Write-Host "   [$Label] Insufficient quota — $($quota.Available)/$($quota.Limit) available ($($quota.CurrentUsage) used)" -ForegroundColor Yellow
        Write-Host "   Request quota increase at: $QUOTA_URL"
        Write-Host "   For step-by-step instructions, see: $GPU_QUOTA_DOC_URL"
        return "low"
    }

    Write-Host " OK ($($quota.Available) cores free)" -ForegroundColor Green
    return "ok"
}

# ── Interactive VM Selection Menu ─────────────────────────────────────────

function Show-VmSelectionMenu {
    <#
    .SYNOPSIS
        Arrow-key driven interactive menu for selecting a VM size.
        Up/Down to move, Enter to select, C for custom, Esc to cancel/re-draw.
        Validates availability in the target region and persists via azd env set.
    .OUTPUTS
        Hashtable with keys: Sku, Cores, Family (Family is $null for CPU VMs)
    #>
    param(
        [string]$PoolName,
        [string]$EnvVarName,
        [array]$Catalog,
        [string]$DefaultSku,
        [string]$Location,
        [switch]$IsGpu,
        [int]$MaxNodes = 1
    )

    $itemCount = $Catalog.Count + 1  # catalog entries + "Custom" row
    $bufWidth  = [Console]::BufferWidth

    # Find the default index
    $currentIndex = 0
    for ($i = 0; $i -lt $Catalog.Count; $i++) {
        if ($Catalog[$i].Sku -eq $DefaultSku) {
            $currentIndex = $i
            break
        }
    }

    # ── Write one padded, coloured line without scrolling ──────────
    # Uses [Console] methods exclusively so the cursor stays put.
    function Write-MenuLine {
        param([int]$Row, [string]$Text, [ConsoleColor]$Fg, [ConsoleColor]$Bg)
        [Console]::SetCursorPosition(0, $Row)
        $padded = $Text.PadRight($bufWidth - 1)    # clear stale chars
        $oldFg = [Console]::ForegroundColor
        $oldBg = [Console]::BackgroundColor
        [Console]::ForegroundColor = $Fg
        [Console]::BackgroundColor = $Bg
        [Console]::Write($padded)
        [Console]::ForegroundColor = $oldFg
        [Console]::BackgroundColor = $oldBg
    }

    # ── Build the display text for one catalog row ─────────────────
    function Format-VmText {
        param([hashtable]$Entry, [bool]$IsGpuPool, [bool]$IsDefault)
        $sku   = $Entry.Sku.PadRight(30)
        $cores = "$($Entry.Cores) cores".PadRight(10)
        $ram   = "$($Entry.RAM)".PadRight(8)
        $tag   = if ($IsDefault) { " (default)" } else { "" }
        if ($IsGpuPool) {
            $gpu = "$($Entry.GPU)".PadRight(16)
            return "${sku} ${cores} ${ram} ${gpu} $($Entry.Desc)${tag}"
        }
        return "${sku} ${cores} ${ram} $($Entry.Desc)${tag}"
    }

    # ── Redraw every row in-place ──────────────────────────────────
    function Render-Menu {
        param([int]$Sel, [int]$Top)
        $defFg = [Console]::ForegroundColor
        $defBg = [Console]::BackgroundColor

        for ($i = 0; $i -lt $Catalog.Count; $i++) {
            $isDef   = ($Catalog[$i].Sku -eq $DefaultSku)
            $text    = Format-VmText -Entry $Catalog[$i] -IsGpuPool $IsGpu -IsDefault $isDef
            $prefix  = if ($i -eq $Sel) { " > " } else { "   " }

            if ($i -eq $Sel) {
                Write-MenuLine -Row ($Top + $i) -Text "${prefix}${text}" -Fg Black -Bg Cyan
            }
            elseif ($isDef) {
                Write-MenuLine -Row ($Top + $i) -Text "${prefix}${text}" -Fg Cyan -Bg $defBg
            }
            else {
                Write-MenuLine -Row ($Top + $i) -Text "${prefix}${text}" -Fg $defFg -Bg $defBg
            }
        }

        # "Custom" row
        $cRow   = $Top + $Catalog.Count
        $cPfx   = if ($Sel -eq $Catalog.Count) { " > " } else { "   " }
        if ($Sel -eq $Catalog.Count) {
            Write-MenuLine -Row $cRow -Text "${cPfx}Enter custom VM size..." -Fg Black -Bg Cyan
        }
        else {
            Write-MenuLine -Row $cRow -Text "${cPfx}Enter custom VM size..." -Fg $defFg -Bg $defBg
        }

        # Park cursor right after the menu so nothing blinks mid-list
        [Console]::SetCursorPosition(0, $Top + $itemCount)
    }

    # ── Outer loop (re-shown on Esc or unavailable VM) ─────────────
    while ($true) {
        # Static header
        Write-Host ""
        Write-Host "   Select VM size for $PoolName node pool:"
        Write-Host "   Use $([char]0x2191)/$([char]0x2193) to move, Enter to select, C custom, Esc cancel"
        Write-Host ""

        # Reserve blank lines so Render-Menu never scrolls the buffer.
        # Write them first, THEN compute where they started — this way
        # any scrolling that occurred is already reflected in CursorTop.
        for ($r = 0; $r -lt $itemCount; $r++) { [Console]::WriteLine("") }
        $menuTopLine = [Console]::CursorTop - $itemCount

        # Hide cursor while navigating
        [Console]::CursorVisible = $false
        try {
            # First draw
            Render-Menu -Sel $currentIndex -Top $menuTopLine

            # ── Key loop ───────────────────────────────────────────
            $confirmed = $false
            $escaped   = $false

            while (-not $confirmed -and -not $escaped) {
                $key = [Console]::ReadKey($true)

                switch ($key.Key) {
                    'UpArrow'   { if ($currentIndex -gt 0)                { $currentIndex-- }; Render-Menu -Sel $currentIndex -Top $menuTopLine }
                    'DownArrow' { if ($currentIndex -lt ($itemCount - 1)) { $currentIndex++ }; Render-Menu -Sel $currentIndex -Top $menuTopLine }
                    'Enter'     { $confirmed = $true }
                    'Escape'    { $escaped   = $true }
                    default {
                        if ($key.KeyChar -ceq 'c' -or $key.KeyChar -ceq 'C') {
                            $currentIndex = $Catalog.Count
                            Render-Menu -Sel $currentIndex -Top $menuTopLine
                        }
                    }
                }
            }
        }
        finally {
            [Console]::CursorVisible = $true
        }

        # Position cursor below the menu for any further output
        [Console]::SetCursorPosition(0, $menuTopLine + $itemCount)

        if ($escaped) {
            Write-Host ""
            Write-Host "   Selection cancelled by user. Provisioning aborted." -ForegroundColor Red
            exit 1
        }
        else {
            # ── Resolve selection from menu ────────────────────────────
            $selectedSku    = $null
            $selectedFamily = $null

            if ($currentIndex -eq $Catalog.Count) {
                $customSku = Read-Host "   Enter VM SKU (e.g. Standard_NC24ads_A100_v4)"
                if ([string]::IsNullOrWhiteSpace($customSku)) {
                    Write-Host "   No value entered. Re-showing menu..." -ForegroundColor Yellow
                    continue
                }
                $selectedSku = $customSku.Trim()
            }
            else {
                $selectedSku = $Catalog[$currentIndex].Sku
            }

            # ── Check region availability ──────────────────────────────
            Write-Host "   Checking availability of $selectedSku in $Location..." -NoNewline
            $availability = Test-VmAvailability -VmSize $selectedSku -Location $Location

            if (-not $availability.Available) {
                Write-Host " NOT AVAILABLE" -ForegroundColor Red
                Write-Host "   '$selectedSku' is not available in region '$Location'. Try another." -ForegroundColor Yellow
                continue
            }
            Write-Host " OK ($($availability.Cores) cores)" -ForegroundColor Green

            # ── Resolve GPU quota family & check quota inline ──────────
            if ($IsGpu) {
                $catalogEntry = $Catalog | Where-Object { $_.Sku -eq $selectedSku } | Select-Object -First 1
                if ($catalogEntry) {
                    $selectedFamily = $catalogEntry.Family
                }
                elseif ($GPU_FAMILY_MAP.ContainsKey($selectedSku)) {
                    $selectedFamily = $GPU_FAMILY_MAP[$selectedSku]
                }
                else {
                    Write-Host "   Custom GPU SKU — quota family needed for validation."
                    $selectedFamily = Read-Host "   Quota family (e.g. StandardNCADSA100v4Family, Enter to skip)"
                    if ([string]::IsNullOrWhiteSpace($selectedFamily)) {
                        $selectedFamily = $null
                        Write-Host "   Skipping GPU quota check for this pool." -ForegroundColor Yellow
                    }
                }

                # Early quota check — warn but let the user decide
                if ($selectedFamily) {
                    $totalCoresNeeded = $availability.Cores * $MaxNodes
                    $quotaResult = Assert-VmQuota -Label $PoolName -Family $selectedFamily -Location $Location -CoresNeeded $totalCoresNeeded
                    if ($quotaResult -in @("zero", "low")) {
                        $proceed = Read-Host "   Continue with this VM anyway? (y = keep, n = re-select) [n]"
                        if ($proceed -ne 'y' -and $proceed -ne 'Y') {
                            Write-Host "   Re-showing menu..." -ForegroundColor Yellow
                            continue
                        }
                    }
                }
            }
        }

        # ── Persist to azd env ─────────────────────────────────────
        try   { azd env set $EnvVarName $selectedSku 2>$null }
        catch { Write-Host "   Warning: could not persist $EnvVarName via 'azd env set'." -ForegroundColor Yellow }

        Write-Host "   Selected: $selectedSku" -ForegroundColor Green
        Write-Host ""

        return @{
            Sku    = $selectedSku
            Cores  = $availability.Cores
            Family = $selectedFamily
        }
    }
}
