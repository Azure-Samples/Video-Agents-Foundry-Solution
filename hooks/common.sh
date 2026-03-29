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

# ── VM Size Availability ──────────────────────────────────────────────────

# Usage: if test_vm_availability "Standard_D4a_v4" "eastus2"; then ...
# Sets global VM_AVAIL_CORES on success
VM_AVAIL_CORES=0
test_vm_availability() {
    local vm_size="$1"
    local location="$2"
    local vm_info
    vm_info=$(az vm list-sizes --location "$location" \
        --query "[?name=='${vm_size}'] | [0]" -o json 2>/dev/null || true)

    if [ -z "$vm_info" ] || [ "$vm_info" = "null" ]; then
        VM_AVAIL_CORES=0
        return 1
    fi

    VM_AVAIL_CORES=$(echo "$vm_info" | grep -o '"numberOfCores":[0-9]*' | grep -o '[0-9]*')
    return 0
}

# Usage: if test_vm_quota "StandardNCADSA100v4Family" "eastus"; then ...
# Sets globals: VM_QUOTA_LIMIT, VM_QUOTA_USED, VM_QUOTA_AVAILABLE
VM_QUOTA_LIMIT=0
VM_QUOTA_USED=0
VM_QUOTA_AVAILABLE=0
test_vm_quota() {
    local family="$1"
    local location="$2"
    VM_QUOTA_LIMIT=0; VM_QUOTA_USED=0; VM_QUOTA_AVAILABLE=0
    [ -z "$family" ] && return 1
    local raw
    local lower_family
    lower_family=$(echo "$family" | tr '[:upper:]' '[:lower:]')
    raw=$(az vm list-usage --location "$location" \
        --query "[?to_lower(name.value)=='${lower_family}'] | [0]" -o json 2>/dev/null || true)
    if [ -z "$raw" ] || [ "$raw" = "null" ]; then
        return 1
    fi
    VM_QUOTA_LIMIT=$(echo "$raw" | grep -o '"limit":[0-9]*' | grep -o '[0-9]*' || echo "0")
    VM_QUOTA_USED=$(echo "$raw" | grep -o '"currentValue":[0-9]*' | grep -o '[0-9]*' || echo "0")
    VM_QUOTA_AVAILABLE=$((VM_QUOTA_LIMIT - VM_QUOTA_USED))
    return 0
}

# Checks GPU quota for a pool, prints formatted status, sets ASSERT_QUOTA_RESULT.
# Values: "ok", "skip", "zero", "low", "error"
# Args: label family location cores_needed
ASSERT_QUOTA_RESULT=""
assert_vm_quota() {
    local label="$1" family="$2" location="$3" cores_needed="$4"
    ASSERT_QUOTA_RESULT=""

    if [ -z "$family" ]; then
        echo "   [${label}] Skipping quota check (no quota family)"
        ASSERT_QUOTA_RESULT="skip"
        return 0
    fi

    printf "   [%s] Checking quota for '%s'..." "$label" "$family"

    if ! test_vm_quota "$family" "$location"; then
        printf " \033[33mUNKNOWN (query failed)\033[0m\n"
        ASSERT_QUOTA_RESULT="error"
        return 1
    fi

    if [ "$VM_QUOTA_LIMIT" -eq 0 ]; then
        printf " \033[31mZERO QUOTA\033[0m\n"
        echo "   [${label}] No quota allocated for '${family}' in '${location}'."
        echo "   Request GPU quota at: ${QUOTA_URL}"
        echo "   For step-by-step instructions, see: ${GPU_QUOTA_DOC_URL}"
        ASSERT_QUOTA_RESULT="zero"
        return 1
    fi

    if [ -n "$cores_needed" ] && [ "$cores_needed" -gt 0 ] && [ "$VM_QUOTA_AVAILABLE" -lt "$cores_needed" ]; then
        printf " \033[33mLOW (%s cores free, need %s)\033[0m\n" "$VM_QUOTA_AVAILABLE" "$cores_needed"
        echo "   [${label}] Insufficient quota — ${VM_QUOTA_AVAILABLE}/${VM_QUOTA_LIMIT} available (${VM_QUOTA_USED} used)"
        echo "   Request quota increase at: ${QUOTA_URL}"
        echo "   For step-by-step instructions, see: ${GPU_QUOTA_DOC_URL}"
        ASSERT_QUOTA_RESULT="low"
        return 1
    fi

    printf " \033[32mOK (%s cores free)\033[0m\n" "$VM_QUOTA_AVAILABLE"
    ASSERT_QUOTA_RESULT="ok"
    return 0
}

# ── Interactive VM Selection Menu ─────────────────────────────────────────

# Arrow-key driven interactive menu for selecting a VM size.
# Up/Down to move, Enter to select, C for custom, Esc to re-draw.
#
# Usage: show_vm_selection_menu "PoolName" "ENV_VAR_NAME" "cpu|gpu" "DefaultSku" "Location"
# Sets globals: SELECTED_VM_SKU, SELECTED_VM_CORES, SELECTED_VM_FAMILY
SELECTED_VM_SKU=""
SELECTED_VM_CORES=0
SELECTED_VM_FAMILY=""

# Format a single catalog line for display
# Args: catalog_type sku cores ram desc [gpu]
_format_vm_line() {
    local ctype="$1" sku="$2" cores="$3" ram="$4" desc="$5" gpu="$6" is_default="$7"
    local tag=""
    [ "$is_default" = "1" ] && tag=" (default)"
    if [ "$ctype" = "gpu" ]; then
        printf "%-30s %-10s %-8s %-16s %s%s" "$sku" "${cores} cores" "$ram" "$gpu" "$desc" "$tag"
    else
        printf "%-30s %-10s %-8s %s%s" "$sku" "${cores} cores" "$ram" "$desc" "$tag"
    fi
}

show_vm_selection_menu() {
    local pool_name="$1"
    local env_var_name="$2"
    local catalog_type="$3"    # "cpu" or "gpu"
    local default_sku="$4"
    local location="$5"

    # Select the right catalog
    local -a catalog
    if [ "$catalog_type" = "gpu" ]; then
        catalog=("${GPU_VM_CATALOG[@]}")
    else
        catalog=("${CPU_VM_CATALOG[@]}")
    fi

    local catalog_count=${#catalog[@]}
    local item_count=$((catalog_count + 1))  # +1 for custom entry

    # Find default index
    local current_index=0
    local i=0
    for entry in "${catalog[@]}"; do
        local entry_sku
        entry_sku=$(echo "$entry" | cut -d'|' -f1)
        if [ "$entry_sku" = "$default_sku" ]; then
            current_index=$i
            break
        fi
        i=$((i + 1))
    done

    # Render the menu in-place using ANSI cursor movement
    _render_menu() {
        local selected=$1 top_offset=$2
        # Move cursor to the start of the menu area
        printf "\033[%d;1H" "$top_offset"

        local idx=0
        for entry in "${catalog[@]}"; do
            local sku cores ram desc gpu family is_def="0"

            if [ "$catalog_type" = "gpu" ]; then
                sku=$(echo "$entry" | cut -d'|' -f1)
                cores=$(echo "$entry" | cut -d'|' -f2)
                ram=$(echo "$entry" | cut -d'|' -f3)
                gpu=$(echo "$entry" | cut -d'|' -f4)
                desc=$(echo "$entry" | cut -d'|' -f6)
            else
                sku=$(echo "$entry" | cut -d'|' -f1)
                cores=$(echo "$entry" | cut -d'|' -f2)
                ram=$(echo "$entry" | cut -d'|' -f3)
                desc=$(echo "$entry" | cut -d'|' -f4)
                gpu=""
            fi

            [ "$sku" = "$default_sku" ] && is_def="1"

            local text
            text=$(_format_vm_line "$catalog_type" "$sku" "$cores" "$ram" "$desc" "$gpu" "$is_def")

            if [ "$idx" -eq "$selected" ]; then
                # Highlighted: black on cyan
                printf "\033[K \033[30;46m > %s \033[0m\n" "$text"
            elif [ "$is_def" = "1" ]; then
                # Default: cyan text
                printf "\033[K \033[36m   %s \033[0m\n" "$text"
            else
                printf "\033[K    %s\n" "$text"
            fi
            idx=$((idx + 1))
        done

        # Custom entry row
        if [ "$selected" -eq "$catalog_count" ]; then
            printf "\033[K \033[30;46m > Enter custom VM size... \033[0m\n"
        else
            printf "\033[K    Enter custom VM size...\n"
        fi
    }

    while true; do
        # Print the header
        echo ""
        echo "   Select VM size for ${pool_name} node pool:"
        printf "   Use \xe2\x86\x91/\xe2\x86\x93 arrows to move, Enter to select, Esc to cancel\n"
        echo ""

        # Get the current cursor row (1-based) for menu rendering
        # Use ANSI DSR (Device Status Report) to query cursor position
        local cursor_row
        if [ -t 0 ]; then
            # Save terminal settings, set raw mode to read the response
            local old_stty
            old_stty=$(stty -g)
            stty raw -echo min 0
            printf "\033[6n" > /dev/tty
            local response=""
            while true; do
                local char
                char=$(dd bs=1 count=1 2>/dev/null)
                response="${response}${char}"
                case "$response" in *R) break ;; esac
            done
            stty "$old_stty"
            # Parse "\033[row;colR"
            cursor_row=$(echo "$response" | sed 's/.*\[//;s/;.*//')
        else
            cursor_row=10  # fallback
        fi

        # Render the initial menu
        _render_menu "$current_index" "$cursor_row"

        # Read keys in raw mode
        local confirmed=false escaped=false

        while [ "$confirmed" = false ] && [ "$escaped" = false ]; do
            # Read a single byte
            local key
            IFS= read -rsn1 key

            if [ "$key" = $'\x1b' ]; then
                # Escape sequence or standalone Esc
                local seq=""
                IFS= read -rsn1 -t 0.1 seq
                if [ -z "$seq" ]; then
                    # Standalone Esc
                    escaped=true
                elif [ "$seq" = "[" ]; then
                    local arrow
                    IFS= read -rsn1 arrow
                    case "$arrow" in
                        A)  # Up arrow
                            [ "$current_index" -gt 0 ] && current_index=$((current_index - 1))
                            _render_menu "$current_index" "$cursor_row"
                            ;;
                        B)  # Down arrow
                            [ "$current_index" -lt $((item_count - 1)) ] && current_index=$((current_index + 1))
                            _render_menu "$current_index" "$cursor_row"
                            ;;
                    esac
                fi
            elif [ "$key" = "" ]; then
                # Enter key
                confirmed=true
            elif [ "$key" = "c" ] || [ "$key" = "C" ]; then
                # Jump to custom entry
                current_index=$catalog_count
                _render_menu "$current_index" "$cursor_row"
            fi
        done

        # Move cursor past the menu
        printf "\033[%d;1H" "$((cursor_row + item_count))"

        if [ "$escaped" = true ]; then
            echo ""
            echo "   Selection cancelled by user." >&2
            echo "ERROR: Provisioning aborted." >&2
            exit 1
        fi

        # ── Resolve selection from menu ────────────────────────────
        local selected_sku="" selected_family=""

        if [ "$current_index" -eq "$catalog_count" ]; then
            # Custom entry
            echo ""
            printf "   Enter custom VM SKU name (e.g. Standard_NC24ads_A100_v4): "
            read -r custom_sku
            if [ -z "$custom_sku" ]; then
                echo "   No value entered. Re-showing menu..."
                continue
            fi
            selected_sku="$(echo "$custom_sku" | xargs)"
        else
            selected_sku=$(echo "${catalog[$current_index]}" | cut -d'|' -f1)
        fi

        # Check availability in the target region
        echo ""
        printf "   Checking availability of %s in %s..." "$selected_sku" "$location"

        if ! test_vm_availability "$selected_sku" "$location"; then
            printf " \033[31mNOT AVAILABLE\033[0m\n"
            echo "   VM size '${selected_sku}' is not available in region '${location}'."
            echo "   Please select a different VM size."
            continue
        fi

        printf " \033[32mOK (%s cores)\033[0m\n" "$VM_AVAIL_CORES"

        # Resolve GPU family & check quota inline
        if [ "$catalog_type" = "gpu" ]; then
            for entry in "${catalog[@]}"; do
                local entry_sku
                entry_sku=$(echo "$entry" | cut -d'|' -f1)
                if [ "$entry_sku" = "$selected_sku" ]; then
                    selected_family=$(echo "$entry" | cut -d'|' -f5)
                    break
                fi
            done

            if [ -z "$selected_family" ] && [ -n "${GPU_FAMILY_MAP[$selected_sku]+x}" ]; then
                selected_family="${GPU_FAMILY_MAP[$selected_sku]}"
            fi

            if [ -z "$selected_family" ]; then
                echo "   Custom GPU SKU detected. The quota family is needed for quota validation."
                printf "   Enter quota family name (e.g. StandardNCADSA100v4Family, or press Enter to skip quota check): "
                read -r selected_family
                if [ -z "$selected_family" ]; then
                    echo "   Quota family not provided. GPU quota check will be skipped for this pool."
                fi
            fi

            # Early quota check — warn but let the user decide
            if [ -n "$selected_family" ]; then
                assert_vm_quota "$pool_name" "$selected_family" "$location" "$VM_AVAIL_CORES"
                if [ "$ASSERT_QUOTA_RESULT" = "zero" ] || [ "$ASSERT_QUOTA_RESULT" = "low" ]; then
                    echo ""
                    printf "   Continue with this VM anyway? (y = keep, n = re-select) [n]: "
                    read -r proceed
                    if [ "$proceed" != "y" ] && [ "$proceed" != "Y" ]; then
                        echo "   Re-showing menu..."
                        continue
                    fi
                fi
            fi
        fi

        # Persist to azd environment
        azd env set "$env_var_name" "$selected_sku" 2>/dev/null || \
            echo "   Warning: Could not persist ${env_var_name} via 'azd env set'."

        printf "   \033[32mSelected: %s\033[0m\n\n" "$selected_sku"

        SELECTED_VM_SKU="$selected_sku"
        SELECTED_VM_CORES="$VM_AVAIL_CORES"
        SELECTED_VM_FAMILY="$selected_family"
        return 0
    done
}
