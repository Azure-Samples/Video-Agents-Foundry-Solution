#!/bin/bash

# =============================================================================
# Pre-Provision Script: Validate prerequisites before provisioning
# =============================================================================

set -e

source "$(dirname "$0")/common.sh"

write_banner "Pre-provision: Validation & Pre-flight Checks"

# =====================================================
# Step 1: Check Azure CLI authentication
# =====================================================
write_step "1" "Checking Azure CLI authentication..."

ACCOUNT_INFO=$(az account show --query "{name:name, id:id}" -o tsv 2>/dev/null || true)

if [ -z "$ACCOUNT_INFO" ]; then
    echo "   ERROR: Not logged in to Azure CLI." >&2
    echo "   Run 'az login' before provisioning." >&2
    exit 1
fi

ACCOUNT_NAME=$(az account show --query "name" -o tsv 2>/dev/null)
echo "   Signed in to account: ${ACCOUNT_NAME}"

if [ -n "${AZURE_SUBSCRIPTION_ID:-}" ]; then
    az account set -s "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || {
        echo "   ERROR: Cannot access subscription '${AZURE_SUBSCRIPTION_ID}'." >&2
        echo "   Verify the subscription ID and your access permissions." >&2
        exit 1
    }
    SUB_NAME=$(az account show --query "name" -o tsv 2>/dev/null)
    echo "   Subscription: ${SUB_NAME} (${AZURE_SUBSCRIPTION_ID})"
fi

# =====================================================
# Step 2: Check required CLI tools
# =====================================================
write_step "2" "Checking required CLI tools..."

assert_cli_tools az helm kubectl -- kubelogin jq

# =====================================================
# Step 3: Validate required environment variables
# =====================================================
write_step "3" "Validating pre-provision environment variables..."

for var in AZURE_SUBSCRIPTION_ID AZURE_LOCATION AZURE_ENV_NAME; do
    eval val=\$$var 2>/dev/null || val=""
    if [ -z "$val" ]; then
        echo "   ${var}: MISSING"
    else
        echo "   ${var}: ${val}"
    fi
done
# Use the shared assertion for the actual error check
assert_env_vars AZURE_SUBSCRIPTION_ID AZURE_LOCATION AZURE_ENV_NAME

# =====================================================
# Step 4: Select VM sizes for AKS node pools
#         (includes region availability + GPU quota checks)
# =====================================================
write_step "4" "Selecting VM sizes for AKS node pools..."

echo "   Querying available VM sizes in ${AZURE_LOCATION}..."

# Fetch CPU and GPU VM lists (pure az CLI, no temp files)
mapfile -t CPU_VMS < <(get_filtered_vm_sizes "$AZURE_LOCATION" "${CPU_VM_PREFIXES[@]}")
mapfile -t GPU_VMS < <(get_filtered_vm_sizes "$AZURE_LOCATION" "${GPU_VM_PREFIXES[@]}")

echo "   CPU sizes: ${#CPU_VMS[@]}  |  GPU sizes: ${#GPU_VMS[@]}"
echo ""
echo "   Choose a VM SKU for each AKS node pool."
echo "   The default is highlighted - press Enter to accept it."

# Determine current/default values
CURRENT_SYSTEM_VM="${SYSTEM_VM_SIZE:-$DEFAULT_SYSTEM_VM_SIZE}"
CURRENT_WORKLOAD_VM="${WORKLOAD_VM_SIZE:-$DEFAULT_WORKLOAD_VM_SIZE}"
CURRENT_DEEPSTREAM_VM="${DEEPSTREAM_GPU_VM_SIZE:-$DEFAULT_DEEPSTREAM_GPU_SIZE}"
CURRENT_INFERENCE_VM="${INFERENCE_GPU_VM_SIZE:-$DEFAULT_INFERENCE_GPU_SIZE}"

# CPU pools
show_vm_selection_menu "System (CPU)"   "SYSTEM_VM_SIZE"   CPU_VMS "$CURRENT_SYSTEM_VM"   "$AZURE_LOCATION"
SYSTEM_SKU="$SELECTED_VM_SKU"

show_vm_selection_menu "Workload (CPU)" "WORKLOAD_VM_SIZE" CPU_VMS "$CURRENT_WORKLOAD_VM" "$AZURE_LOCATION"
WORKLOAD_SKU="$SELECTED_VM_SKU"

# GPU pools (quota validated inline, node count determines total cores checked)
show_vm_selection_menu "Deepstream (GPU)" "DEEPSTREAM_GPU_VM_SIZE" GPU_VMS "$CURRENT_DEEPSTREAM_VM" "$AZURE_LOCATION" "$DEEPSTREAM_GPU_MAX_NODE_COUNT" "gpu"
DEEPSTREAM_GPU_VM_SIZE="$SELECTED_VM_SKU"

show_vm_selection_menu "Inference (GPU)" "INFERENCE_GPU_VM_SIZE" GPU_VMS "$CURRENT_INFERENCE_VM" "$AZURE_LOCATION" "$INFERENCE_GPU_MAX_NODE_COUNT" "gpu"
INFERENCE_GPU_VM_SIZE="$SELECTED_VM_SKU"

# =====================================================
# Step 5: Register required Azure resource providers
# =====================================================
write_step "5" "Checking Azure resource provider registrations..."

register_required_providers || true

# =====================================================
# Summary
# =====================================================
echo ""
write_banner "Pre-provision validation passed!"
echo ""
echo "  Subscription:    ${SUB_NAME:-$AZURE_SUBSCRIPTION_ID}"
echo "  Location:        ${AZURE_LOCATION}"
echo "  Environment:     ${AZURE_ENV_NAME}"
echo "  System CPU:      ${SYSTEM_SKU}"
echo "  Workload CPU:    ${WORKLOAD_SKU}"
echo "  Deepstream GPU:  ${DEEPSTREAM_GPU_VM_SIZE} (${DEEPSTREAM_GPU_MAX_NODE_COUNT} node(s))"
echo "  Inference GPU:   ${INFERENCE_GPU_VM_SIZE} (${INFERENCE_GPU_MAX_NODE_COUNT} node(s))"
echo "  Providers:       all registered"
echo "  Tools:           all present"
echo ""
echo "Proceeding with provisioning..."
