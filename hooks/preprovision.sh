#!/bin/bash

# =============================================================================
# Pre-Provision Script: Validate prerequisites before provisioning
# =============================================================================

set -eo pipefail
source "$(dirname "$0")/common.sh"

TOTAL_STEPS=6

write_foundry_banner "Pre-Provision Validation"

# =====================================================
# Step 1: Check Azure CLI authentication
# =====================================================
log_step 1 $TOTAL_STEPS "Checking Azure CLI Authentication"

ACCOUNT_INFO=$(az account show --query "{name:name, id:id}" -o tsv 2>/dev/null | tr -d '\r' || true)

if [ -z "$ACCOUNT_INFO" ]; then
    log_error "Not logged in to Azure CLI. Run 'az login' before provisioning."
    exit 1
fi

ACCOUNT_NAME=$(az account show --query "name" -o tsv 2>/dev/null | tr -d '\r')
log_success "Signed in to account: ${ACCOUNT_NAME}"

if [ -n "${AZURE_SUBSCRIPTION_ID:-}" ]; then
    az account set -s "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || {
        log_error "Cannot access subscription '${AZURE_SUBSCRIPTION_ID}'."
        log_info "Verify the subscription ID and your access permissions."
        exit 1
    }
    SUB_NAME=$(az account show --query "name" -o tsv 2>/dev/null | tr -d '\r')
    log_success "Subscription: ${SUB_NAME}"
    log_success "ID ${AZURE_SUBSCRIPTION_ID}"
fi

# =====================================================
# Step 2: Check required CLI tools
# =====================================================
log_step 2 $TOTAL_STEPS "Checking Required CLI Tools"

assert_cli_tools az helm kubectl -- kubelogin jq

# =====================================================
# Step 3: Validate required environment variables
# =====================================================
log_step 3 $TOTAL_STEPS "Validating Environment Variables"

for var in AZURE_SUBSCRIPTION_ID AZURE_LOCATION AZURE_ENV_NAME; do
    val="${!var:-}"
    if [ -z "$val" ]; then
        write_health_row "$var" "Fail" "not set"
    else
        write_key_value "$var" "$val"
    fi
done
write_key_value "CREATE_IN_LOCAL" "${CREATE_IN_LOCAL:-(unset)}"
if [ "$INTERACTIVE" = "true" ]; then
    write_key_value "Mode" "interactive"
else
    write_key_value "Mode" "non-interactive"
fi
# Use the shared assertion for the actual error check
assert_env_vars AZURE_SUBSCRIPTION_ID AZURE_LOCATION AZURE_ENV_NAME

# Validate STORAGE_SKU_NAME against region capabilities if ZRS is requested
STORAGE_SKU="${STORAGE_SKU_NAME:-Standard_LRS}"
if [ "$STORAGE_SKU" = "Standard_ZRS" ]; then
    log_info "Checking ZRS availability in ${AZURE_LOCATION}..."
    ZRS_AVAILABLE=$(az storage account list-skus --location "$AZURE_LOCATION" \
        --query "[?name=='Standard_ZRS'].name | [0]" \
        -o tsv 2>/dev/null | tr -d '\r' || true)
    if [ -z "$ZRS_AVAILABLE" ]; then
        log_warning "Requested Standard_ZRS is not available in '${AZURE_LOCATION}'."
        log_warning "Falling back to Standard_LRS to avoid deployment failure."
        azd env set STORAGE_SKU_NAME Standard_LRS 2>/dev/null || true
        STORAGE_SKU="Standard_LRS"
    else
        log_success "ZRS is available in ${AZURE_LOCATION}"
    fi
fi
write_key_value "STORAGE_SKU" "$STORAGE_SKU"

# ── Validate Kubernetes version against region capabilities ──────────────
# Pin minors drift from standard support to LTS-only (e.g. 1.32 → LTS).
# If the requested minor is not available on the standard "KubernetesOfficial"
# support plan in this region, auto-fall back to the region's default minor.
REQUESTED_K8S="${KUBERNETES_VERSION:-1.34}"
K8S_VERSIONS_JSON=$(az aks get-versions --location "$AZURE_LOCATION" -o json 2>/dev/null || true)
if [ -n "$K8S_VERSIONS_JSON" ] && command -v jq >/dev/null 2>&1; then
    K8S_STANDARD=$(echo "$K8S_VERSIONS_JSON" | jq -r '.values[] | select(.capabilities.supportPlan | contains(["KubernetesOfficial"])) | .version' 2>/dev/null || true)
    K8S_DEFAULT=$(echo "$K8S_VERSIONS_JSON" | jq -r '.values[] | select(.isDefault==true) | .version' 2>/dev/null | head -n1)
    if ! echo "$K8S_STANDARD" | grep -qx "$REQUESTED_K8S"; then
        if [ -n "$K8S_DEFAULT" ]; then
            log_warning "Kubernetes '${REQUESTED_K8S}' is not on standard support in '${AZURE_LOCATION}'."
            log_warning "Falling back to region default: '${K8S_DEFAULT}'."
            azd_env_set KUBERNETES_VERSION "$K8S_DEFAULT" || true
            export KUBERNETES_VERSION="$K8S_DEFAULT"
            REQUESTED_K8S="$K8S_DEFAULT"
        else
            log_warning "Kubernetes '${REQUESTED_K8S}' is not on standard support and no default could be resolved."
        fi
    fi
    write_key_value "KUBERNETES_VERSION" "$REQUESTED_K8S"
else
    log_warning "Could not query AKS versions in '${AZURE_LOCATION}'. Proceeding with '${REQUESTED_K8S}'."
fi

# Persist the resolved CREATE_FOUNDRY_PROJECT value so Bicep + all downstream
# hooks agree on the same boolean. (Bicep's default is true; the hooks default
# to true to match.)
if azd env set CREATE_FOUNDRY_PROJECT "$CREATE_FOUNDRY_PROJECT" 2>/dev/null; then
    export CREATE_FOUNDRY_PROJECT
    write_key_value "CREATE_FOUNDRY_PROJECT" $CREATE_FOUNDRY_PROJECT
else
    log_warning "Could not persist CREATE_FOUNDRY_PROJECT via 'azd env set'."
fi

# =====================================================
# Step 4: Resolve AI Model Quota (if Foundry enabled)
# =====================================================
log_step 4 $TOTAL_STEPS "Checking AI Model Quota"

if [ "$CREATE_FOUNDRY_PROJECT" = "false" ]; then
    log_info "AI Foundry disabled (CREATE_FOUNDRY_PROJECT=false). Skipping model quota check."
else
    AI_MODEL_NAME="${AI_MODEL_NAME:-$DEFAULT_AI_MODEL_NAME}"
    AI_MODEL_CAPACITY="${AI_MODEL_CAPACITY:-1}"

    resolve_model_quota "$AZURE_LOCATION" "$AI_MODEL_NAME" "$AI_MODEL_CAPACITY"
fi

# =====================================================
# Step 5: Select VM sizes for AKS node pools
#         (includes region availability + GPU quota checks)
# =====================================================
log_step 5 $TOTAL_STEPS "Selecting VM Sizes for AKS Node Pools"

if [ "${SKIP_POST_PROVISION:-false}" = "true" ]; then
    # SKIP_POST_PROVISION gates BOTH the post-provision/post-up hooks AND
    # this pre-provision step's interactive VM SKU / quota menu. Name is
    # historical (the flag was originally postup-only). When true, we still
    # run provider registration in step 6 because `azd up --no-prompt` in CI
    # performs a real Bicep deployment that needs providers registered.
    log_info "SKIP_POST_PROVISION=true — skipping VM SKU availability + quota checks."
    SYSTEM_SKU="${SYSTEM_VM_SIZE:-$DEFAULT_SYSTEM_VM_SIZE}"
    WORKLOAD_SKU="${WORKLOAD_VM_SIZE:-$DEFAULT_WORKLOAD_VM_SIZE}"
    DEEPSTREAM_GPU_VM_SIZE="${DEEPSTREAM_GPU_VM_SIZE:-$DEFAULT_DEEPSTREAM_GPU_SIZE}"
    INFERENCE_GPU_VM_SIZE="${INFERENCE_GPU_VM_SIZE:-$DEFAULT_INFERENCE_GPU_SIZE}"
    # Only persist user-supplied values. Skip persisting compiled-in defaults
    # so a later SKIP_POST_PROVISION=false run will still trigger the menu /
    # validation path rather than silently accept defaults baked into the env.
    _persist_if_set() {
        local var="$1"
        local val="${!var:-}"
        [ -n "$val" ] && azd env set "$var" "$val" 2>/dev/null || true
    }
    _persist_if_set SYSTEM_VM_SIZE
    _persist_if_set WORKLOAD_VM_SIZE
    _persist_if_set DEEPSTREAM_GPU_VM_SIZE
    _persist_if_set INFERENCE_GPU_VM_SIZE
    unset -f _persist_if_set
else
    # Determine current/default values
    CURRENT_SYSTEM_VM="${SYSTEM_VM_SIZE:-$DEFAULT_SYSTEM_VM_SIZE}"
    CURRENT_WORKLOAD_VM="${WORKLOAD_VM_SIZE:-$DEFAULT_WORKLOAD_VM_SIZE}"
    CURRENT_DEEPSTREAM_VM="${DEEPSTREAM_GPU_VM_SIZE:-$DEFAULT_DEEPSTREAM_GPU_SIZE}"
    CURRENT_INFERENCE_VM="${INFERENCE_GPU_VM_SIZE:-$DEFAULT_INFERENCE_GPU_SIZE}"

    # Fetch full lists
    log_info "Querying available VM SKUs in ${AZURE_LOCATION}..."
    mapfile -t ALL_CPU_VMS < <(get_filtered_vm_sizes "$AZURE_LOCATION" "${CPU_VM_PREFIXES[@]}")
    mapfile -t ALL_GPU_VMS < <(get_filtered_vm_sizes "$AZURE_LOCATION" "${GPU_VM_PREFIXES[@]}")
    log_success "Found VM SKUs in ${AZURE_LOCATION}"

    log_info "${#ALL_CPU_VMS[@]} CPU + ${#ALL_GPU_VMS[@]} GPU sizes available"

    if [ "${#ALL_CPU_VMS[@]}" -eq 0 ] && [ "${#ALL_GPU_VMS[@]}" -eq 0 ]; then
        log_error "No VM sizes are available in '${AZURE_LOCATION}' for this subscription."
        log_info "This usually means the region has restrictive SKU policies for your subscription."
        log_info "Try a different region: run 'azd env set AZURE_LOCATION <region>' and re-run 'azd up'."
        log_info "Recommended regions: eastus2, westus3, southcentralus, northeurope"
        exit 1
    fi

    if [ "${#ALL_CPU_VMS[@]}" -eq 0 ]; then
        log_error "No CPU VM sizes (D/E/F-series) are available in '${AZURE_LOCATION}'."
        log_info "AKS requires CPU nodes for system and workload pools."
        log_info "Try a different region: run 'azd env set AZURE_LOCATION <region>' and re-run 'azd up'."
        log_info "Recommended regions: eastus2, westus3, southcentralus, northeurope"
        exit 1
    fi

    if [ "${#ALL_GPU_VMS[@]}" -eq 0 ]; then
        log_warning "No GPU VM sizes (NC/NV/ND-series) are available in '${AZURE_LOCATION}'."
        log_info "GPU pools are required for video processing. Consider a region with GPU support."
        log_info "Try: run 'azd env set AZURE_LOCATION <region>' and re-run 'azd up'."
        log_info "Recommended GPU regions: eastus2, westus3, southcentralus, northeurope"
        exit 1
    fi

    log_info "Querying VM quota in region..."
    if fetch_vm_quota_map "$AZURE_LOCATION"; then
        log_success "Quota data retrieved for ${VM_QUOTA_MAP_COUNT} VM families"
    else
        log_warning "Could not retrieve VM quota data; menus will show all SKUs."
    fi

    select_vm_sizes_for_menu ALL_CPU_VMS SYSTEM_VMS   SYSTEM_RECOMMENDED_FAMILIES   "$CURRENT_SYSTEM_VM"     "$SIZES_PER_FAMILY" 0 "$SYSTEM_MAX_CORES"
    select_vm_sizes_for_menu ALL_CPU_VMS WORKLOAD_VMS WORKLOAD_RECOMMENDED_FAMILIES "$CURRENT_WORKLOAD_VM"   "$SIZES_PER_FAMILY" "$WORKLOAD_MIN_CORES"
    select_vm_sizes_for_menu ALL_GPU_VMS DEEPSTREAM_VMS GPU_RECOMMENDED_FAMILIES    "$CURRENT_DEEPSTREAM_VM" "$SIZES_PER_FAMILY"
    select_vm_sizes_for_menu ALL_GPU_VMS INFERENCE_VMS  GPU_RECOMMENDED_FAMILIES    "$CURRENT_INFERENCE_VM"  "$SIZES_PER_FAMILY"

    # Annotate + filter by quota using each pool's max node count.
    annotate_vm_sizes_with_quota SYSTEM_VMS     "$CURRENT_SYSTEM_VM"     "$SYSTEM_MAX_NODE_COUNT"
    annotate_vm_sizes_with_quota WORKLOAD_VMS   "$CURRENT_WORKLOAD_VM"   "$WORKLOAD_MAX_NODE_COUNT"
    annotate_vm_sizes_with_quota DEEPSTREAM_VMS "$CURRENT_DEEPSTREAM_VM" "$DEEPSTREAM_GPU_MAX_NODE_COUNT"
    annotate_vm_sizes_with_quota INFERENCE_VMS  "$CURRENT_INFERENCE_VM"  "$INFERENCE_GPU_MAX_NODE_COUNT"

    # Resolve defaults — in interactive mode, pick closest available if default unavailable.
    # In non-interactive mode, skip fallback — validation will fail hard if SKU doesn't exist.
    if [ "$INTERACTIVE" = "true" ]; then
        CURRENT_SYSTEM_VM=$(resolve_default_sku "$CURRENT_SYSTEM_VM" SYSTEM_VMS 4)
        CURRENT_WORKLOAD_VM=$(resolve_default_sku "$CURRENT_WORKLOAD_VM" WORKLOAD_VMS 32)
        CURRENT_DEEPSTREAM_VM=$(resolve_default_sku "$CURRENT_DEEPSTREAM_VM" DEEPSTREAM_VMS 6)
        CURRENT_INFERENCE_VM=$(resolve_default_sku "$CURRENT_INFERENCE_VM" INFERENCE_VMS 40)
    fi

    write_key_value "System pool"     "${#SYSTEM_VMS[@]} sizes (with quota)"
    write_key_value "Workload pool"   "${#WORKLOAD_VMS[@]} sizes (with quota)"
    write_key_value "Deepstream pool" "${#DEEPSTREAM_VMS[@]} sizes (with quota)"
    write_key_value "Inference pool"  "${#INFERENCE_VMS[@]} sizes (with quota)"

    if [ "$INTERACTIVE" = "true" ]; then
        write_section "Choose a VM SKU for each AKS node pool"
        log_info "The default is highlighted. Press Enter to accept, C for custom."

        # CPU pools (quota-filtered lists, node count determines total cores checked)
        show_vm_selection_menu "System (CPU)"   "SYSTEM_VM_SIZE"   SYSTEM_VMS   "$CURRENT_SYSTEM_VM"   "$AZURE_LOCATION" "$SYSTEM_MAX_NODE_COUNT"
        SYSTEM_SKU="$SELECTED_VM_SKU"

        show_vm_selection_menu "Workload (CPU)" "WORKLOAD_VM_SIZE" WORKLOAD_VMS "$CURRENT_WORKLOAD_VM" "$AZURE_LOCATION" "$WORKLOAD_MAX_NODE_COUNT"
        WORKLOAD_SKU="$SELECTED_VM_SKU"

        # GPU pools (quota validated inline, node count determines total cores checked)
        show_vm_selection_menu "Deepstream (GPU)" "DEEPSTREAM_GPU_VM_SIZE" DEEPSTREAM_VMS "$CURRENT_DEEPSTREAM_VM" "$AZURE_LOCATION" "$DEEPSTREAM_GPU_MAX_NODE_COUNT" "gpu"
        DEEPSTREAM_GPU_VM_SIZE="$SELECTED_VM_SKU"

        show_vm_selection_menu "Inference (GPU)" "INFERENCE_GPU_VM_SIZE" INFERENCE_VMS "$CURRENT_INFERENCE_VM" "$AZURE_LOCATION" "$INFERENCE_GPU_MAX_NODE_COUNT" "gpu"
        INFERENCE_GPU_VM_SIZE="$SELECTED_VM_SKU"
    else
        # Non-interactive: validate configured SKUs exist and have quota, fail if not.
        log_info "Non-interactive mode (CREATE_IN_LOCAL=false). Validating configured VM sizes."

        _errors=()

        # Validate a VM SKU exists and has quota. Checks both CPU and GPU families.
        # Usage: _validate_vm "Label" "SKU" "ARRAY_NAME" "ENV_VAR" max_nodes ["gpu"]
        _validate_vm() {
            local label="$1" sku="$2" arr_name="$3" env_var="$4" max_nodes="${5:-1}" is_gpu="${6:-}"
            local -n _arr=$arr_name
            local found_cores="" found_family=""
            for entry in "${_arr[@]}"; do
                local entry_sku="${entry%%|*}"
                if [ "$entry_sku" = "$sku" ]; then
                    local rest="${entry#*|}"
                    found_cores="${rest%%|*}"
                    rest="${rest#*|}"
                    # Skip memGB field to get family (4th field: name|cores|memGB|family)
                    rest="${rest#*|}"
                    found_family="${rest%%|*}"
                    break
                fi
            done
            if [ -z "$found_cores" ]; then
                _errors+=("'$sku' ($label) is not available in region '$AZURE_LOCATION'. Set $env_var to a valid SKU.")
                return
            fi
            write_key_value "$label" "$sku ($found_cores vCPUs)"

            # Resolve quota family — GPU uses pattern map, CPU uses SKU family field
            local family=""
            if [ "$is_gpu" = "gpu" ]; then
                get_quota_family_for_vm "$sku"
                family="$GET_QUOTA_FAMILY_RESULT"
            else
                family="$found_family"
            fi

            if [ -z "$family" ]; then
                if [ "$is_gpu" = "gpu" ]; then
                    _errors+=("'$sku' ($label): could not resolve quota family. Cannot verify quota in non-interactive mode.")
                fi
                # CPU without family: skip quota check (non-critical)
                return
            fi

            local needed=$((found_cores))
            if lookup_vm_quota "$family" "$AZURE_LOCATION"; then
                local committed=${COMMITTED_QUOTA_CORES[$family]:-0}
                local avail=$((VM_QUOTA_AVAILABLE - committed))
                if [ "$avail" -lt "$needed" ]; then
                    _errors+=("'$sku' ($label): insufficient quota for '$family' — need $needed cores, have $avail. Request quota at: $QUOTA_URL")
                else
                    COMMITTED_QUOTA_CORES[$family]=$((committed + needed))
                fi
            else
                if [ "$is_gpu" = "gpu" ]; then
                    _errors+=("'$sku' ($label): failed to query quota for '$family'. Cannot verify quota in non-interactive mode.")
                else
                    log_warning "'$sku' ($label): quota data unavailable for '$family'. Skipping CPU quota check." >&2
                fi
            fi
        }

        _validate_vm "System CPU"     "$CURRENT_SYSTEM_VM"     ALL_CPU_VMS "SYSTEM_VM_SIZE"            "$SYSTEM_MAX_NODE_COUNT"
        _validate_vm "Workload CPU"   "$CURRENT_WORKLOAD_VM"   ALL_CPU_VMS "WORKLOAD_VM_SIZE"          "$WORKLOAD_MAX_NODE_COUNT"
        _validate_vm "Deepstream GPU" "$CURRENT_DEEPSTREAM_VM" ALL_GPU_VMS "DEEPSTREAM_GPU_VM_SIZE"    "$DEEPSTREAM_GPU_MAX_NODE_COUNT" "gpu"
        _validate_vm "Inference GPU"  "$CURRENT_INFERENCE_VM"  ALL_GPU_VMS "INFERENCE_GPU_VM_SIZE"     "$INFERENCE_GPU_MAX_NODE_COUNT"  "gpu"

        if [ ${#_errors[@]} -gt 0 ]; then
            for err in "${_errors[@]}"; do log_error "$err"; done
            exit 1
        fi

        SYSTEM_SKU="$CURRENT_SYSTEM_VM"
        WORKLOAD_SKU="$CURRENT_WORKLOAD_VM"
        DEEPSTREAM_GPU_VM_SIZE="$CURRENT_DEEPSTREAM_VM"
        INFERENCE_GPU_VM_SIZE="$CURRENT_INFERENCE_VM"

        # Persist to azd env
        azd env set SYSTEM_VM_SIZE "$CURRENT_SYSTEM_VM" 2>/dev/null || true
        azd env set WORKLOAD_VM_SIZE "$CURRENT_WORKLOAD_VM" 2>/dev/null || true
        azd env set DEEPSTREAM_GPU_VM_SIZE "$CURRENT_DEEPSTREAM_VM" 2>/dev/null || true
        azd env set INFERENCE_GPU_VM_SIZE "$CURRENT_INFERENCE_VM" 2>/dev/null || true
    fi
fi

# =====================================================
# Step 6: Register required Azure resource providers
# =====================================================
log_step 6 $TOTAL_STEPS "Checking Azure Resource Provider Registrations"

# Provider registration always runs — even under SKIP_POST_PROVISION=true,
# `azd up --no-prompt` in CI still performs a real Bicep deployment that
# requires registered providers. Only the interactive SKU/quota menu is gated.
register_required_providers || true

# =====================================================
# Summary
# =====================================================
echo ""
write_box_banner "Pre-Provision Validation Passed" "" "Single" 50

write_section "Configuration Summary"
write_key_value "Subscription"   "${SUB_NAME:-$AZURE_SUBSCRIPTION_ID}"
write_key_value "Location"       "$AZURE_LOCATION"
write_key_value "Environment"    "$AZURE_ENV_NAME"
write_key_value "System CPU"     "$SYSTEM_SKU"
write_key_value "Workload CPU"   "$WORKLOAD_SKU"
write_key_value "Deepstream GPU" "${DEEPSTREAM_GPU_VM_SIZE} (${DEEPSTREAM_GPU_MAX_NODE_COUNT} node(s))"
write_key_value "Inference GPU"  "${INFERENCE_GPU_VM_SIZE} (${INFERENCE_GPU_MAX_NODE_COUNT} node(s))"
if [ "$CREATE_FOUNDRY_PROJECT" != "false" ]; then
    write_key_value "AI Model"       "${AI_MODEL_NAME} (capacity: ${AI_MODEL_CAPACITY})"
fi
write_key_value "Providers"      "all registered"
write_key_value "Tools"          "all present"

echo ""
log_success "Proceeding with provisioning..."
echo ""
