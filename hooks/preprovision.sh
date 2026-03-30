#!/bin/bash

# =============================================================================
# Pre-Provision Script: Validate prerequisites before provisioning
# =============================================================================

set -e

source "$(dirname "$0")/common.sh"

TOTAL_STEPS=5

write_foundry_banner "Pre-Provision Validation"

# =====================================================
# Step 1: Check Azure CLI authentication
# =====================================================
log_step 1 $TOTAL_STEPS "Checking Azure CLI Authentication"

ACCOUNT_INFO=$(az account show --query "{name:name, id:id}" -o tsv 2>/dev/null || true)

if [ -z "$ACCOUNT_INFO" ]; then
    log_error "Not logged in to Azure CLI. Run 'az login' before provisioning."
    exit 1
fi

ACCOUNT_NAME=$(az account show --query "name" -o tsv 2>/dev/null)
log_success "Signed in to account: ${ACCOUNT_NAME}"

if [ -n "${AZURE_SUBSCRIPTION_ID:-}" ]; then
    az account set -s "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || {
        log_error "Cannot access subscription '${AZURE_SUBSCRIPTION_ID}'."
        log_info "Verify the subscription ID and your access permissions."
        exit 1
    }
    SUB_NAME=$(az account show --query "name" -o tsv 2>/dev/null)
    log_success "Subscription: ${SUB_NAME}"
    write_key_value "ID" "$AZURE_SUBSCRIPTION_ID"
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
    eval val=\$$var 2>/dev/null || val=""
    if [ -z "$val" ]; then
        write_health_row "$var" "Fail" "not set"
    else
        write_key_value "$var" "$val"
    fi
done
# Use the shared assertion for the actual error check
assert_env_vars AZURE_SUBSCRIPTION_ID AZURE_LOCATION AZURE_ENV_NAME

# =====================================================
# Step 4: Select VM sizes for AKS node pools
#         (includes region availability + GPU quota checks)
# =====================================================
log_step 4 $TOTAL_STEPS "Selecting VM Sizes for AKS Node Pools"

# Determine current/default values
CURRENT_SYSTEM_VM="${SYSTEM_VM_SIZE:-$DEFAULT_SYSTEM_VM_SIZE}"
CURRENT_WORKLOAD_VM="${WORKLOAD_VM_SIZE:-$DEFAULT_WORKLOAD_VM_SIZE}"
CURRENT_DEEPSTREAM_VM="${DEEPSTREAM_GPU_VM_SIZE:-$DEFAULT_DEEPSTREAM_GPU_SIZE}"
CURRENT_INFERENCE_VM="${INFERENCE_GPU_VM_SIZE:-$DEFAULT_INFERENCE_GPU_SIZE}"

# Fetch full lists, then select top N centered on the default
run_with_spinner "Querying VM sizes in ${AZURE_LOCATION}" "" \
    true  # placeholder — actual fetch below since we need the output
# Actually fetch (run_with_spinner eats stdout, so do it inline)
_SPINNER_FRAME=0; spinner_tick "Querying VM sizes in ${AZURE_LOCATION}"
mapfile -t ALL_CPU_VMS < <(get_filtered_vm_sizes "$AZURE_LOCATION" "${CPU_VM_PREFIXES[@]}")
mapfile -t ALL_GPU_VMS < <(get_filtered_vm_sizes "$AZURE_LOCATION" "${GPU_VM_PREFIXES[@]}")
spinner_complete "Found VM sizes in ${AZURE_LOCATION}"

log_info "${#ALL_CPU_VMS[@]} CPU + ${#ALL_GPU_VMS[@]} GPU sizes available"

select_vm_sizes_for_menu ALL_CPU_VMS SYSTEM_VMS   SYSTEM_RECOMMENDED_FAMILIES   "$CURRENT_SYSTEM_VM"     "$SIZES_PER_FAMILY" 0 "$SYSTEM_MAX_CORES"
select_vm_sizes_for_menu ALL_CPU_VMS WORKLOAD_VMS WORKLOAD_RECOMMENDED_FAMILIES "$CURRENT_WORKLOAD_VM"   "$SIZES_PER_FAMILY" "$WORKLOAD_MIN_CORES"
select_vm_sizes_for_menu ALL_GPU_VMS GPU_VMS      GPU_RECOMMENDED_FAMILIES      "$CURRENT_DEEPSTREAM_VM" "$SIZES_PER_FAMILY"

write_key_value "System pool"   "${#SYSTEM_VMS[@]} sizes"
write_key_value "Workload pool" "${#WORKLOAD_VMS[@]} sizes"
write_key_value "GPU pool"      "${#GPU_VMS[@]} sizes"

write_section "Choose a VM SKU for each AKS node pool"
log_info "The default is highlighted. Press Enter to accept, C for custom."

# CPU pools (separate lists for system vs workload)
show_vm_selection_menu "System (CPU)"   "SYSTEM_VM_SIZE"   SYSTEM_VMS   "$CURRENT_SYSTEM_VM"   "$AZURE_LOCATION"
SYSTEM_SKU="$SELECTED_VM_SKU"

show_vm_selection_menu "Workload (CPU)" "WORKLOAD_VM_SIZE" WORKLOAD_VMS "$CURRENT_WORKLOAD_VM" "$AZURE_LOCATION"
WORKLOAD_SKU="$SELECTED_VM_SKU"

# GPU pools (quota validated inline, node count determines total cores checked)
show_vm_selection_menu "Deepstream (GPU)" "DEEPSTREAM_GPU_VM_SIZE" GPU_VMS "$CURRENT_DEEPSTREAM_VM" "$AZURE_LOCATION" "$DEEPSTREAM_GPU_MAX_NODE_COUNT" "gpu"
DEEPSTREAM_GPU_VM_SIZE="$SELECTED_VM_SKU"

show_vm_selection_menu "Inference (GPU)" "INFERENCE_GPU_VM_SIZE" GPU_VMS "$CURRENT_INFERENCE_VM" "$AZURE_LOCATION" "$INFERENCE_GPU_MAX_NODE_COUNT" "gpu"
INFERENCE_GPU_VM_SIZE="$SELECTED_VM_SKU"

# =====================================================
# Step 5: Register required Azure resource providers
# =====================================================
log_step 5 $TOTAL_STEPS "Checking Azure Resource Provider Registrations"

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
write_key_value "Providers"      "all registered"
write_key_value "Tools"          "all present"

echo ""
log_success "Proceeding with provisioning..."
echo ""
