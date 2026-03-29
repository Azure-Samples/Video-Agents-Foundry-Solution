#!/usr/bin/env bash
# =============================================================================
# Shared Utilities: Common functions used across all Bash hooks
# =============================================================================
# Source this file via: source "$(dirname "$0")/common.sh"
# This file automatically loads config.sh.

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HOOKS_DIR}/config.sh"

# ── Output Helpers ───────────────────────────────────────────────────────────

write_banner() {
    echo "=============================================="
    echo "$1"
    echo "=============================================="
}

write_step() {
    local step_number="$1"
    local message="$2"
    echo ""
    echo ">> Step ${step_number}: ${message}"
}

# ── Prerequisite Checks ─────────────────────────────────────────────────────

assert_env_vars() {
    # Usage: assert_env_vars VAR1 VAR2 VAR3
    local missing=""
    for var in "$@"; do
        eval val=\$$var 2>/dev/null || val=""
        if [ -z "$val" ]; then
            missing="${missing}  - ${var}\n"
        fi
    done

    if [ -n "$missing" ]; then
        echo "ERROR: The following required environment variables are not set:" >&2
        printf "%b" "$missing" >&2
        echo "Run 'azd env get-values' to check your environment." >&2
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
            local version
            version=$($cmd version --short 2>/dev/null || $cmd version --client --short 2>/dev/null || $cmd --version 2>/dev/null | head -1 || echo "installed")
            echo "   ${cmd}: OK (${version})"
        else
            if [ "$mode" = "required" ]; then
                echo "   ${cmd}: MISSING" >&2
                error_count=$((error_count + 1))
            else
                echo "   ${cmd}: not found (optional, but recommended)"
            fi
        fi
    done

    if [ "$error_count" -gt 0 ]; then
        echo "" >&2
        echo "   ERROR: ${error_count} required tool(s) missing. Install them before proceeding." >&2
        exit 1
    fi
}

# ── Azure Providers ─────────────────────────────────────────────────────────

register_required_providers() {
    # Usage: register_required_providers [provider1 provider2 ...]
    # If no arguments, uses REQUIRED_PROVIDERS from config.sh
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
                echo "   ${provider}: Registered"
                ;;
            Registering)
                echo "   ${provider}: Registering (in progress)"
                providers_registering=$((providers_registering + 1))
                ;;
            NotRegistered|Unregistered)
                echo "   ${provider}: Not registered - registering now..."
                az provider register --namespace "$provider" --wait false 2>/dev/null || true
                providers_registering=$((providers_registering + 1))
                ;;
            *)
                echo "   ${provider}: ${state} (unexpected state)"
                ;;
        esac
    done

    if [ "$providers_registering" -gt 0 ]; then
        echo ""
        echo "   NOTE: ${providers_registering} provider(s) are being registered."
        echo "   Registration can take 2-5 minutes. Provisioning will proceed,"
        echo "   but if it fails, wait a few minutes and retry."
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
# Usage: mapfile -t CPU_VMS < <(get_filtered_vm_sizes "eastus" "Standard_D")
#        mapfile -t GPU_VMS < <(get_filtered_vm_sizes "eastus" "Standard_NC" "Standard_NV" "Standard_ND")
get_filtered_vm_sizes() {
    local location="$1"; shift
    local -a prefixes=("$@")
    # Build JMESPath filter: [?starts_with(name,'P1') || starts_with(name,'P2')]
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

# Looks up quota for a family directly via az CLI (single call).
# Sets globals: VM_QUOTA_LIMIT, VM_QUOTA_USED, VM_QUOTA_AVAILABLE
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

# Looks up quota family for a VM via az vm list-skus.
# Sets global GET_QUOTA_FAMILY_RESULT
GET_QUOTA_FAMILY_RESULT=""
get_quota_family_for_vm() {
    local vm_size="$1" location="$2"
    GET_QUOTA_FAMILY_RESULT=$(az vm list-skus --location "$location" --size "$vm_size" \
        --query "[0].family" -o tsv 2>/dev/null || true)
}

# Checks GPU quota, prints formatted status, sets ASSERT_QUOTA_RESULT.
# Values: "ok", "skip", "zero", "low", "error"
ASSERT_QUOTA_RESULT=""
assert_vm_quota() {
    local label="$1" family="$2" location="$3" cores_needed="$4"
    ASSERT_QUOTA_RESULT=""

    if [ -z "$family" ]; then
        echo "   [${label}] Skipping quota check (no quota family)"
        ASSERT_QUOTA_RESULT="skip"; return 0
    fi

    printf "   [%s] Checking quota for '%s'..." "$label" "$family"

    if ! lookup_vm_quota "$family" "$location"; then
        printf " \033[33mUNKNOWN (family not found)\033[0m\n"
        ASSERT_QUOTA_RESULT="error"; return 1
    fi

    if [ "$VM_QUOTA_LIMIT" -eq 0 ]; then
        printf " \033[31mZERO QUOTA\033[0m\n"
        echo "   [${label}] No quota allocated for '${family}'."
        echo "   Request GPU quota at: ${QUOTA_URL}"
        echo "   For step-by-step instructions, see: ${GPU_QUOTA_DOC_URL}"
        ASSERT_QUOTA_RESULT="zero"; return 1
    fi

    if [ -n "$cores_needed" ] && [ "$cores_needed" -gt 0 ] && [ "$VM_QUOTA_AVAILABLE" -lt "$cores_needed" ]; then
        printf " \033[33mLOW (%s cores free, need %s)\033[0m\n" "$VM_QUOTA_AVAILABLE" "$cores_needed"
        echo "   [${label}] Insufficient — ${VM_QUOTA_AVAILABLE}/${VM_QUOTA_LIMIT} available (${VM_QUOTA_USED} used)"
        echo "   Request quota increase at: ${QUOTA_URL}"
        ASSERT_QUOTA_RESULT="low"; return 1
    fi

    printf " \033[32mOK (%s cores free)\033[0m\n" "$VM_QUOTA_AVAILABLE"
    ASSERT_QUOTA_RESULT="ok"; return 0
}

# ── Interactive VM Selection Menu ─────────────────────────────────────────

# Arrow-key menu. Data is a bash array of "name|cores|memGB" lines (from get_filtered_vm_sizes).
# Usage: show_vm_selection_menu "PoolName" "ENV_VAR" vm_array_name "DefaultSku" "Location" max_nodes "gpu"
# Sets globals: SELECTED_VM_SKU, SELECTED_VM_CORES, SELECTED_VM_FAMILY
SELECTED_VM_SKU=""
SELECTED_VM_CORES=0
SELECTED_VM_FAMILY=""

show_vm_selection_menu() {
    local pool_name="$1"
    local env_var_name="$2"
    local -n _vm_array=$3       # nameref to caller's array
    local default_sku="$4"
    local location="$5"
    local max_nodes="${6:-1}"
    local is_gpu="${7:-}"

    local vm_count=${#_vm_array[@]}
    local item_count=$((vm_count + 1))
    local max_visible=20
    [ "$item_count" -lt "$max_visible" ] && max_visible=$item_count

    if [ "$vm_count" -eq 0 ]; then
        echo "   No VM sizes available for this pool." >&2
        echo "   Provisioning aborted." >&2
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
        echo "   Select VM size for ${pool_name} node pool (${vm_count} sizes available):"
        printf "   Use \xe2\x86\x91/\xe2\x86\x93 to move, Enter to select, C custom, Esc cancel\n"
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
            echo ""; echo "   Selection cancelled by user. Provisioning aborted." >&2; exit 1
        fi

        # Resolve selection
        local selected_sku="" selected_cores=0 selected_family=""
        if [ "$current_index" -eq "$vm_count" ]; then
            echo ""; printf "   Enter VM SKU (e.g. Standard_NC24ads_A100_v4): "; read -r custom_sku
            [ -z "$custom_sku" ] && { echo "   No value entered. Re-showing menu..."; continue; }
            selected_sku="$(echo "$custom_sku" | xargs)"
            for ((i=0; i<vm_count; i++)); do
                [ "${vm_names[$i]}" = "$selected_sku" ] && { selected_cores="${vm_cores[$i]}"; break; }
            done
            [ "$selected_cores" -eq 0 ] && { printf "   \033[31m'%s' not found in region.\033[0m\n" "$selected_sku"; continue; }
        else
            selected_sku="${vm_names[$current_index]}"
            selected_cores="${vm_cores[$current_index]}"
        fi

        printf "   \033[32m%s — %s vCPUs\033[0m\n" "$selected_sku" "$selected_cores"

        # GPU quota check
        if [ "$is_gpu" = "gpu" ]; then
            printf "   Resolving quota family..."
            get_quota_family_for_vm "$selected_sku" "$location"
            selected_family="$GET_QUOTA_FAMILY_RESULT"
            if [ -n "$selected_family" ]; then
                printf " %s\n" "$selected_family"
                local total_cores=$((selected_cores * max_nodes))
                assert_vm_quota "$pool_name" "$selected_family" "$location" "$total_cores"
                if [ "$ASSERT_QUOTA_RESULT" = "zero" ] || [ "$ASSERT_QUOTA_RESULT" = "low" ]; then
                    echo ""; printf "   Continue anyway? (y/n) [n]: "; read -r proceed
                    [ "$proceed" != "y" ] && [ "$proceed" != "Y" ] && { echo "   Re-showing menu..."; continue; }
                fi
            else
                printf " not found (quota check skipped)\n"
            fi
        fi

        azd env set "$env_var_name" "$selected_sku" 2>/dev/null || \
            echo "   Warning: Could not persist ${env_var_name} via 'azd env set'."

        printf "   \033[32mSelected: %s\033[0m\n\n" "$selected_sku"
        SELECTED_VM_SKU="$selected_sku"
        SELECTED_VM_CORES="$selected_cores"
        SELECTED_VM_FAMILY="$selected_family"
        return 0
    done
}
