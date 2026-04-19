# =============================================================================
# Shared Utilities: Common functions used across all PowerShell hooks
# =============================================================================
# Source this file via: . "$PSScriptRoot/common.ps1"
# This file automatically loads config.ps1 and ui.ps1.

. "$PSScriptRoot/config.ps1"
. "$PSScriptRoot/ui.ps1"

# ── Prerequisite Checks ─────────────────────────────────────────────────────

function Assert-EnvVars {
    param([string[]]$Required)
    $missing = $Required | Where-Object { -not (Get-Item "env:$_" -ErrorAction SilentlyContinue) }
    if ($missing) {
        Log-Error "Missing required environment variables:"
        foreach ($var in $missing) {
            Write-Host "     $($script:C.Error)$($script:Sym.Error)$($script:C.Reset)  $var"
        }
        Write-Host ""
        Log-Info "Run 'azd env get-values' to check your environment."
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
            Log-Success "$cmd"
        }
        else {
            Log-Error "$cmd - not found"
            $errorCount++
        }
    }
    foreach ($cmd in $Optional) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            Log-Success "$cmd"
        }
        else {
            Log-Warning "$cmd - not found (optional)"
        }
    }
    if ($errorCount -gt 0) {
        Write-Host ""
        Log-Error "$errorCount required tool(s) missing. Install them before proceeding."
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
                Log-Success "$provider"
            }
            "Registering" {
                Log-Warning "$provider (registration in progress)"
                $providersRegistering++
            }
            { $_ -in @("NotRegistered", "Unregistered") } {
                Log-Info "Registering $provider..."
                az provider register --namespace $provider --wait false 2>$null
                Log-Success "$provider registered"
                $providersRegistering++
            }
            default {
                Log-Warning "$provider ($state)"
            }
        }
    }

    if ($providersRegistering -gt 0) {
        Write-Host ""
        Log-Warning "$providersRegistering provider(s) are being registered."
        Log-Info "Registration can take 2-5 minutes. Provisioning will proceed,"
        Log-Info "but if it fails, wait a few minutes and retry."
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
        Queries az vm list-skus for a region and returns an array of hashtables.
        Uses list-skus (not list-sizes) to respect subscription restrictions —
        only SKUs the subscription is allowed to use are returned.
        Each entry: @{ Name; Cores; MemoryGB; Family }
        Family is the quota family name (matches az vm list-usage name.value).
    #>
    param([string]$Location)
    $query = "[?restrictions[?type=='Location']|length(@)==``0``].{name:name, family:family, vCPUs:capabilities[?name=='vCPUs'].value|[0], memGB:capabilities[?name=='MemoryGB'].value|[0]}"
    $raw = (az vm list-skus --location $Location --resource-type virtualMachines --query $query -o json 2>$null) | ConvertFrom-Json
    if (-not $raw) { return @() }
    return $raw | ForEach-Object {
        @{ Name = $_.name; Cores = [int]$_.vCPUs; MemoryGB = [int]$_.memGB; Family = $_.family }
    }
}

function Resolve-DefaultSku {
    <#
    .SYNOPSIS
        Checks if the desired default SKU exists in the available list.
        If not, picks the closest available SKU by core count.
    #>
    param(
        [string]$DefaultSku,
        [array]$AvailableSizes,
        [int]$PreferCores = 0
    )
    if (-not $AvailableSizes -or $AvailableSizes.Count -eq 0) { return $DefaultSku }

    # Check if default exists in available list
    $match = $AvailableSizes | Where-Object { $_.Name -eq $DefaultSku }
    if ($match) { return $DefaultSku }

    # Not available — log and pick the closest by core count
    Log-Warning "Default SKU '$DefaultSku' is not available in this subscription/region."

    if ($PreferCores -gt 0) {
        $closest = $AvailableSizes | Sort-Object { [math]::Abs($_.Cores - $PreferCores) } | Select-Object -First 1
    }
    else {
        $closest = $AvailableSizes | Select-Object -First 1
    }

    if ($closest) {
        Log-Info "Auto-selected '$($closest.Name)' ($($closest.Cores) vCPUs) as closest match."
        return $closest.Name
    }
    return $DefaultSku
}

function Select-VmSizesForMenu {
    <#
    .SYNOPSIS
        Picks VM sizes for the interactive menu based on recommended families.
        For each family, matches VM names that contain the family pattern,
        filters by core range, takes up to $SizesPerFamily sorted by cores.
        The default SKU is always included. Result is sorted by cores.

        When QuotaData is supplied, each entry is annotated with quota info
        (AvailableQuota, QuotaLimit, QuotaFamily, HasEnoughQuota). SKUs whose
        family has too little quota to run $MaxNodes of that size are dropped,
        except the default SKU which is kept (annotated) so the user sees it.
    #>
    param(
        [array]$AllSizes,
        [string[]]$Prefixes,
        [string[]]$RecommendedFamilies,
        [string]$DefaultSku,
        [int]$SizesPerFamily = 3,
        [int]$MinCores = 0,
        [int]$MaxCores = [int]::MaxValue,
        [hashtable]$QuotaData,
        [int]$MaxNodes = 1
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

    $entries = $selected.Values | Sort-Object { $_.Cores }, { $_.Name }

    # ── Annotate with quota + drop SKUs that cannot satisfy $MaxNodes ─────
    if ($QuotaData -and $QuotaData.Count -gt 0) {
        $annotated = @()
        foreach ($vm in $entries) {
            $fam = Get-QuotaFamilyForVm -VmSize $vm.Name -SkuFamily $vm.Family
            $avail = $null; $limit = $null; $hasEnough = $true; $familyKnown = $false
            if ($fam -and $QuotaData.ContainsKey($fam)) {
                $familyKnown = $true
                $avail = [int]$QuotaData[$fam].Available
                $limit = [int]$QuotaData[$fam].Limit
                $needed = [int]$vm.Cores * [math]::Max(1, [int]$MaxNodes)
                $hasEnough = ($limit -gt 0) -and ($avail -ge $needed)
            }
            # Clone hashtable so we don't mutate the shared $AllSizes entries
            $copy = @{}
            foreach ($k in $vm.Keys) { $copy[$k] = $vm[$k] }
            $copy.QuotaFamily     = $fam
            $copy.QuotaFamilyKnown = $familyKnown
            $copy.AvailableQuota  = $avail
            $copy.QuotaLimit      = $limit
            $copy.HasEnoughQuota  = $hasEnough
            $annotated += ,$copy
        }

        # Keep only entries with a known quota family AND enough quota.
        # The user-facing default is kept regardless so it's never silently
        # hidden — the final quota check before submission still guards it.
        $filtered = $annotated | Where-Object {
            ($_.QuotaFamilyKnown -and $_.HasEnoughQuota) -or ($_.Name -eq $DefaultSku)
        }

        # Fallback: if quota would empty the list, return the unfiltered annotated
        # set so the user can still pick something and be warned.
        if (-not $filtered -or @($filtered).Count -eq 0) {
            return $annotated
        }
        return @($filtered)
    }

    return $entries
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
        Resolves the quota family name for a VM size.
        Prefers the family string reported by az vm list-skus (passed via
        -SkuFamily) because it matches az vm list-usage's name.value directly.
        Falls back to the GPU_QUOTA_FAMILY_MAP regex table for older SKUs where
        the family field is empty.
        Returns the family string, or $null if nothing matches.
    #>
    param(
        [string]$VmSize,
        [string]$SkuFamily,
        [string]$Location   # kept for interface compat, not used
    )
    if (-not [string]::IsNullOrWhiteSpace($SkuFamily)) {
        return $SkuFamily
    }
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
        Log-Warning "[$Label] Skipping quota check (no quota family)"
        return "skip"
    }

    Write-LogMessage -Message "[$Label] Checking quota for '$Family'..." -Symbol $script:Sym.Info -SymbolColor $script:C.Accent -NoNewline

    if (-not $QuotaData.ContainsKey($Family)) {
        Write-Host " UNKNOWN (family not found)" -ForegroundColor Yellow
        return "error"
    }

    $q = $QuotaData[$Family]

    if ($q.Limit -eq 0) {
        Write-Host ""
        Log-Error "[$Label] No quota allocated for '$Family'."
        Log-Info "Request GPU quota at: $QUOTA_URL"
        Log-Info "For step-by-step instructions, see: $GPU_QUOTA_DOC_URL"
        return "zero"
    }

    if ($CoresNeeded -gt 0 -and $q.Available -lt $CoresNeeded) {
        Write-Host ""
        Log-Warning "[$Label] Insufficient quota: $($q.Available)/$($q.Limit) available ($($q.Used) used), need $CoresNeeded"
        Log-Info "Request quota increase at: $QUOTA_URL"
        Log-Info "For step-by-step instructions, see: $GPU_QUOTA_DOC_URL"
        return "low"
    }

    Write-Host " $($script:C.Success)OK ($($q.Available) cores free)$($script:C.Reset)"
    return "ok"
}

# ── AI Model Quota Check ──────────────────────────────────────────────────

function Resolve-ModelQuota {
    param(
        [string]$Location,
        [string]$Model,
        [string]$Format = $DEFAULT_AI_MODEL_FORMAT,
        [string]$DeploymentType = $DEFAULT_AI_MODEL_DEPLOYMENT_TYPE,
        [string]$CapacityEnvVarName = 'AI_MODEL_CAPACITY',
        [int]$Capacity
    )

    $modelType = "$Format.$DeploymentType.$Model"
    Log-Info "Checking quota for $modelType in $Location..."

    $modelInfo = $null
    try {
        $modelInfo = (az cognitiveservices usage list --location $Location `
                --query "[?name.value=='$modelType'] | [0]" -o json 2>$null) | ConvertFrom-Json
    }
    catch { }

    if (-not $modelInfo) {
        Log-Warning "No quota info found for '$modelType' in '$Location'. Skipping quota check."
        Log-Info "The model may not be available in this region. Bicep will report a clearer error if so."
        return
    }

    $currentValue = [int]($modelInfo.currentValue -replace '\.0+$', '')
    $limit = [int]($modelInfo.limit -replace '\.0+$', '')
    $available = $limit - $currentValue

    Write-KeyValue "Model" $modelType
    Write-KeyValue "Quota" "$available available ($currentValue used / $limit limit)"

    if ($available -ge $Capacity) {
        Log-Success "Sufficient quota: $available available, need $Capacity"
        return
    }

    if ($available -ge 1) {
        Log-Warning "Insufficient quota: $available available (in thousands of TPM), need $Capacity."
        $validInput = $false
        do {
            $userInput = Read-Host "Enter a new capacity between 1 and $available (or 'q' to abort)"
            if ($userInput -eq 'q') {
                Log-Error "Aborted by user."
                exit 1
            }
            $parsed = 0
            if ([int]::TryParse($userInput, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $available) {
                $validInput = $true
            }
            else {
                Log-Warning "Invalid input. Enter an integer between 1 and $available."
            }
        } while (-not $validInput)

        azd env set $CapacityEnvVarName $parsed 2>$null
        Log-Success "Capacity adjusted to $parsed (saved to $CapacityEnvVarName)"
    }
    else {
        Log-Error "Zero quota available for '$modelType' in '$Location'."
        Log-Info "Request quota at: $AI_QUOTA_URL"
        exit 1
    }
}

# ── Interactive VM Selection Menu ─────────────────────────────────────────
# NOTE: This function uses low-level [Console] manipulation for interactive
# arrow-key menus. Its internal styling is intentionally left as-is.

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
        Log-Error "No VM sizes available in region '$Location' for this pool."
        Log-Error "Selection cancelled. Provisioning aborted."
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

        # Quota column (only when quota data was supplied)
        $quotaCol = ""
        if ($Entry.ContainsKey('QuotaFamilyKnown')) {
            if ($Entry.QuotaFamilyKnown) {
                $quotaCol = "$($Entry.AvailableQuota) free".PadRight(14)
            }
            else {
                $quotaCol = "quota n/a".PadRight(14)
            }
        }

        $tag = if ($IsDefault) { " (default)" } else { "" }
        return "${name} ${cores} ${mem} ${quotaCol}${tag}"
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
        Write-Section "Select VM size for $PoolName ($($VmSizes.Count) sizes available)"
        Log-Info "Use $([char]0x2191)/$([char]0x2193) to move, Enter to select, C custom, Esc cancel"
        if ($VmSizes.Count -gt 0 -and $VmSizes[0].ContainsKey('QuotaFamilyKnown')) {
            Log-Info "Quota column shows cores free in this region (pool max nodes: $MaxNodes)."
        }
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
            Log-Error "Selection cancelled by user. Provisioning aborted."
            exit 1
        }

        # ── Resolve selection ──────────────────────────────────────
        $selectedSku    = $null
        $selectedFamily = $null
        $selectedCores  = 0

        if ($currentIndex -eq $VmSizes.Count) {
            $customSku = Read-Host "   Enter VM SKU (e.g. Standard_NC24ads_A100_v4)"
            if ([string]::IsNullOrWhiteSpace($customSku)) {
                Log-Warning "No value entered. Re-showing menu..."
                continue
            }
            $selectedSku = $customSku.Trim()
            # Look up cores from the full list
            $match = $VmSizes | Where-Object { $_.Name -eq $selectedSku } | Select-Object -First 1
            if ($match) {
                $selectedCores = $match.Cores
            }
            else {
                Log-Error "'$selectedSku' not found in region '$Location'."
                continue
            }
        }
        else {
            $selectedSku   = $VmSizes[$currentIndex].Name
            $selectedCores = $VmSizes[$currentIndex].Cores
        }

        Log-Success "$selectedSku $($script:C.Muted)($selectedCores vCPUs)$($script:C.Reset)"

        # ── GPU quota check ────────────────────────────────────────
        if ($IsGpu) {
            Write-LogMessage -Message "Resolving quota family..." -Symbol $script:Sym.Info -SymbolColor $script:C.Accent -NoNewline
            $skuFamily = $null
            $match = $VmSizes | Where-Object { $_.Name -eq $selectedSku } | Select-Object -First 1
            if ($match -and $match.ContainsKey('Family')) { $skuFamily = $match.Family }
            $selectedFamily = Get-QuotaFamilyForVm -VmSize $selectedSku -SkuFamily $skuFamily -Location $Location
            if ($selectedFamily) {
                Write-Host " $($script:C.Muted)$selectedFamily$($script:C.Reset)"
                $totalCoresNeeded = $selectedCores * $MaxNodes
                $quotaResult = Assert-VmQuota -Label $PoolName -Family $selectedFamily -QuotaData $QuotaData -CoresNeeded $totalCoresNeeded
                if ($quotaResult -in @("zero", "low")) {
                    $proceed = Read-Host "   Continue with this VM anyway? (y = keep, n = re-select) [n]"
                    if ($proceed -ne 'y' -and $proceed -ne 'Y') {
                        Log-Warning "Re-showing menu..."
                        continue
                    }
                }
            }
            else {
                Write-Host " $($script:C.Warning)not found (quota check skipped)$($script:C.Reset)"
            }
        }

        # ── Persist to azd env ─────────────────────────────────────
        try   { azd env set $EnvVarName $selectedSku 2>$null }
        catch { Log-Warning "Could not persist $EnvVarName via 'azd env set'." }

        Log-Success "Selected: $selectedSku"
        Write-Host ""

        return @{
            Sku    = $selectedSku
            Cores  = $selectedCores
            Family = $selectedFamily
        }
    }
}
