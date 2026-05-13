#!/usr/bin/env bash
# =============================================================================
# Shared Utilities: Common functions used across all Bash hooks
# =============================================================================
# Source this file via: source "$(dirname "$0")/common.sh"
# This file automatically loads config.sh and ui.sh.

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HOOKS_DIR}/config.sh"
source "${HOOKS_DIR}/ui.sh"

# ── Helpers ─────────────────────────────────────────────────────────────────

# Persist a key/value via `azd env set`, warning (but not failing) on error.
# Usage: azd_env_set NAME VALUE
azd_env_set() {
    local name="$1"
    local value="${2:-}"
    if ! azd env set "$name" "$value" 2>/dev/null; then
        log_warning "Could not persist '${name}' via 'azd env set'."
        return 1
    fi
    return 0
}

# ── Prerequisite Checks ─────────────────────────────────────────────────────

assert_env_vars() {
    # Usage: assert_env_vars VAR1 VAR2 VAR3
    local missing=()
    for var in "$@"; do
        val="${!var:-}"
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
        state=$(az provider show -n "$provider" --query "registrationState" -o tsv 2>/dev/null | tr -d '\r' || echo "Unknown")
        case "$state" in
            Registered)
                log_success "$provider"
                ;;
            Registering)
                log_warning "$provider (registration in progress)"
                providers_registering=$((providers_registering + 1))
                ;;
            NotRegistered|Unregistered)
                log_info "Registering $provider..."
                az provider register --namespace "$provider" --wait false 2>/dev/null || true
                log_success "$provider registered"
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

    if ! az aks get-credentials \
        --resource-group "$resource_group" \
        --name "$cluster_name" \
        --admin \
        --overwrite-existing 2>/dev/null; then
        log_error "Failed to get AKS credentials for '$cluster_name'." >&2
        return 1
    fi

    echo "$kube_context"
}

# ── Kubernetes Helpers ──────────────────────────────────────────────────────

get_running_pod_count() {
    # Usage: count=$(get_running_pod_count namespace kube_context)
    # Counts both Running and Succeeded pods — some workloads (e.g. the GPU
    # operator's cuda-validator / install jobs) intentionally end in Succeeded
    # and should not be reported as degraded.
    local namespace="$1"
    local kube_context="$2"
    local running succeeded
    running=$(kubectl --context "$kube_context" get pods -n "$namespace" \
        --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    succeeded=$(kubectl --context "$kube_context" get pods -n "$namespace" \
        --field-selector=status.phase=Succeeded --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo $(( ${running:-0} + ${succeeded:-0} ))
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
# Uses az vm list-skus (not list-sizes) to respect subscription restrictions.
# Output: pipe-delimited lines "name|cores|memGB|family" to stdout.
# family is the az vm list-skus "family" field — matches az vm list-usage
# name.value so we can look up quota directly.
get_filtered_vm_sizes() {
    local location="$1"; shift
    local -a prefixes=("$@")

    # Build a JMESPath expression like:
    #   (starts_with(name, 'Standard_D') || starts_with(name, 'Standard_E'))
    # so Azure does the prefix filtering server-side instead of piping every
    # unrestricted SKU through bash.
    local prefix_expr=""
    if [ "${#prefixes[@]}" -gt 0 ]; then
        local joined="" sep=""
        for p in "${prefixes[@]}"; do
            joined+="${sep}starts_with(name, \`${p}\`)"
            sep=" || "
        done
        prefix_expr=" && (${joined})"
    fi

    local query="[?(restrictions[?type==\`Location\`]|length(@)==\`0\`)${prefix_expr}].{n:name, c:capabilities[?name==\`vCPUs\`].value|[0], m:capabilities[?name==\`MemoryGB\`].value|[0], f:family}"
    az vm list-skus --location "$location" --resource-type virtualMachines \
        --query "$query" -o tsv 2>/dev/null | tr -d '\r' | while IFS=$'\t' read -r name cores memGB family; do
        [ -z "$name" ] && continue
        echo "${name}|${cores}|${memGB}|${family}"
    done | sort -t'|' -k2 -n
}

# Checks if a default SKU is available; if not, picks the closest by core count.
# Usage: resolved=$(resolve_default_sku "Standard_D4a_v4" ARRAY_NAME 4)
resolve_default_sku() {
    local default_sku="$1"
    local -n _sizes=$2
    local prefer_cores="${3:-0}"

    if [ ${#_sizes[@]} -eq 0 ]; then
        echo "$default_sku"
        return
    fi

    # Check if default exists
    for entry in "${_sizes[@]}"; do
        local sku="${entry%%|*}"
        [ "$sku" = "$default_sku" ] && { echo "$default_sku"; return; }
    done

    # Not available — pick closest by core count
    log_warning "Default SKU '$default_sku' is not available in this subscription/region." >&2

    local best_sku="" best_diff=999999 best_cores=0
    for entry in "${_sizes[@]}"; do
        local sku="${entry%%|*}"
        local rest="${entry#*|}"
        local cores="${rest%%|*}"
        local diff=$(( cores - prefer_cores ))
        [ "$diff" -lt 0 ] && diff=$(( -diff ))
        if [ "$diff" -lt "$best_diff" ]; then
            best_diff="$diff"
            best_sku="$sku"
            best_cores="$cores"
        fi
    done

    if [ -n "$best_sku" ]; then
        log_info "Auto-selected '$best_sku' ($best_cores vCPUs) as closest match." >&2
        echo "$best_sku"
    else
        echo "$default_sku"
    fi
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
            if [[ "$sku" =~ $pattern ]]; then
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

    # Sort output by cores (guard: empty array → printf with no args emits a
    # bare newline that mapfile captures as one phantom empty-string element)
    if [ "${#_out[@]}" -gt 0 ]; then
        local -a sorted
        mapfile -t sorted < <(printf '%s\n' "${_out[@]}" | sort -t'|' -k2 -n)
        _out=("${sorted[@]}")
    fi
}

# Tracks cores already committed by prior GPU pool selections in this session.
declare -A COMMITTED_QUOTA_CORES

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
        -o tsv 2>/dev/null | tr -d '\r' || true)
    [ -z "$raw" ] && return 1
    VM_QUOTA_LIMIT=$(echo "$raw" | cut -f1)
    VM_QUOTA_USED=$(echo "$raw" | cut -f2)
    VM_QUOTA_AVAILABLE=$((VM_QUOTA_LIMIT - VM_QUOTA_USED))
    return 0
}

# Resolves quota family for a VM size.
# Prefers the sku_family argument (from az vm list-skus "family" field, which
# matches az vm list-usage name.value). Falls back to the regex table in
# GPU_QUOTA_PATTERNS / GPU_QUOTA_FAMILIES for older SKUs with an empty family.
GET_QUOTA_FAMILY_RESULT=""
get_quota_family_for_vm() {
    local vm_size="$1"
    local sku_family="${2:-}"
    GET_QUOTA_FAMILY_RESULT=""
    if [ -n "$sku_family" ]; then
        GET_QUOTA_FAMILY_RESULT="$sku_family"
        return 0
    fi
    for ((i=0; i<${#GPU_QUOTA_PATTERNS[@]}; i++)); do
        if [[ "$vm_size" =~ ${GPU_QUOTA_PATTERNS[$i]} ]]; then
            GET_QUOTA_FAMILY_RESULT="${GPU_QUOTA_FAMILIES[$i]}"
            return 0
        fi
    done
    return 1
}

# Fetches full per-family quota map for a region in a single call.
# Populates the global associative array VM_QUOTA_MAP[family]="avail|limit".
declare -gA VM_QUOTA_MAP=()
VM_QUOTA_MAP_COUNT=0
fetch_vm_quota_map() {
    local location="$1"
    VM_QUOTA_MAP=()
    VM_QUOTA_MAP_COUNT=0
    local raw
    raw=$(az vm list-usage --location "$location" \
        --query "[].{n:name.value, l:limit, u:currentValue}" \
        -o tsv 2>/dev/null | tr -d '\r' || true)
    [ -z "$raw" ] && return 1
    while IFS=$'\t' read -r fam limit used; do
        [ -z "$fam" ] && continue
        local avail=$((limit - used))
        VM_QUOTA_MAP["$fam"]="${avail}|${limit}"
        VM_QUOTA_MAP_COUNT=$((VM_QUOTA_MAP_COUNT + 1))
    done <<< "$raw"
    return 0
}

# Annotates + filters a VM size array by quota.
# Input entries: "name|cores|memGB|family" (from get_filtered_vm_sizes).
# Output entries: "name|cores|memGB|family|avail|limit|hasEnough" where:
#   - avail/limit are empty when family is unknown to the quota map
#   - hasEnough is 1/0 (always 1 when family unknown, to avoid hiding SKUs)
# SKUs that can't satisfy $max_nodes are dropped, except $default_sku which is
# kept (annotated) so the user always sees it. If filtering would empty the
# list, the unfiltered annotated set is returned instead.
annotate_vm_sizes_with_quota() {
    local -n _list=$1
    local default_sku="${2:-}"
    local max_nodes="${3:-1}"
    [ "$max_nodes" -lt 1 ] && max_nodes=1

    local -a annotated=() kept=()

    for entry in "${_list[@]}"; do
        local name="${entry%%|*}"
        local rest="${entry#*|}"
        local cores="${rest%%|*}"; rest="${rest#*|}"
        local mem="${rest%%|*}";   rest="${rest#*|}"
        local family="${rest}"

        get_quota_family_for_vm "$name" "$family" >/dev/null || true
        local fam="$GET_QUOTA_FAMILY_RESULT"

        local avail="" limit="" has_enough=1 family_known=0
        if [ -n "$fam" ] && [ -n "${VM_QUOTA_MAP[$fam]+x}" ]; then
            family_known=1
            local qinfo="${VM_QUOTA_MAP[$fam]}"
            avail="${qinfo%%|*}"
            limit="${qinfo##*|}"
            local needed=$((cores * max_nodes))
            if [ "$limit" -le 0 ] || [ "$avail" -lt "$needed" ]; then
                has_enough=0
            fi
        fi

        local annotated_entry="${name}|${cores}|${mem}|${fam}|${avail}|${limit}|${has_enough}"
        annotated+=("$annotated_entry")

        # Keep SKUs with unknown quota family (can't verify, don't hide newer
        # SKUs), SKUs with enough quota, or the configured default.
        if [ "$family_known" = "0" ] || [ "$has_enough" = "1" ]; then
            kept+=("$annotated_entry")
        elif [ "$name" = "$default_sku" ]; then
            kept+=("$annotated_entry")
        fi
    done

    # Fall back to the unfiltered list if filtering emptied it
    if [ "${#kept[@]}" -eq 0 ]; then
        _list=("${annotated[@]}")
    else
        _list=("${kept[@]}")
    fi
    return 0
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

    # Subtract cores already committed by prior GPU pool selections
    local committed=${COMMITTED_QUOTA_CORES[$family]:-0}
    if [ "$committed" -gt 0 ]; then
        VM_QUOTA_AVAILABLE=$((VM_QUOTA_AVAILABLE - committed))
        [ "$VM_QUOTA_AVAILABLE" -lt 0 ] && VM_QUOTA_AVAILABLE=0
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

# ── AI Model Quota Check ──────────────────────────────────────────────────

resolve_model_quota() {
    # Usage: resolve_model_quota <location> <model> <capacity> [format] [deployment_type] [capacity_env_var]
    # Checks AI model deployment quota via az cognitiveservices usage list.
    # If insufficient, prompts the user to reduce capacity or exits.
    local location="$1"
    local model="$2"
    local capacity="$3"
    local format="${4:-$DEFAULT_AI_MODEL_FORMAT}"
    local deployment_type="${5:-$DEFAULT_AI_MODEL_DEPLOYMENT_TYPE}"
    local capacity_env_var="${6:-AI_MODEL_CAPACITY}"

    local model_type="${format}.${deployment_type}.${model}"
    log_info "Checking quota for $model_type in $location..."

    local model_info
    # Query limit + current as TSV (two tab-separated fields, explicit order) —
    # avoids fragile awk JSON parsing.
    model_info=$(az cognitiveservices usage list --location "$location" \
        --query "[?name.value=='$model_type'] | [0].{l:limit, u:currentValue}" \
        --output tsv 2>/dev/null | tr -d '\r')

    if [ -z "$model_info" ]; then
        log_warning "No quota info found for '$model_type' in '$location'. Skipping quota check."
        log_info "The model may not be available in this region. Bicep will report a clearer error if so."
        return 0
    fi

    local current_value limit
    limit=$(echo "$model_info" | cut -f1)
    current_value=$(echo "$model_info" | cut -f2)
    current_value=$(echo "${current_value:-0}" | cut -d'.' -f1 | tr -dc '0-9')
    limit=$(echo "${limit:-0}" | cut -d'.' -f1 | tr -dc '0-9')
    current_value=${current_value:-0}
    limit=${limit:-0}
    local available=$((limit - current_value))

    write_key_value "Model" "$model_type"
    write_key_value "Quota" "$available available ($current_value used / $limit limit)"

    if [ "$available" -ge "$capacity" ]; then
        log_success "Sufficient quota: $available available, need $capacity"
        return 0
    fi

    if [ "$available" -ge 1 ]; then
        log_warning "Insufficient quota: $available available (in thousands of TPM), need $capacity."
        if [ "$INTERACTIVE" != "true" ]; then
            # Non-interactive: auto-reduce capacity to available quota
            log_info "Non-interactive mode. Auto-adjusting capacity to $available."
            azd env set "$capacity_env_var" "$available" 2>/dev/null || true
            log_success "Capacity adjusted to $available (saved to $capacity_env_var)"
            return 0
        fi
        local valid_input=false
        while [ "$valid_input" = false ]; do
            printf "   Enter a new capacity between 1 and %d (or 'q' to abort): " "$available"
            read -r user_input
            if [ "$user_input" = "q" ]; then
                log_error "Aborted by user."
                exit 1
            fi
            if echo "$user_input" | grep -qE '^[0-9]+$'; then
                if [ "$user_input" -ge 1 ] && [ "$user_input" -le "$available" ]; then
                    valid_input=true
                else
                    log_warning "Invalid input. '$user_input' is not between 1 and $available."
                fi
            else
                log_warning "Invalid input: '$user_input' is not a valid integer."
            fi
        done
        azd env set "$capacity_env_var" "$user_input" 2>/dev/null || true
        log_success "Capacity adjusted to $user_input (saved to $capacity_env_var)"
    else
        log_error "Zero quota available for '$model_type' in '$location'."
        log_info "Request quota at: $AI_QUOTA_URL"
        exit 1
    fi
}

# ── Interactive VM Selection Menu ─────────────────────────────────────────
# NOTE: This function uses low-level terminal manipulation for interactive
# arrow-key menus when a capable terminal is available.  When running under
# azd on Windows (pseudo-terminal without raw-mode support) it falls back to
# a simple numbered-list menu that only needs basic line input.

# Detect whether the terminal supports the interactive arrow-key menu.
# On Windows (MSYS / Git Bash / Cygwin) the pseudo-terminal that azd provides
# passes the stty probe but still breaks on read -rsn1, so we always fall back
# to the simple numbered-list menu there.
_TERM_SUPPORTS_RAW=""
_test_terminal_raw_mode() {
    if [ -n "$_TERM_SUPPORTS_RAW" ]; then return "$_TERM_SUPPORTS_RAW"; fi
    _TERM_SUPPORTS_RAW=1  # assume unsupported

    # Windows pseudo-terminals (MSYS, Cygwin) don't reliably support raw reads
    case "$OSTYPE" in
        msys*|cygwin*|mingw*) _TERM_SUPPORTS_RAW=1; return 1 ;;
    esac

    if [ -t 0 ] && [ -t 1 ]; then
        local _old
        _old=$(stty -g 2>/dev/null) || { _TERM_SUPPORTS_RAW=1; return 1; }
        if stty raw -echo min 0 time 1 2>/dev/null; then
            stty "$_old" 2>/dev/null
            _TERM_SUPPORTS_RAW=0
        else
            stty "$_old" 2>/dev/null || true
        fi
    fi
    return "$_TERM_SUPPORTS_RAW"
}

SELECTED_VM_SKU=""
SELECTED_VM_CORES=0
SELECTED_VM_FAMILY=""

show_vm_selection_menu() {
    local pool_name="$1"
    local env_var_name="$2"
    local _vm_array_name=$3
    local default_sku="$4"
    local location="$5"
    local max_nodes="${6:-1}"
    local is_gpu="${7:-}"

    local -n _vm_array_ref=$_vm_array_name
    local vm_count=${#_vm_array_ref[@]}

    if [ "$vm_count" -eq 0 ]; then
        log_error "No VM sizes available for this pool."
        log_error "Provisioning aborted."
        exit 1
    fi

    # If stdin is not a real TTY (azd hook pipes stdin in devcontainer), skip
    # interactive menu entirely — `read` would hit EOF and `set -e` would abort.
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        log_warning "Non-TTY stdin detected — auto-selecting default '${default_sku}' for ${pool_name}."
        log_info "To choose interactively, run 'bash hooks/preprovision.sh' directly, or set the SKU via 'azd env set ${env_var_name} <SKU>'."
        SELECTED_VM_SKU="$default_sku"
        SELECTED_VM_CORES=0
        SELECTED_VM_FAMILY=""
        for entry in "${_vm_array_ref[@]}"; do
            local n="${entry%%|*}"
            if [ "$n" = "$default_sku" ]; then
                local rest="${entry#*|}"
                SELECTED_VM_CORES="${rest%%|*}"
                rest="${rest#*|}"      # drop cores
                rest="${rest#*|}"      # drop memGB
                SELECTED_VM_FAMILY="${rest%%|*}"
                break
            fi
        done
        azd env set "$env_var_name" "$default_sku" 2>/dev/null || true

        # GPU pools: still validate + reserve quota so we don't proceed silently
        # with an unfunded default SKU.
        if [ "$is_gpu" = "gpu" ] && [ "$SELECTED_VM_CORES" -gt 0 ]; then
            get_quota_family_for_vm "$default_sku" "$SELECTED_VM_FAMILY"
            local _fam="$GET_QUOTA_FAMILY_RESULT"
            if [ -n "$_fam" ]; then
                SELECTED_VM_FAMILY="$_fam"
                local _total=$((SELECTED_VM_CORES * max_nodes))
                assert_vm_quota "$pool_name" "$_fam" "$location" "$_total" || true
                if [ "$ASSERT_QUOTA_RESULT" = "ok" ]; then
                    COMMITTED_QUOTA_CORES[$_fam]=$(( ${COMMITTED_QUOTA_CORES[$_fam]:-0} + _total ))
                elif [ "$ASSERT_QUOTA_RESULT" = "zero" ] || [ "$ASSERT_QUOTA_RESULT" = "low" ]; then
                    log_error "Default GPU SKU '${default_sku}' for ${pool_name} has insufficient quota — set '$env_var_name' to a SKU with quota or request quota."
                    exit 1
                fi
            else
                log_warning "Could not resolve quota family for default GPU SKU '${default_sku}'. Skipping quota check."
            fi
        fi
        return 0
    fi

    # Disable set -e around menu so a read EOF or terminal glitch cannot kill
    # the parent hook. Capture exit, fall back to default SKU on failure.
    # Save current errexit state — restoring unconditionally would change shell
    # options for callers that didn't have `set -e` enabled.
    local _had_e=0
    case "$-" in *e*) _had_e=1 ;; esac
    local menu_ok=0
    set +e
    if _test_terminal_raw_mode; then
        _show_vm_menu_interactive "$pool_name" "$env_var_name" "$_vm_array_name" "$default_sku" "$location" "$max_nodes" "$is_gpu"
        menu_ok=$?
    else
        _show_vm_menu_simple "$pool_name" "$env_var_name" "$_vm_array_name" "$default_sku" "$location" "$max_nodes" "$is_gpu"
        menu_ok=$?
    fi
    [ "$_had_e" -eq 1 ] && set -e

    if [ "$menu_ok" -ne 0 ] || [ -z "$SELECTED_VM_SKU" ]; then
        log_warning "VM menu failed (exit $menu_ok) — falling back to default '${default_sku}' for ${pool_name}."
        SELECTED_VM_SKU="$default_sku"
        SELECTED_VM_CORES=0
        SELECTED_VM_FAMILY=""
        azd env set "$env_var_name" "$default_sku" 2>/dev/null || true
    fi
    return 0
}

# ── Simple numbered-list fallback (works without raw terminal) ────────────
_show_vm_menu_simple() {
    local pool_name="$1"
    local env_var_name="$2"
    local -n _svm_array=$3
    local default_sku="$4"
    local location="$5"
    local max_nodes="${6:-1}"
    local is_gpu="${7:-}"

    local vm_count=${#_svm_array[@]}

    # Parse into parallel arrays
    local -a vm_names vm_cores vm_mem vm_family vm_avail vm_limit vm_has_enough
    local has_quota_info=0
    for entry in "${_svm_array[@]}"; do
        IFS='|' read -r -a _f <<< "$entry"
        vm_names+=("${_f[0]}")
        vm_cores+=("${_f[1]}")
        vm_mem+=("${_f[2]}")
        vm_family+=("${_f[3]:-}")
        vm_avail+=("${_f[4]:-}")
        vm_limit+=("${_f[5]:-}")
        vm_has_enough+=("${_f[6]:-1}")
        if [ -n "${_f[4]:-}" ] || [ -n "${_f[5]:-}" ]; then
            has_quota_info=1
        fi
    done

    # Find default index
    local default_index=0
    for ((i=0; i<vm_count; i++)); do
        [ "${vm_names[$i]}" = "$default_sku" ] && { default_index=$i; break; }
    done

    while true; do
        echo ""
        write_section "Select VM size for ${pool_name} (${vm_count} sizes available)"
        if [ "$has_quota_info" = "1" ]; then
            log_info "Quota column shows cores free in this region (pool max nodes: ${max_nodes})."
        fi
        echo ""

        for ((i=0; i<vm_count; i++)); do
            local tag=""
            [ "${vm_names[$i]}" = "$default_sku" ] && tag=" (default)"

            local qcol=""
            if [ "$has_quota_info" = "1" ]; then
                if [ -n "${vm_avail[$i]}" ]; then
                    qcol=$(printf "%-14s" "${vm_avail[$i]} free")
                else
                    qcol=$(printf "%-14s" "quota n/a")
                fi
            fi

            printf "   %2d) %-35s %-10s %-8s %s%s\n" "$((i+1))" "${vm_names[$i]}" "${vm_cores[$i]} vCPUs" "${vm_mem[$i]} GB" "$qcol" "$tag"
        done
        printf "    C) Enter custom VM size\n"
        echo ""
        printf "   Enter choice [%d]: " "$((default_index + 1))"
        read -r user_choice

        # Default: press Enter → use default index
        if [ -z "$user_choice" ]; then
            user_choice=$((default_index + 1))
        fi

        local selected_sku="" selected_cores=0 selected_family=""

        if [ "$user_choice" = "c" ] || [ "$user_choice" = "C" ]; then
            printf "   Enter VM SKU (e.g. Standard_NC24ads_A100_v4): "
            read -r custom_sku
            [ -z "$custom_sku" ] && { log_warning "No value entered. Re-showing menu..."; continue; }
            selected_sku="$(echo "$custom_sku" | xargs)"
            for ((i=0; i<vm_count; i++)); do
                [ "${vm_names[$i]}" = "$selected_sku" ] && { selected_cores="${vm_cores[$i]}"; break; }
            done
            [ "$selected_cores" -eq 0 ] && { log_error "'$selected_sku' not found in region."; continue; }
        elif [[ "$user_choice" =~ ^[0-9]+$ ]] && [ "$user_choice" -ge 1 ] && [ "$user_choice" -le "$vm_count" ]; then
            local idx=$((user_choice - 1))
            selected_sku="${vm_names[$idx]}"
            selected_cores="${vm_cores[$idx]}"
        else
            log_warning "Invalid choice '$user_choice'. Enter a number 1-${vm_count} or C."
            continue
        fi

        log_success "${selected_sku} (${selected_cores} vCPUs)"

        # GPU quota check
        if [ "$is_gpu" = "gpu" ]; then
            _write_log_message "Resolving quota family..." "$SYM_INFO" "$C_ACCENT" "$C_TEXT" false true
            local sku_family=""
            for ((i=0; i<vm_count; i++)); do
                if [ "${vm_names[$i]}" = "$selected_sku" ]; then
                    sku_family="${vm_family[$i]:-}"
                    break
                fi
            done
            get_quota_family_for_vm "$selected_sku" "$sku_family"
            selected_family="$GET_QUOTA_FAMILY_RESULT"
            if [ -n "$selected_family" ]; then
                printf " %b%s%b\n" "$C_MUTED" "$selected_family" "$C_RESET"
                local total_cores=$((selected_cores * max_nodes))
                assert_vm_quota "$pool_name" "$selected_family" "$location" "$total_cores" || true
                if [ "$ASSERT_QUOTA_RESULT" = "zero" ] || [ "$ASSERT_QUOTA_RESULT" = "low" ]; then
                    log_warning "Re-showing menu..."
                    continue
                fi
                # Reserve committed cores so subsequent GPU pool selections see reduced availability
                if [ "$ASSERT_QUOTA_RESULT" = "ok" ] && [ -n "$selected_family" ]; then
                    COMMITTED_QUOTA_CORES[$selected_family]=$(( ${COMMITTED_QUOTA_CORES[$selected_family]:-0} + total_cores ))
                    local remaining=$((VM_QUOTA_AVAILABLE - total_cores))
                    log_info "Reserved $total_cores cores ($selected_family) for $pool_name — $remaining remaining"
                fi
            else
                printf " %bnot found (quota check skipped)%b\n" "$C_WARNING" "$C_RESET"
            fi
        fi

        azd env set "$env_var_name" "$selected_sku" 2>/dev/null || \
            log_warning "Could not persist ${env_var_name} via 'azd env set'."

        log_success "Selected: $selected_sku"
        echo ""
        printf "  %b────────────────────────────────────────────────────────────%b\n\n" "$C_MUTED" "$C_RESET"
        SELECTED_VM_SKU="$selected_sku"
        SELECTED_VM_CORES="$selected_cores"
        SELECTED_VM_FAMILY="$selected_family"
        return 0
    done
}

# ── Interactive arrow-key menu (requires raw terminal support) ────────────
_show_vm_menu_interactive() {
    local pool_name="$1"
    local env_var_name="$2"
    local -n _ivm_array=$3
    local default_sku="$4"
    local location="$5"
    local max_nodes="${6:-1}"
    local is_gpu="${7:-}"

    local vm_count=${#_ivm_array[@]}
    local item_count=$((vm_count + 1))
    local max_visible=20
    [ "$item_count" -lt "$max_visible" ] && max_visible=$item_count

    # Parse into parallel arrays for fast indexed access.
    # Entries are either "name|cores|memGB" (legacy), "name|cores|memGB|family",
    # or quota-annotated "name|cores|memGB|family|avail|limit|hasEnough".
    local -a vm_names vm_cores vm_mem vm_family vm_avail vm_limit vm_has_enough
    local has_quota_info=0
    for entry in "${_ivm_array[@]}"; do
        IFS='|' read -r -a _f <<< "$entry"
        vm_names+=("${_f[0]}")
        vm_cores+=("${_f[1]}")
        vm_mem+=("${_f[2]}")
        vm_family+=("${_f[3]:-}")
        vm_avail+=("${_f[4]:-}")
        vm_limit+=("${_f[5]:-}")
        vm_has_enough+=("${_f[6]:-1}")
        if [ -n "${_f[4]:-}" ] || [ -n "${_f[5]:-}" ]; then
            has_quota_info=1
        fi
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
        # Use relative positioning: caller ensures cursor is at menu top row.
        # `top` arg kept for compatibility but no longer used.
        printf "\r"
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

                # Quota column
                local qcol=""
                if [ "$has_quota_info" = "1" ]; then
                    if [ -n "${vm_avail[$idx]}" ]; then
                        qcol=$(printf "%-14s" "${vm_avail[$idx]} free")
                    else
                        qcol=$(printf "%-14s" "quota n/a")
                    fi
                fi

                text=$(printf "%-35s %-10s %-8s %s%s" "${vm_names[$idx]}" "${vm_cores[$idx]} vCPUs" "${vm_mem[$idx]} GB" "$qcol" "$tag")
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
        if [ "$has_quota_info" = "1" ]; then
            log_info "Quota column shows cores free in this region (pool max nodes: ${max_nodes})."
        fi
        echo ""

        # Relative positioning: print blank lines for viewport, move cursor back
        # to top of viewport, then render in place. Avoids unreliable cursor-DSR
        # query that breaks in devcontainer / azd pseudo-terminals.
        for ((r=0; r<max_visible; r++)); do echo ""; done
        printf "\033[%dA" "$max_visible"  # move cursor up to viewport top
        local menu_top=0  # unused with relative positioning

        _update_scroll
        _render_menu "$current_index" "$menu_top" "$scroll_offset"
        # After render, cursor is on line after viewport. Move back up to top.
        _rerender() {
            printf "\033[%dA" "$max_visible"
            _render_menu "$current_index" "$menu_top" "$scroll_offset"
        }

        local confirmed=false escaped=false
        while [ "$confirmed" = false ] && [ "$escaped" = false ]; do
            local key=""
            if ! IFS= read -rsn1 key; then
                # read failed (EOF / non-TTY). Abort menu — caller falls back.
                echo ""
                log_warning "Interactive menu input unavailable (read EOF)."
                return 2
            fi
            if [ "$key" = $'\x1b' ]; then
                local seq=""; IFS= read -rsn1 -t 0.1 seq || true
                if [ -z "$seq" ]; then escaped=true
                elif [ "$seq" = "[" ]; then
                    local arrow; IFS= read -rsn1 arrow
                    case "$arrow" in
                        A) [ "$current_index" -gt 0 ] && current_index=$((current_index - 1)); _update_scroll; _rerender ;;
                        B) [ "$current_index" -lt $((item_count - 1)) ] && current_index=$((current_index + 1)); _update_scroll; _rerender ;;
                    esac
                fi
            elif [ "$key" = "" ]; then confirmed=true
            elif [ "$key" = "c" ] || [ "$key" = "C" ]; then
                current_index=$vm_count; _update_scroll; _rerender
            fi
        done

        # After Enter: _render_menu left cursor below viewport. Add blank line
        # for visual separation between this menu and next action / pool menu.
        echo ""

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
            local sku_family=""
            for ((i=0; i<vm_count; i++)); do
                if [ "${vm_names[$i]}" = "$selected_sku" ]; then
                    sku_family="${vm_family[$i]:-}"
                    break
                fi
            done
            get_quota_family_for_vm "$selected_sku" "$sku_family"
            selected_family="$GET_QUOTA_FAMILY_RESULT"
            if [ -n "$selected_family" ]; then
                printf " %b%s%b\n" "$C_MUTED" "$selected_family" "$C_RESET"
                local total_cores=$((selected_cores * max_nodes))
                assert_vm_quota "$pool_name" "$selected_family" "$location" "$total_cores" || true

                if [ "$ASSERT_QUOTA_RESULT" = "zero" ] || [ "$ASSERT_QUOTA_RESULT" = "low" ]; then
                    log_warning "Re-showing menu..."
                    continue
                fi
                # Reserve committed cores so subsequent GPU pool selections see reduced availability
                if [ "$ASSERT_QUOTA_RESULT" = "ok" ] && [ -n "$selected_family" ]; then
                    COMMITTED_QUOTA_CORES[$selected_family]=$(( ${COMMITTED_QUOTA_CORES[$selected_family]:-0} + total_cores ))
                    local remaining=$((VM_QUOTA_AVAILABLE - total_cores))
                    log_info "Reserved $total_cores cores ($selected_family) for $pool_name — $remaining remaining"
                fi
            else
                printf " %bnot found (quota check skipped)%b\n" "$C_WARNING" "$C_RESET"
            fi
        fi

        azd env set "$env_var_name" "$selected_sku" 2>/dev/null || \
            log_warning "Could not persist ${env_var_name} via 'azd env set'."

        log_success "Selected: $selected_sku"
        echo ""
        printf "  %b────────────────────────────────────────────────────────────%b\n\n" "$C_MUTED" "$C_RESET"
        SELECTED_VM_SKU="$selected_sku"
        SELECTED_VM_CORES="$selected_cores"
        SELECTED_VM_FAMILY="$selected_family"
        return 0
    done
}