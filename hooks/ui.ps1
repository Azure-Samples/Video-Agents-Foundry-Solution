# =============================================================================
# UI Module: ANSI colors, symbols, logging, spinners, and banners
# =============================================================================
# Adapted from VideoIndexer-CLI styling patterns.
# Source this file via common.ps1 (which sources config.ps1 first).

# ── ANSI Support Detection ──────────────────────────────────────────────────

function Test-AnsiSupport {
    if ($PSVersionTable.PSVersion.Major -ge 7) { return $true }
    if ($env:WT_SESSION) { return $true }
    if ($env:TERM_PROGRAM -eq "vscode") { return $true }
    if ($env:ConEmuANSI -eq "ON") { return $true }
    if ($PSVersionTable.PSEdition -eq "Desktop") {
        try {
            $build = [System.Environment]::OSVersion.Version.Build
            if ($build -ge 10586) { return $true }
        }
        catch { }
    }
    return $false
}

$script:AnsiSupported = Test-AnsiSupport

# ── Color Constants ─────────────────────────────────────────────────────────
# Stored in a hashtable to avoid clashing with PowerShell read-only variables
# like $Error. Access as $script:C.Success, $script:C.Error, etc.

$script:ESC = [char]27

if ($script:AnsiSupported) {
    $script:C = @{
        Reset      = "$($script:ESC)[0m"
        Bold       = "$($script:ESC)[1m"
        Dim        = "$($script:ESC)[2m"

        # Semantic colors (cyan accent — matches azd output style)
        Accent     = "$($script:ESC)[36m"
        AccentBold = "$($script:ESC)[1;36m"
        AccentDim  = "$($script:ESC)[2;36m"
        Success    = "$($script:ESC)[32m"
        Error      = "$($script:ESC)[91m"
        Warning    = "$($script:ESC)[33m"
        Info       = "$($script:ESC)[37m"
        Muted      = "$($script:ESC)[90m"
        Text       = "$($script:ESC)[37m"
        BoldWhite  = "$($script:ESC)[1;97m"
    }
}
else {
    $script:C = @{
        Reset = ""; Bold = ""; Dim = ""
        Accent = ""; AccentBold = ""; AccentDim = ""
        Success = ""; Error = ""; Warning = ""
        Info = ""; Muted = ""; Text = ""
        BoldWhite = ""
    }
}

# ── Symbol Constants ────────────────────────────────────────────────────────

if ($script:AnsiSupported) {
    $script:Sym = @{
        Success   = [char]0x2714   # ✔
        Error     = [char]0x2718   # ✘
        Warning   = [char]0x26A0  # ⚠
        Info      = [char]0x2022   # •
        Pending   = [char]0x25CB   # ○
        Pointer   = [char]0x276F  # ❯
        Arrow     = [char]0x2192   # →
        HLine     = [char]0x2500   # ─
        Step      = [char]0x25B6  # ▶
    }

    $script:BoxDouble = @{
        TL = [char]0x2554; TR = [char]0x2557
        BL = [char]0x255A; BR = [char]0x255D
        H  = [char]0x2550; V  = [char]0x2551
    }

    $script:BoxSingle = @{
        TL = [char]0x250C; TR = [char]0x2510
        BL = [char]0x2514; BR = [char]0x2518
        H  = [char]0x2500; V  = [char]0x2502
    }
}
else {
    $script:Sym = @{
        Success = "+"; Error = "x"; Warning = "!"; Info = "*"
        Pending = "o"; Pointer = ">"; Arrow = "->"; HLine = "-"; Step = ">"
    }

    $script:BoxDouble = @{
        TL = "+"; TR = "+"; BL = "+"; BR = "+"
        H  = "="; V  = "|"
    }

    $script:BoxSingle = @{
        TL = "+"; TR = "+"; BL = "+"; BR = "+"
        H  = "-"; V  = "|"
    }
}

# ── Core Logging ────────────────────────────────────────────────────────────

function Write-LogMessage {
    param(
        [string]$Message,
        [string]$Symbol = "",
        [string]$SymbolColor = $script:C.Info,
        [string]$MessageColor = $script:C.Text,
        [switch]$NoTimestamp,
        [switch]$NoNewline
    )

    $ts = if (-not $NoTimestamp) {
        "$($script:C.Muted)$(Get-Date -Format 'HH:mm:ss')$($script:C.Reset)  "
    } else { "  " }

    $sym = if ($Symbol) {
        "$SymbolColor$Symbol$($script:C.Reset)  "
    } else { "   " }

    $line = "  $ts$sym$MessageColor$Message$($script:C.Reset)"

    if ($NoNewline) {
        Write-Host $line -NoNewline
    }
    else {
        Write-Host $line
    }
}

function Log-Info {
    param([string]$Message)
    Write-LogMessage -Message $Message -Symbol $script:Sym.Info -SymbolColor $script:C.Accent
}

function Log-Success {
    param([string]$Message)
    Write-LogMessage -Message $Message -Symbol $script:Sym.Success `
        -SymbolColor $script:C.Success -MessageColor $script:C.Success
}

function Log-Error {
    param([string]$Message)
    Write-LogMessage -Message $Message -Symbol $script:Sym.Error `
        -SymbolColor $script:C.Error -MessageColor $script:C.Error
}

function Log-Warning {
    param([string]$Message)
    Write-LogMessage -Message $Message -Symbol $script:Sym.Warning `
        -SymbolColor $script:C.Warning -MessageColor $script:C.Warning
}

function Log-Step {
    param(
        [int]$Number,
        [int]$Total,
        [string]$Title
    )
    $counter = "$($script:C.Muted)[$Number/$Total]$($script:C.Reset)"
    $sym     = "$($script:C.AccentBold)$($script:Sym.Step)$($script:C.Reset)"
    Write-Host ""
    Write-Host "  $sym  $counter  $($script:C.BoldWhite)$Title$($script:C.Reset)"
    Write-Host "  $($script:C.Muted)$([string]$script:Sym.HLine * 60)$($script:C.Reset)"
}

# ── Banner & Box Drawing ───────────────────────────────────────────────────

function Write-BoxBanner {
    param(
        [string]$Text,
        [string]$Subtitle = "",
        [ValidateSet("Double", "Single")]
        [string]$Style = "Double",
        [int]$Width = 64
    )

    $box   = if ($Style -eq "Double") { $script:BoxDouble } else { $script:BoxSingle }
    $color = if ($Style -eq "Double") { $script:C.AccentBold } else { $script:C.Accent }
    $r     = $script:C.Reset

    $innerWidth = $Width - 2
    $hLine = [string]$box.H * $innerWidth

    Write-Host "  $color$($box.TL)$hLine$($box.TR)$r"
    Write-Host "  $color$($box.V)$(' ' * $innerWidth)$($box.V)$r"

    # Centered title
    $pad   = $innerWidth - $Text.Length
    $left  = [math]::Floor($pad / 2)
    $right = $pad - $left
    Write-Host "  $color$($box.V)$(' ' * $left)$($script:C.BoldWhite)$Text$r$color$(' ' * $right)$($box.V)$r"

    if ($Subtitle) {
        $pad   = $innerWidth - $Subtitle.Length
        $left  = [math]::Floor($pad / 2)
        $right = $pad - $left
        Write-Host "  $color$($box.V)$(' ' * $left)$($script:C.Muted)$Subtitle$r$color$(' ' * $right)$($box.V)$r"
    }

    Write-Host "  $color$($box.V)$(' ' * $innerWidth)$($box.V)$r"
    Write-Host "  $color$($box.BL)$hLine$($box.BR)$r"
}

function Write-FoundryBanner {
    <#
    .SYNOPSIS
        Draws the Video Agents Foundry banner using block characters,
        following the same pattern as the VI CLI banner.
    #>
    param(
        [string]$Phase = ""
    )

    $c = $script:C
    $s = $script:Sym
    $ruleWidth = 45
    $rule = [string]$s.HLine * $ruleWidth

    if (-not $script:AnsiSupported) {
        # Plain fallback
        Write-Host ""
        Write-Host "  $("=" * $ruleWidth)"
        Write-Host "  VIDEO AGENTS"
        Write-Host "  F O U N D R Y   S O L U T I O N"
        if ($Phase) { Write-Host "  $Phase" }
        Write-Host "  $("=" * $ruleWidth)"
        Write-Host ""
        return
    }

    Write-Host ""
    Write-Host "   $($c.AccentBold)██╗ ██╗██╗$($c.Reset)"
    Write-Host "   $($c.AccentBold)██║ ██║██║$($c.Reset)"
    Write-Host "   $($c.AccentBold)╚████╔╝██║$($c.Reset)"
    Write-Host "   $($c.AccentBold) ╚══╝  ╚═╝$($c.Reset)"
    Write-Host "  $($c.Muted)$rule$($c.Reset)"
    Write-Host "  $($c.AccentBold)Video Agents Foundry$($c.Reset)  $($c.Muted)v$($script:FoundryVersion)$($c.Reset)"
    if ($Phase) {
        Write-Host "  $($c.Muted)$Phase$($c.Reset)"
    }
    Write-Host "  $($c.Muted)$rule$($c.Reset)"
    Write-Host ""
}

# ── Structural Helpers ──────────────────────────────────────────────────────

function Write-Title {
    param([string]$Text)
    Write-Host ""
    Write-Host "  $($script:C.BoldWhite)$Text$($script:C.Reset)"
    Write-Host "  $($script:C.AccentDim)$([string]$script:Sym.HLine * ($Text.Length + 4))$($script:C.Reset)"
}

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "  $($script:C.Accent)$($script:Sym.Pointer)$($script:C.Reset)  $($script:C.BoldWhite)$Text$($script:C.Reset)"
}

function Write-KeyValue {
    param(
        [string]$Key,
        [string]$Value,
        [int]$KeyWidth = 24
    )
    $paddedKey = $Key.PadRight($KeyWidth)
    Write-Host "     $($script:C.Muted)$paddedKey$($script:C.Reset) $($script:C.Text)$Value$($script:C.Reset)"
}

function Write-Separator {
    param([int]$Width = 60)
    Write-Host "  $($script:C.Muted)$([string]$script:Sym.HLine * $Width)$($script:C.Reset)"
}

function Write-HealthRow {
    param(
        [string]$Name,
        [ValidateSet("Pass", "Fail", "Warn", "Pending", "Skip")]
        [string]$Status,
        [string]$Detail = ""
    )
    $icon = switch ($Status) {
        "Pass"    { "$($script:C.Success)$($script:Sym.Success)" }
        "Fail"    { "$($script:C.Error)$($script:Sym.Error)" }
        "Warn"    { "$($script:C.Warning)$($script:Sym.Warning)" }
        "Pending" { "$($script:C.Muted)$($script:Sym.Pending)" }
        "Skip"    { "$($script:C.Muted)$($script:Sym.HLine)" }
    }
    $detailText = if ($Detail) { "  $($script:C.Muted)$Detail$($script:C.Reset)" } else { "" }
    $paddedName = $Name.PadRight(30)
    Write-Host "     $icon$($script:C.Reset)  $paddedName$detailText"
}

function Write-SummaryBlock {
    param(
        [int]$Passed,
        [int]$Failed,
        [int]$Warnings,
        [int]$Total
    )
    Write-Host ""
    if ($Failed -eq 0 -and $Warnings -eq 0) {
        Write-BoxBanner -Text "All Checks Passed" -Subtitle "$Passed / $Total" -Style Single -Width 44
    }
    elseif ($Failed -eq 0) {
        Write-BoxBanner -Text "Checks Complete" -Subtitle "$Warnings warning(s)" -Style Single -Width 44
    }
    else {
        Write-BoxBanner -Text "Issues Detected" -Subtitle "$Failed failed, $Warnings warning(s)" -Style Single -Width 44
    }

    Write-Host ""
    Write-Host "     $($script:C.Success)$($script:Sym.Success)$($script:C.Reset)  Passed:   $Passed / $Total"
    if ($Failed -gt 0) {
        Write-Host "     $($script:C.Error)$($script:Sym.Error)$($script:C.Reset)  Failed:   $Failed / $Total"
    }
    if ($Warnings -gt 0) {
        Write-Host "     $($script:C.Warning)$($script:Sym.Warning)$($script:C.Reset)  Warnings: $Warnings / $Total"
    }
    Write-Host ""
}
