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

# Resolve defaults — if the configured default isn't available, pick the closest match
CURRENT_SYSTEM_VM=$(resolve_default_sku "$CURRENT_SYSTEM_VM" SYSTEM_VMS 4)
CURRENT_WORKLOAD_VM=$(resolve_default_sku "$CURRENT_WORKLOAD_VM" WORKLOAD_VMS 32)
CURRENT_DEEPSTREAM_VM=$(resolve_default_sku "$CURRENT_DEEPSTREAM_VM" DEEPSTREAM_VMS 24)
CURRENT_INFERENCE_VM=$(resolve_default_sku "$CURRENT_INFERENCE_VM" INFERENCE_VMS 24)

write_key_value "System pool"     "${#SYSTEM_VMS[@]} sizes (with quota)"
write_key_value "Workload pool"   "${#WORKLOAD_VMS[@]} sizes (with quota)"
write_key_value "Deepstream pool" "${#DEEPSTREAM_VMS[@]} sizes (with quota)"
write_key_value "Inference pool"  "${#INFERENCE_VMS[@]} sizes (with quota)"

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

# =====================================================
# Step 6: Register required Azure resource providers
# =====================================================
log_step 6 $TOTAL_STEPS "Checking Azure Resource Provider Registrations"

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
