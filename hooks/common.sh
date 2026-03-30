#!/usr/bin/env bash
# =============================================================================
# Shared Utilities: Common functions used across all Bash hooks
# =============================================================================
# Source this file via: source "$(dirname "$0")/common.sh"
# This file automatically loads config.sh and ui.sh.

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HOOKS_DIR}/config.sh"
source "${HOOKS_DIR}/ui.sh"

# ── Prerequisite Checks ─────────────────────────────────────────────────────

assert_env_vars() {
    # Usage: assert_env_vars VAR1 VAR2 VAR3
    local missing=()
    for var in "$@"; do
        eval val=\$$var 2>/dev/null || val=""
        if [ -z "$val" ]; then
            missing+=("$var")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required environment variables:"
        for var in "${missing[@]}"; do
            printf "     %b%s%b  %s\n" "$C_ERROR" "$SYM_ERROR" "$C_RESET" "$var"
        done
        echo ""
        log_info "Run 'azd env get-values' to check your environment."
        exit 1
    fi
}

assert_cli_tools() {
    # Usage: assert_cli_tools required_tool1 required_tool2 -- optional_tool1 optional_tool2
    local mode="required"
    local error_count=0

    for cmd in "$@"; do
        if [ "$cmd" = "--" ]; then
            mode="optional"
            continue
        fi

        if command -v "$cmd" >/dev/null 2>&1; then
            log_success "$cmd"
        else
            if [ "$mode" = "required" ]; then
                log_error "$cmd - not found"
                error_count=$((error_count + 1))
            else
                log_warning "$cmd - not found (optional)"
            fi
        fi
    done

    if [ "$error_count" -gt 0 ]; then
        echo ""
        log_error "${error_count} required tool(s) missing. Install them before proceeding."
        exit 1
    fi
}

# ── Azure Providers ─────────────────────────────────────────────────────────

register_required_providers() {
    # Usage: register_required_providers [provider1 provider2 ...]
    local providers=("${@:-${REQUIRED_PROVIDERS[@]}}")
    if [ ${#providers[@]} -eq 0 ]; then
        providers=("${REQUIRED_PROVIDERS[@]}")
    fi

    local providers_registering=0
    for provider in "${providers[@]}"; do
        local state
        state=$(az provider show -n "$provider" --query "registrationState" -o tsv 2>/dev/null || echo "Unknown")
        case "$state" in
            Registered)
                log_success "$provider"
                ;;
            Registering)
                log_warning "$provider (registration in progress)"
                providers_registering=$((providers_registering + 1))
                ;;
            NotRegistered|Unregistered)
                run_with_spinner "Registering $provider" "$provider registered" \
                    az provider register --namespace "$provider" --wait false
                providers_registering=$((providers_registering + 1))
                ;;
            *)
                log_warning "$provider ($state)"
                ;;
        esac
    done

    if [ "$providers_registering" -gt 0 ]; then
        echo ""
        log_warning "${providers_registering} provider(s) are being registered."
        log_info "Registration can take 2-5 minutes. Provisioning will proceed,"
        log_info "but if it fails, wait a few minutes and retry."
    fi

    return "$providers_registering"
}

# ── AKS Credentials ────────────────────────────────────────────────────────

connect_aks_cluster() {
    # Usage: KUBE_CONTEXT=$(connect_aks_cluster [resource_group] [cluster_name])
    local resource_group="${1:-$AZURE_RESOURCE_GROUP}"
    local cluster_name="${2:-$AZURE_AKS_CLUSTER_NAME}"
    local kube_context="${cluster_name}-admin"

    az aks get-credentials \
        --resource-group "$resource_group" \
        --name "$cluster_name" \
        --admin \
        --overwrite-existing 2>/dev/null

    echo "$kube_context"
}

# ── Kubernetes Helpers ──────────────────────────────────────────────────────

get_running_pod_count() {
    # Usage: count=$(get_running_pod_count namespace kube_context)
    local namespace="$1"
    local kube_context="$2"
    kubectl --context "$kube_context" get pods -n "$namespace" \
        --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' '
}

get_total_pod_count() {
    # Usage: count=$(get_total_pod_count namespace kube_context)
    local namespace="$1"
    local kube_context="$2"
    kubectl --context "$kube_context" get pods -n "$namespace" \
        --no-headers 2>/dev/null | wc -l | tr -d ' '
}

test_namespace_exists() {
    # Usage: if test_namespace_exists namespace kube_context; then ...
    local namespace="$1"
    local kube_context="$2"
    kubectl --context "$kube_context" get namespace "$namespace" --no-headers 2>/dev/null | grep -q .
}

# ── Azure VM Data (pure az CLI + bash, no python) ────────────────────────

# Fetches VM sizes for a region, filtered by name prefixes, sorted by cores.
# Output: pipe-delimited lines "name|cores|memGB" to stdout.
get_filtered_vm_sizes() {
    local location="$1"; shift
    local -a prefixes=("$@")
    local filter=""
    for p in "${prefixes[@]}"; do
        [ -n "$filter" ] && filter="${filter} || "
        filter="${filter}starts_with(name, '${p}')"
    done
    az vm list-sizes --location "$location" \
        --query "sort_by([?${filter}], &numberOfCores)[].{n:name, c:numberOfCores, m:memoryInMB}" \
        -o tsv 2>/dev/null | while IFS=$'\t' read -r name cores memMB; do
        echo "${name}|${cores}|$((memMB / 1024))"
    done
}

# Picks VM sizes for the menu based on recommended families.
select_vm_sizes_for_menu() {
    local -n _src=$1
    local -n _out=$2
    local -n _families=$3
    local default_sku="$4"
    local per_family="${5:-3}"
    local min_cores="${6:-0}"
    local max_cores="${7:-999999}"

    _out=()
    local -A seen

    for pattern in "${_families[@]}"; do
        local count=0
        for entry in "${_src[@]}"; do
            local sku="${entry%%|*}"
            local rest="${entry#*|}"
            local cores="${rest%%|*}"
            [ "$cores" -lt "$min_cores" ] && continue
            [ "$cores" -gt "$max_cores" ] && continue
            if echo "$sku" | grep -qE "$pattern"; then
                if [ -z "${seen[$sku]+x}" ]; then
                    seen[$sku]=1
                    _out+=("$entry")
                    count=$((count + 1))
                    [ "$count" -ge "$per_family" ] && break
                fi
            fi
        done
    done

    # Ensure default SKU is included
    if [ -n "$default_sku" ] && [ -z "${seen[$default_sku]+x}" ]; then
        for entry in "${_src[@]}"; do
            local sku="${entry%%|*}"
            [ "$sku" = "$default_sku" ] && { _out+=("$entry"); break; }
        done
    fi

    # Sort output by cores
    local -a sorted
    mapfile -t sorted < <(printf '%s\n' "${_out[@]}" | sort -t'|' -k2 -n)
    _out=("${sorted[@]}")
}

# Looks up quota for a family directly via az CLI (single call).
VM_QUOTA_LIMIT=0
VM_QUOTA_USED=0
VM_QUOTA_AVAILABLE=0
lookup_vm_quota() {
    local family="$1" location="$2"
    VM_QUOTA_LIMIT=0; VM_QUOTA_USED=0; VM_QUOTA_AVAILABLE=0
    [ -z "$family" ] && return 1
    local raw
    raw=$(az vm list-usage --location "$location" \
        --query "[?name.value=='${family}'] | [0].{l:limit, u:currentValue}" \
        -o tsv 2>/dev/null || true)
    [ -z "$raw" ] && return 1
    VM_QUOTA_LIMIT=$(echo "$raw" | cut -f1)
    VM_QUOTA_USED=$(echo "$raw" | cut -f2)
    VM_QUOTA_AVAILABLE=$((VM_QUOTA_LIMIT - VM_QUOTA_USED))
    return 0
}

# Resolves quota family for a GPU VM using the pattern lookup table.
GET_QUOTA_FAMILY_RESULT=""
get_quota_family_for_vm() {
    local vm_size="$1"
    GET_QUOTA_FAMILY_RESULT=""
    for ((i=0; i<${#GPU_QUOTA_PATTERNS[@]}; i++)); do
        if echo "$vm_size" | grep -qE "${GPU_QUOTA_PATTERNS[$i]}"; then
            GET_QUOTA_FAMILY_RESULT="${GPU_QUOTA_FAMILIES[$i]}"
            return 0
        fi
    done
    return 1
}

# Checks GPU quota, prints formatted status, sets ASSERT_QUOTA_RESULT.
ASSERT_QUOTA_RESULT=""
assert_vm_quota() {
    local label="$1" family="$2" location="$3" cores_needed="$4"
    ASSERT_QUOTA_RESULT=""

    if [ -z "$family" ]; then
        log_warning "[$label] Skipping quota check (no quota family)"
        ASSERT_QUOTA_RESULT="skip"; return 0
    fi

    _write_log_message "[$label] Checking quota for '$family'..." "$SYM_INFO" "$C_ACCENT" "$C_TEXT" false true

    if ! lookup_vm_quota "$family" "$location"; then
        printf " %bUNKNOWN (family not found)%b\n" "$C_WARNING" "$C_RESET"
        ASSERT_QUOTA_RESULT="error"; return 1
    fi

    if [ "$VM_QUOTA_LIMIT" -eq 0 ]; then
        echo ""
        log_error "[$label] No quota allocated for '$family'."
        log_info "Request GPU quota at: $QUOTA_URL"
        log_info "For step-by-step instructions, see: $GPU_QUOTA_DOC_URL"
        ASSERT_QUOTA_RESULT="zero"; return 1
    fi

    if [ -n "$cores_needed" ] && [ "$cores_needed" -gt 0 ] && [ "$VM_QUOTA_AVAILABLE" -lt "$cores_needed" ]; then
        echo ""
        log_warning "[$label] Insufficient: ${VM_QUOTA_AVAILABLE}/${VM_QUOTA_LIMIT} available (${VM_QUOTA_USED} used), need $cores_needed"
        log_info "Request quota increase at: $QUOTA_URL"
        ASSERT_QUOTA_RESULT="low"; return 1
    fi

    printf " %bOK (%s cores free)%b\n" "$C_SUCCESS" "$VM_QUOTA_AVAILABLE" "$C_RESET"
    ASSERT_QUOTA_RESULT="ok"; return 0
}

# ── Interactive VM Selection Menu ─────────────────────────────────────────
# NOTE: This function uses low-level terminal manipulation for interactive
# arrow-key menus. Its internal styling is intentionally left as-is.

SELECTED_VM_SKU=""
SELECTED_VM_CORES=0
SELECTED_VM_FAMILY=""

show_vm_selection_menu() {
    local pool_name="$1"
    local env_var_name="$2"
    local -n _vm_array=$3
    local default_sku="$4"
    local location="$5"
    local max_nodes="${6:-1}"
    local is_gpu="${7:-}"

    local vm_count=${#_vm_array[@]}
    local item_count=$((vm_count + 1))
    local max_visible=20
    [ "$item_count" -lt "$max_visible" ] && max_visible=$item_count

    if [ "$vm_count" -eq 0 ]; then
        log_error "No VM sizes available for this pool."
        log_error "Provisioning aborted."
        exit 1
    fi

    # Parse into parallel arrays for fast indexed access
    local -a vm_names vm_cores vm_mem
    for entry in "${_vm_array[@]}"; do
        vm_names+=("${entry%%|*}")
        local rest="${entry#*|}"
        vm_cores+=("${rest%%|*}")
        vm_mem+=("${rest#*|}")
    done

    # Find default index, set initial scroll
    local current_index=0 scroll_offset=0
    for ((i=0; i<vm_count; i++)); do
        [ "${vm_names[$i]}" = "$default_sku" ] && { current_index=$i; break; }
    done
    scroll_offset=$((current_index - max_visible / 2))
    [ "$scroll_offset" -lt 0 ] && scroll_offset=0
    local max_scroll=$((item_count - max_visible))
    [ "$max_scroll" -lt 0 ] && max_scroll=0
    [ "$scroll_offset" -gt "$max_scroll" ] && scroll_offset=$max_scroll

    _update_scroll() {
        [ "$current_index" -lt "$scroll_offset" ] && scroll_offset=$current_index
        [ "$current_index" -ge $((scroll_offset + max_visible)) ] && scroll_offset=$((current_index - max_visible + 1))
        [ "$scroll_offset" -lt 0 ] && scroll_offset=0
        [ "$scroll_offset" -gt "$max_scroll" ] && scroll_offset=$max_scroll
    }

    _render_menu() {
        local selected=$1 top=$2 offset=$3
        printf "\033[%d;1H" "$top"
        for ((row=0; row<max_visible; row++)); do
            local idx=$((offset + row))
            if [ "$idx" -eq "$vm_count" ]; then
                [ "$idx" -eq "$selected" ] \
                    && printf "\033[K \033[30;46m > Enter custom VM size... \033[0m\n" \
                    || printf "\033[K    Enter custom VM size...\n"
            elif [ "$idx" -lt "$vm_count" ]; then
                local is_def="0"
                [ "${vm_names[$idx]}" = "$default_sku" ] && is_def="1"
                local text tag=""
                [ "$is_def" = "1" ] && tag=" (default)"
                text=$(printf "%-35s %-10s %-8s%s" "${vm_names[$idx]}" "${vm_cores[$idx]} vCPUs" "${vm_mem[$idx]} GB" "$tag")
                if [ "$idx" -eq "$selected" ]; then
                    printf "\033[K \033[30;46m > %s \033[0m\n" "$text"
                elif [ "$is_def" = "1" ]; then
                    printf "\033[K \033[36m   %s \033[0m\n" "$text"
                else
                    printf "\033[K    %s\n" "$text"
                fi
            else
                printf "\033[K\n"
            fi
        done
    }

    while true; do
        echo ""
        write_section "Select VM size for ${pool_name} (${vm_count} sizes available)"
        log_info "Use ↑/↓ to move, Enter to select, C custom, Esc cancel"
        echo ""

        # Get cursor row via ANSI DSR
        local cursor_row
        if [ -t 0 ]; then
            local old_stty; old_stty=$(stty -g)
            stty raw -echo min 0
            printf "\033[6n" > /dev/tty
            local response=""
            while true; do
                local ch; ch=$(dd bs=1 count=1 2>/dev/null)
                response="${response}${ch}"
                case "$response" in *R) break ;; esac
            done
            stty "$old_stty"
            cursor_row=$(echo "$response" | sed 's/.*\[//;s/;.*//')
        else
            cursor_row=10
        fi

        # Reserve viewport lines
        for ((r=0; r<max_visible; r++)); do echo ""; done
        local menu_top=$cursor_row

        _update_scroll
        _render_menu "$current_index" "$menu_top" "$scroll_offset"

        local confirmed=false escaped=false
        while [ "$confirmed" = false ] && [ "$escaped" = false ]; do
            local key; IFS= read -rsn1 key
            if [ "$key" = $'\x1b' ]; then
                local seq=""; IFS= read -rsn1 -t 0.1 seq
                if [ -z "$seq" ]; then escaped=true
                elif [ "$seq" = "[" ]; then
                    local arrow; IFS= read -rsn1 arrow
                    case "$arrow" in
                        A) [ "$current_index" -gt 0 ] && current_index=$((current_index - 1)); _update_scroll; _render_menu "$current_index" "$menu_top" "$scroll_offset" ;;
                        B) [ "$current_index" -lt $((item_count - 1)) ] && current_index=$((current_index + 1)); _update_scroll; _render_menu "$current_index" "$menu_top" "$scroll_offset" ;;
                    esac
                fi
            elif [ "$key" = "" ]; then confirmed=true
            elif [ "$key" = "c" ] || [ "$key" = "C" ]; then
                current_index=$vm_count; _update_scroll; _render_menu "$current_index" "$menu_top" "$scroll_offset"
            fi
        done

        printf "\033[%d;1H" "$((menu_top + max_visible))"

        if [ "$escaped" = true ]; then
            echo ""
            log_error "Selection cancelled by user. Provisioning aborted."
            exit 1
        fi

        # Resolve selection
        local selected_sku="" selected_cores=0 selected_family=""
        if [ "$current_index" -eq "$vm_count" ]; then
            echo ""; printf "   Enter VM SKU (e.g. Standard_NC24ads_A100_v4): "; read -r custom_sku
            [ -z "$custom_sku" ] && { log_warning "No value entered. Re-showing menu..."; continue; }
            selected_sku="$(echo "$custom_sku" | xargs)"
            for ((i=0; i<vm_count; i++)); do
                [ "${vm_names[$i]}" = "$selected_sku" ] && { selected_cores="${vm_cores[$i]}"; break; }
            done
            [ "$selected_cores" -eq 0 ] && { log_error "'$selected_sku' not found in region."; continue; }
        else
            selected_sku="${vm_names[$current_index]}"
            selected_cores="${vm_cores[$current_index]}"
        fi

        log_success "${selected_sku} (${selected_cores} vCPUs)"

        # GPU quota check
        if [ "$is_gpu" = "gpu" ]; then
            _write_log_message "Resolving quota family..." "$SYM_INFO" "$C_ACCENT" "$C_TEXT" false true
            get_quota_family_for_vm "$selected_sku" "$location"
            selected_family="$GET_QUOTA_FAMILY_RESULT"
            if [ -n "$selected_family" ]; then
                printf " %b%s%b\n" "$C_MUTED" "$selected_family" "$C_RESET"
                local total_cores=$((selected_cores * max_nodes))
                assert_vm_quota "$pool_name" "$selected_family" "$location" "$total_cores"
                if [ "$ASSERT_QUOTA_RESULT" = "zero" ] || [ "$ASSERT_QUOTA_RESULT" = "low" ]; then
                    echo ""; printf "   Continue anyway? (y/n) [n]: "; read -r proceed
                    [ "$proceed" != "y" ] && [ "$proceed" != "Y" ] && { log_warning "Re-showing menu..."; continue; }
                fi
            else
                printf " %bnot found (quota check skipped)%b\n" "$C_WARNING" "$C_RESET"
            fi
        fi

        azd env set "$env_var_name" "$selected_sku" 2>/dev/null || \
            log_warning "Could not persist ${env_var_name} via 'azd env set'."

        log_success "Selected: $selected_sku"
        echo ""
        SELECTED_VM_SKU="$selected_sku"
        SELECTED_VM_CORES="$selected_cores"
        SELECTED_VM_FAMILY="$selected_family"
        return 0
    done
}
