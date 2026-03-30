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

# ── Azure VM Data (queried once, shared across menus) ────────────────────

function Get-AzVmSizesForRegion {
    <#
    .SYNOPSIS
        Queries az vm list-sizes for a region and returns an array of hashtables.
        Each entry: @{ Name; Cores; MemoryGB }
    #>
    param([string]$Location)
    $raw = (az vm list-sizes --location $Location -o json 2>$null) | ConvertFrom-Json
    if (-not $raw) { return @() }
    return $raw | ForEach-Object {
        @{ Name = $_.name; Cores = [int]$_.numberOfCores; MemoryGB = [math]::Round($_.memoryInMB / 1024) }
    }
}

function Select-VmSizesForMenu {
    <#
    .SYNOPSIS
        Picks VM sizes for the interactive menu based on recommended families.
        For each family, matches VM names that contain the family pattern,
        filters by core range, takes up to $SizesPerFamily sorted by cores.
        The default SKU is always included. Result is sorted by cores.
    #>
    param(
        [array]$AllSizes,
        [string[]]$Prefixes,
        [string[]]$RecommendedFamilies,
        [string]$DefaultSku,
        [int]$SizesPerFamily = 3,
        [int]$MinCores = 0,
        [int]$MaxCores = [int]::MaxValue
    )

    # Filter by broad prefix first (CPU vs GPU), then by core range
    $pool = $AllSizes | Where-Object {
        $n = $_.Name; $c = $_.Cores
        ($Prefixes | Where-Object { $n.StartsWith($_) }).Count -gt 0 -and
        $c -ge $MinCores -and $c -le $MaxCores
    }

    # For each recommended family, find matching VMs and take top N by cores
    $selected = @{}  # keyed by Name to deduplicate
    foreach ($family in $RecommendedFamilies) {
        $familyMatches = $pool | Where-Object { $_.Name -match $family } |
                   Sort-Object { $_.Cores }, { $_.Name } |
                   Select-Object -First $SizesPerFamily
        foreach ($vm in $familyMatches) {
            $selected[$vm.Name] = $vm
        }
    }

    # Ensure the default SKU is included
    if ($DefaultSku -and -not $selected.ContainsKey($DefaultSku)) {
        $defVm = $pool | Where-Object { $_.Name -eq $DefaultSku } | Select-Object -First 1
        if ($defVm) { $selected[$defVm.Name] = $defVm }
    }

    # Return sorted by cores
    return $selected.Values | Sort-Object { $_.Cores }, { $_.Name }
}

function Get-AzVmQuotaForRegion {
    <#
    .SYNOPSIS
        Queries az vm list-usage for a region and returns a hashtable keyed by family name.
        Each value: @{ Limit; Used; Available }
    #>
    param([string]$Location)
    $result = @{}
    $raw = (az vm list-usage --location $Location -o json 2>$null) | ConvertFrom-Json
    if (-not $raw) { return $result }
    foreach ($q in $raw) {
        $result[$q.name.value] = @{
            Limit     = [int]$q.limit
            Used      = [int]$q.currentValue
            Available = [int]$q.limit - [int]$q.currentValue
        }
    }
    return $result
}

function Get-QuotaFamilyForVm {
    <#
    .SYNOPSIS
        Resolves the quota family name for a GPU VM size using the
        GPU_QUOTA_FAMILY_MAP regex lookup table. No API call needed.
        Returns the family string, or $null if no pattern matches.
    #>
    param(
        [string]$VmSize,
        [string]$Location   # kept for interface compat, not used
    )
    foreach ($pattern in $GPU_QUOTA_FAMILY_MAP.Keys) {
        if ($VmSize -match $pattern) {
            return $GPU_QUOTA_FAMILY_MAP[$pattern]
        }
    }
    return $null
}

function Assert-VmQuota {
    <#
    .SYNOPSIS
        Checks GPU quota for a pool using the pre-fetched quota hashtable.
        Returns: "ok", "skip", "zero", "low", or "error".
    #>
    param(
        [string]$Label,
        [string]$Family,
        [hashtable]$QuotaData,
        [int]$CoresNeeded
    )

    if (-not $Family) {
        Write-Host "   [$Label] Skipping quota check (no quota family)" -ForegroundColor Yellow
        return "skip"
    }

    Write-Host "   [$Label] Checking quota for '$Family'..." -NoNewline

    if (-not $QuotaData.ContainsKey($Family)) {
        Write-Host " UNKNOWN (family not found)" -ForegroundColor Yellow
        return "error"
    }

    $q = $QuotaData[$Family]

    if ($q.Limit -eq 0) {
        Write-Host " ZERO QUOTA" -ForegroundColor Red
        Write-Host "   [$Label] No quota allocated for '$Family'." -ForegroundColor Red
        Write-Host "   Request GPU quota at: $QUOTA_URL"
        Write-Host "   For step-by-step instructions, see: $GPU_QUOTA_DOC_URL"
        return "zero"
    }

    if ($CoresNeeded -gt 0 -and $q.Available -lt $CoresNeeded) {
        Write-Host " LOW ($($q.Available) cores free, need $CoresNeeded)" -ForegroundColor Yellow
        Write-Host "   [$Label] Insufficient quota — $($q.Available)/$($q.Limit) available ($($q.Used) used)" -ForegroundColor Yellow
        Write-Host "   Request quota increase at: $QUOTA_URL"
        Write-Host "   For step-by-step instructions, see: $GPU_QUOTA_DOC_URL"
        return "low"
    }

    Write-Host " OK ($($q.Available) cores free)" -ForegroundColor Green
    return "ok"
}

# ── Interactive VM Selection Menu ─────────────────────────────────────────

function Show-VmSelectionMenu {
    <#
    .SYNOPSIS
        Arrow-key driven interactive menu for selecting a VM size.
        The catalog is built dynamically from az vm list-sizes data.
        Up/Down to move, Enter to select, C for custom, Esc to abort.
    .PARAMETER VmSizes
        Array of hashtables from Get-AzVmSizesForRegion, pre-filtered for CPU or GPU.
    .PARAMETER QuotaData
        Hashtable from Get-AzVmQuotaForRegion (used for GPU quota check).
    .OUTPUTS
        Hashtable with keys: Sku, Cores, Family (Family is $null for CPU VMs)
    #>
    param(
        [string]$PoolName,
        [string]$EnvVarName,
        [array]$VmSizes,
        [string]$DefaultSku,
        [string]$Location,
        [switch]$IsGpu,
        [int]$MaxNodes = 1,
        [hashtable]$QuotaData = @{}
    )

    if ($VmSizes.Count -eq 0) {
        Write-Host "   No VM sizes available in region '$Location' for this pool." -ForegroundColor Red
        Write-Host "   Selection cancelled. Provisioning aborted." -ForegroundColor Red
        exit 1
    }

    $totalItems = $VmSizes.Count + 1  # VM entries + "Custom" row
    $bufWidth   = [Console]::BufferWidth
    $maxVisible = [math]::Min(20, $totalItems)  # viewport height

    # Find the default index
    $currentIndex = 0
    for ($i = 0; $i -lt $VmSizes.Count; $i++) {
        if ($VmSizes[$i].Name -eq $DefaultSku) {
            $currentIndex = $i
            break
        }
    }

    # Scroll offset — first item visible in the viewport
    $scrollOffset = [math]::Max(0, $currentIndex - [math]::Floor($maxVisible / 2))
    $scrollOffset = [math]::Min($scrollOffset, [math]::Max(0, $totalItems - $maxVisible))

    # ── Write one padded, coloured line without scrolling ──────────
    function Write-MenuLine {
        param([int]$Row, [string]$Text, [ConsoleColor]$Fg, [ConsoleColor]$Bg)
        [Console]::SetCursorPosition(0, $Row)
        $padded = $Text.PadRight($bufWidth - 1)
        $oldFg = [Console]::ForegroundColor
        $oldBg = [Console]::BackgroundColor
        [Console]::ForegroundColor = $Fg
        [Console]::BackgroundColor = $Bg
        [Console]::Write($padded)
        [Console]::ForegroundColor = $oldFg
        [Console]::BackgroundColor = $oldBg
    }

    # ── Build the display text for one row ─────────────────────────
    function Format-VmText {
        param([hashtable]$Entry, [bool]$IsDefault)
        $name  = $Entry.Name.PadRight(35)
        $cores = "$($Entry.Cores) vCPUs".PadRight(10)
        $mem   = "$($Entry.MemoryGB) GB".PadRight(8)
        $tag   = if ($IsDefault) { " (default)" } else { "" }
        return "${name} ${cores} ${mem}${tag}"
    }

    # ── Redraw the visible viewport in-place ───────────────────────
    function Render-Menu {
        param([int]$Sel, [int]$Top, [int]$Offset)
        $defFg = [Console]::ForegroundColor
        $defBg = [Console]::BackgroundColor
        $visEnd = [math]::Min($Offset + $maxVisible, $totalItems)

        for ($row = 0; $row -lt $maxVisible; $row++) {
            $itemIdx = $Offset + $row
            if ($itemIdx -ge $totalItems) {
                # Blank filler if viewport is larger than remaining items
                Write-MenuLine -Row ($Top + $row) -Text "" -Fg $defFg -Bg $defBg
                continue
            }

            if ($itemIdx -eq $VmSizes.Count) {
                # "Custom" row
                $pfx = if ($itemIdx -eq $Sel) { " > " } else { "   " }
                $txt = "${pfx}Enter custom VM size..."
                if ($itemIdx -eq $Sel) {
                    Write-MenuLine -Row ($Top + $row) -Text $txt -Fg Black -Bg Cyan
                } else {
                    Write-MenuLine -Row ($Top + $row) -Text $txt -Fg $defFg -Bg $defBg
                }
            }
            else {
                $isDef  = ($VmSizes[$itemIdx].Name -eq $DefaultSku)
                $text   = Format-VmText -Entry $VmSizes[$itemIdx] -IsDefault $isDef
                $prefix = if ($itemIdx -eq $Sel) { " > " } else { "   " }

                if ($itemIdx -eq $Sel) {
                    Write-MenuLine -Row ($Top + $row) -Text "${prefix}${text}" -Fg Black -Bg Cyan
                }
                elseif ($isDef) {
                    Write-MenuLine -Row ($Top + $row) -Text "${prefix}${text}" -Fg Cyan -Bg $defBg
                }
                else {
                    Write-MenuLine -Row ($Top + $row) -Text "${prefix}${text}" -Fg $defFg -Bg $defBg
                }
            }
        }

        # Scroll indicators on the right edge of first/last row
        if ($Offset -gt 0) {
            [Console]::SetCursorPosition($bufWidth - 4, $Top)
            [Console]::Write(" $([char]0x2191)  ")
        }
        if ($visEnd -lt $totalItems) {
            [Console]::SetCursorPosition($bufWidth - 4, $Top + $maxVisible - 1)
            [Console]::Write(" $([char]0x2193)  ")
        }

        [Console]::SetCursorPosition(0, $Top + $maxVisible)
    }

    # ── Ensure selection is visible, adjust scrollOffset ───────────
    function Update-Scroll {
        if ($currentIndex -lt $scrollOffset) {
            $script:scrollOffset = $currentIndex
        }
        elseif ($currentIndex -ge ($scrollOffset + $maxVisible)) {
            $script:scrollOffset = $currentIndex - $maxVisible + 1
        }
        $script:scrollOffset = [math]::Max(0, [math]::Min($script:scrollOffset, $totalItems - $maxVisible))
    }

    # ── Outer loop ─────────────────────────────────────────────────
    while ($true) {
        Write-Host ""
        Write-Host "   Select VM size for $PoolName node pool ($($VmSizes.Count) sizes available):"
        Write-Host "   Use $([char]0x2191)/$([char]0x2193) to move, Enter to select, C custom, Esc cancel"
        Write-Host ""

        # Reserve exactly $maxVisible blank lines (viewport size, not total items)
        for ($r = 0; $r -lt $maxVisible; $r++) { [Console]::WriteLine("") }
        $menuTopLine = [Console]::CursorTop - $maxVisible

        [Console]::CursorVisible = $false
        try {
            Update-Scroll
            Render-Menu -Sel $currentIndex -Top $menuTopLine -Offset $scrollOffset

            $confirmed = $false
            $escaped   = $false

            while (-not $confirmed -and -not $escaped) {
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    'UpArrow' {
                        if ($currentIndex -gt 0) { $currentIndex-- }
                        Update-Scroll
                        Render-Menu -Sel $currentIndex -Top $menuTopLine -Offset $scrollOffset
                    }
                    'DownArrow' {
                        if ($currentIndex -lt ($totalItems - 1)) { $currentIndex++ }
                        Update-Scroll
                        Render-Menu -Sel $currentIndex -Top $menuTopLine -Offset $scrollOffset
                    }
                    'Enter'  { $confirmed = $true }
                    'Escape' { $escaped   = $true }
                    default {
                        if ($key.KeyChar -ceq 'c' -or $key.KeyChar -ceq 'C') {
                            $currentIndex = $VmSizes.Count
                            Update-Scroll
                            Render-Menu -Sel $currentIndex -Top $menuTopLine -Offset $scrollOffset
                        }
                    }
                }
            }
        }
        finally {
            [Console]::CursorVisible = $true
        }

        [Console]::SetCursorPosition(0, $menuTopLine + $maxVisible)

        if ($escaped) {
            Write-Host ""
            Write-Host "   Selection cancelled by user. Provisioning aborted." -ForegroundColor Red
            exit 1
        }

        # ── Resolve selection ──────────────────────────────────────
        $selectedSku    = $null
        $selectedFamily = $null
        $selectedCores  = 0

        if ($currentIndex -eq $VmSizes.Count) {
            $customSku = Read-Host "   Enter VM SKU (e.g. Standard_NC24ads_A100_v4)"
            if ([string]::IsNullOrWhiteSpace($customSku)) {
                Write-Host "   No value entered. Re-showing menu..." -ForegroundColor Yellow
                continue
            }
            $selectedSku = $customSku.Trim()
            # Look up cores from the full list
            $match = $VmSizes | Where-Object { $_.Name -eq $selectedSku } | Select-Object -First 1
            if ($match) {
                $selectedCores = $match.Cores
            }
            else {
                Write-Host "   '$selectedSku' not found in region '$Location'." -ForegroundColor Red
                continue
            }
        }
        else {
            $selectedSku   = $VmSizes[$currentIndex].Name
            $selectedCores = $VmSizes[$currentIndex].Cores
        }

        Write-Host "   $selectedSku — $selectedCores vCPUs" -ForegroundColor Green

        # ── GPU quota check ────────────────────────────────────────
        if ($IsGpu) {
            Write-Host "   Resolving quota family..." -NoNewline
            $selectedFamily = Get-QuotaFamilyForVm -VmSize $selectedSku -Location $Location
            if ($selectedFamily) {
                Write-Host " $selectedFamily" -ForegroundColor Gray
                $totalCoresNeeded = $selectedCores * $MaxNodes
                $quotaResult = Assert-VmQuota -Label $PoolName -Family $selectedFamily -QuotaData $QuotaData -CoresNeeded $totalCoresNeeded
                if ($quotaResult -in @("zero", "low")) {
                    $proceed = Read-Host "   Continue with this VM anyway? (y = keep, n = re-select) [n]"
                    if ($proceed -ne 'y' -and $proceed -ne 'Y') {
                        Write-Host "   Re-showing menu..." -ForegroundColor Yellow
                        continue
                    }
                }
            }
            else {
                Write-Host " not found (quota check skipped)" -ForegroundColor Yellow
            }
        }

        # ── Persist to azd env ─────────────────────────────────────
        try   { azd env set $EnvVarName $selectedSku 2>$null }
        catch { Write-Host "   Warning: could not persist $EnvVarName via 'azd env set'." -ForegroundColor Yellow }

        Write-Host "   Selected: $selectedSku" -ForegroundColor Green
        Write-Host ""

        return @{
            Sku    = $selectedSku
            Cores  = $selectedCores
            Family = $selectedFamily
        }
    }
}
