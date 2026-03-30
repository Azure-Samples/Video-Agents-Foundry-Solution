#!/usr/bin/env bash
# =============================================================================
# UI Module: ANSI colors, symbols, logging, spinners, and banners (Bash)
# =============================================================================
# Adapted from the PowerShell ui.ps1 / VideoIndexer-CLI styling patterns.
# Source this file via common.sh (which sources config.sh first).

# ── ANSI Support Detection ──────────────────────────────────────────────────

_test_ansi_support() {
    # Most modern terminals support ANSI; check common indicators
    [ -n "${WT_SESSION:-}" ] && return 0       # Windows Terminal
    [ "${TERM_PROGRAM:-}" = "vscode" ] && return 0
    [ "${COLORTERM:-}" = "truecolor" ] && return 0
    [ "${COLORTERM:-}" = "24bit" ] && return 0
    case "${TERM:-}" in
        xterm*|screen*|tmux*|rxvt*|linux|alacritty) return 0 ;;
    esac
    # If stdout is a terminal, assume ANSI support
    [ -t 1 ] && return 0
    return 1
}

if _test_ansi_support; then
    ANSI_SUPPORTED=true
else
    ANSI_SUPPORTED=false
fi

# ── Color Constants ─────────────────────────────────────────────────────────

if [ "$ANSI_SUPPORTED" = true ]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'

    C_ACCENT='\033[36m'
    C_ACCENT_BOLD='\033[1;36m'
    C_ACCENT_DIM='\033[2;36m'
    C_SUCCESS='\033[32m'
    C_ERROR='\033[91m'
    C_WARNING='\033[33m'
    C_INFO='\033[37m'
    C_MUTED='\033[90m'
    C_TEXT='\033[37m'
    C_BOLD_WHITE='\033[1;97m'
else
    C_RESET='' C_BOLD='' C_DIM=''
    C_ACCENT='' C_ACCENT_BOLD='' C_ACCENT_DIM=''
    C_SUCCESS='' C_ERROR='' C_WARNING=''
    C_INFO='' C_MUTED='' C_TEXT='' C_BOLD_WHITE=''
fi

# ── Symbol Constants ────────────────────────────────────────────────────────

if [ "$ANSI_SUPPORTED" = true ]; then
    SYM_SUCCESS="✔"
    SYM_ERROR="✘"
    SYM_WARNING="⚠"
    SYM_INFO="•"
    SYM_PENDING="○"
    SYM_POINTER="❯"
    SYM_ARROW="→"
    SYM_HLINE="─"
    SYM_STEP="▶"

    BOX_D_TL="╔" BOX_D_TR="╗" BOX_D_BL="╚" BOX_D_BR="╝" BOX_D_H="═" BOX_D_V="║"
    BOX_S_TL="┌" BOX_S_TR="┐" BOX_S_BL="└" BOX_S_BR="┘" BOX_S_H="─" BOX_S_V="│"
else
    SYM_SUCCESS="+" SYM_ERROR="x" SYM_WARNING="!" SYM_INFO="*"
    SYM_PENDING="o" SYM_POINTER=">" SYM_ARROW="->" SYM_HLINE="-" SYM_STEP=">"

    BOX_D_TL="+" BOX_D_TR="+" BOX_D_BL="+" BOX_D_BR="+" BOX_D_H="=" BOX_D_V="|"
    BOX_S_TL="+" BOX_S_TR="+" BOX_S_BL="+" BOX_S_BR="+" BOX_S_H="-" BOX_S_V="|"
fi

# ── Core Logging ────────────────────────────────────────────────────────────

_write_log_message() {
    local message="$1"
    local symbol="${2:-}"
    local symbol_color="${3:-$C_INFO}"
    local message_color="${4:-$C_TEXT}"
    local no_timestamp="${5:-false}"
    local no_newline="${6:-false}"

    local ts=""
    if [ "$no_timestamp" = false ]; then
        ts="${C_MUTED}$(date +%H:%M:%S)${C_RESET}  "
    else
        ts="  "
    fi

    local sym_part=""
    if [ -n "$symbol" ]; then
        sym_part="${symbol_color}${symbol}${C_RESET}  "
    else
        sym_part="   "
    fi

    if [ "$no_newline" = true ]; then
        printf "  %b%b%b%s%b" "$ts" "$sym_part" "$message_color" "$message" "$C_RESET"
    else
        printf "  %b%b%b%s%b\n" "$ts" "$sym_part" "$message_color" "$message" "$C_RESET"
    fi
}

log_info() {
    _write_log_message "$1" "$SYM_INFO" "$C_ACCENT"
}

log_success() {
    _write_log_message "$1" "$SYM_SUCCESS" "$C_SUCCESS" "$C_SUCCESS"
}

log_error() {
    _write_log_message "$1" "$SYM_ERROR" "$C_ERROR" "$C_ERROR"
}

log_warning() {
    _write_log_message "$1" "$SYM_WARNING" "$C_WARNING" "$C_WARNING"
}

log_step() {
    local number="$1"
    local total="$2"
    local title="$3"

    local rule=""
    for ((i=0; i<60; i++)); do rule="${rule}${SYM_HLINE}"; done

    printf "\n  %b%s%b  %b[%s/%s]%b  %b%s%b\n" \
        "$C_ACCENT_BOLD" "$SYM_STEP" "$C_RESET" \
        "$C_MUTED" "$number" "$total" "$C_RESET" \
        "$C_BOLD_WHITE" "$title" "$C_RESET"
    printf "  %b%s%b\n" "$C_MUTED" "$rule" "$C_RESET"
}

# ── Banner & Box Drawing ───────────────────────────────────────────────────

_repeat_char() {
    local char="$1" count="$2" result=""
    for ((i=0; i<count; i++)); do result="${result}${char}"; done
    printf "%s" "$result"
}

write_box_banner() {
    local text="$1"
    local subtitle="${2:-}"
    local style="${3:-Double}"
    local width="${4:-64}"

    local tl tr bl br h v color
    if [ "$style" = "Double" ]; then
        tl="$BOX_D_TL" tr="$BOX_D_TR" bl="$BOX_D_BL" br="$BOX_D_BR" h="$BOX_D_H" v="$BOX_D_V"
        color="$C_ACCENT_BOLD"
    else
        tl="$BOX_S_TL" tr="$BOX_S_TR" bl="$BOX_S_BL" br="$BOX_S_BR" h="$BOX_S_H" v="$BOX_S_V"
        color="$C_ACCENT"
    fi

    local inner_width=$((width - 2))
    local h_line; h_line=$(_repeat_char "$h" "$inner_width")
    local spaces; spaces=$(_repeat_char " " "$inner_width")

    # Centered title
    local text_len=${#text}
    local left_pad=$(( (inner_width - text_len) / 2 ))
    local right_pad=$(( inner_width - text_len - left_pad ))
    local left_spaces; left_spaces=$(_repeat_char " " "$left_pad")
    local right_spaces; right_spaces=$(_repeat_char " " "$right_pad")

    printf "  %b%s%s%s%b\n" "$color" "$tl" "$h_line" "$tr" "$C_RESET"
    printf "  %b%s%s%s%b\n" "$color" "$v" "$spaces" "$v" "$C_RESET"
    printf "  %b%s%b%s%b%s%b%b%s%b%s%b\n" "$color" "$v" "$C_RESET" \
        "$left_spaces" "$C_BOLD_WHITE" "$text" "$C_RESET" \
        "$color" "$right_spaces" "$v" "$C_RESET"

    if [ -n "$subtitle" ]; then
        local sub_len=${#subtitle}
        local sub_left=$(( (inner_width - sub_len) / 2 ))
        local sub_right=$(( inner_width - sub_len - sub_left ))
        local sub_left_sp; sub_left_sp=$(_repeat_char " " "$sub_left")
        local sub_right_sp; sub_right_sp=$(_repeat_char " " "$sub_right")
        printf "  %b%s%b%s%b%s%b%b%s%s%b\n" "$color" "$v" "$C_RESET" \
            "$sub_left_sp" "$C_MUTED" "$subtitle" "$C_RESET" \
            "$color" "$sub_right_sp" "$v" "$C_RESET"
    fi

    printf "  %b%s%s%s%b\n" "$color" "$v" "$spaces" "$v" "$C_RESET"
    printf "  %b%s%s%s%b\n" "$color" "$bl" "$h_line" "$br" "$C_RESET"
}

write_foundry_banner() {
    local phase="${1:-}"
    local rule_width=45
    local rule; rule=$(_repeat_char "$SYM_HLINE" "$rule_width")

    if [ "$ANSI_SUPPORTED" != true ]; then
        local border; border=$(_repeat_char "=" "$rule_width")
        echo ""
        echo "  $border"
        echo "  VIDEO AGENTS"
        echo "  FOUNDRY SOLUTION"
        [ -n "$phase" ] && echo "  $phase"
        echo "  $border"
        echo ""
        return
    fi

    printf "\n"
    printf "   %b██╗ ██╗██╗%b\n" "$C_ACCENT_BOLD" "$C_RESET"
    printf "   %b██║ ██║██║%b\n" "$C_ACCENT_BOLD" "$C_RESET"
    printf "   %b╚████╔╝██║%b\n" "$C_ACCENT_BOLD" "$C_RESET"
    printf "   %b ╚══╝  ╚═╝%b\n" "$C_ACCENT_BOLD" "$C_RESET"
    printf "  %b%s%b\n" "$C_MUTED" "$rule" "$C_RESET"
    printf "  %bVideo Agents Foundry%b  %bv%s%b\n" "$C_ACCENT_BOLD" "$C_RESET" "$C_MUTED" "$FOUNDRY_VERSION" "$C_RESET"
    if [ -n "$phase" ]; then
        printf "  %b%s%b\n" "$C_MUTED" "$phase" "$C_RESET"
    fi
    printf "  %b%s%b\n" "$C_MUTED" "$rule" "$C_RESET"
    printf "\n"
}

# ── Structural Helpers ──────────────────────────────────────────────────────

write_title() {
    local text="$1"
    local text_len=${#text}
    local rule; rule=$(_repeat_char "$SYM_HLINE" "$((text_len + 4))")
    printf "\n  %b%s%b\n" "$C_BOLD_WHITE" "$text" "$C_RESET"
    printf "  %b%s%b\n" "$C_ACCENT_DIM" "$rule" "$C_RESET"
}

write_section() {
    local text="$1"
    printf "\n  %b%s%b  %b%s%b\n" "$C_ACCENT" "$SYM_POINTER" "$C_RESET" "$C_BOLD_WHITE" "$text" "$C_RESET"
}

write_key_value() {
    local key="$1"
    local value="$2"
    local key_width="${3:-24}"
    printf "     %b%-${key_width}s%b %b%s%b\n" "$C_MUTED" "$key" "$C_RESET" "$C_TEXT" "$value" "$C_RESET"
}

write_separator() {
    local width="${1:-60}"
    local rule; rule=$(_repeat_char "$SYM_HLINE" "$width")
    printf "  %b%s%b\n" "$C_MUTED" "$rule" "$C_RESET"
}

write_health_row() {
    local name="$1"
    local status="$2"
    local detail="${3:-}"

    local icon
    case "$status" in
        Pass)    icon="${C_SUCCESS}${SYM_SUCCESS}" ;;
        Fail)    icon="${C_ERROR}${SYM_ERROR}" ;;
        Warn)    icon="${C_WARNING}${SYM_WARNING}" ;;
        Pending) icon="${C_MUTED}${SYM_PENDING}" ;;
        Skip)    icon="${C_MUTED}${SYM_HLINE}" ;;
    esac

    local detail_text=""
    [ -n "$detail" ] && detail_text="  ${C_MUTED}${detail}${C_RESET}"

    printf "     %b%b  %-30s%b\n" "$icon" "$C_RESET" "$name" "$detail_text"
}

write_summary_block() {
    local passed="$1"
    local failed="$2"
    local warnings="$3"
    local total="$4"

    echo ""
    if [ "$failed" -eq 0 ] && [ "$warnings" -eq 0 ]; then
        write_box_banner "All Checks Passed" "$passed / $total" "Single" 44
    elif [ "$failed" -eq 0 ]; then
        write_box_banner "Checks Complete" "$warnings warning(s)" "Single" 44
    else
        write_box_banner "Issues Detected" "$failed failed, $warnings warning(s)" "Single" 44
    fi

    echo ""
    printf "     %b%s%b  Passed:   %s / %s\n" "$C_SUCCESS" "$SYM_SUCCESS" "$C_RESET" "$passed" "$total"
    if [ "$failed" -gt 0 ]; then
        printf "     %b%s%b  Failed:   %s / %s\n" "$C_ERROR" "$SYM_ERROR" "$C_RESET" "$failed" "$total"
    fi
    if [ "$warnings" -gt 0 ]; then
        printf "     %b%s%b  Warnings: %s / %s\n" "$C_WARNING" "$SYM_WARNING" "$C_RESET" "$warnings" "$total"
    fi
    echo ""
}
