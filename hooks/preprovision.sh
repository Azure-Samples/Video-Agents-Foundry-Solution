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
# Step 4: Register required Azure resource providers
# =====================================================
write_step "4" "Checking Azure resource provider registrations..."

register_required_providers || true

# =====================================================
# Step 5: Validate region supports required VM sizes
# =====================================================
write_step "5" "Checking region capability for GPU VMs..."

for GPU_VM in "$DEEPSTREAM_GPU_VM_SIZE" "$INFERENCE_GPU_VM_SIZE"; do
    VM_AVAILABLE=$(az vm list-sizes --location "$AZURE_LOCATION" \
        --query "[?name=='${GPU_VM}']" -o tsv 2>/dev/null || true)

    if [ -z "$VM_AVAILABLE" ]; then
        echo "   ERROR: VM size '${GPU_VM}' is not available in region '${AZURE_LOCATION}'." >&2
        echo "   This VM is required for a GPU node pool." >&2
        echo "" >&2
        echo "   Change region with: azd env set AZURE_LOCATION <region>" >&2
        exit 1
    fi

    echo "   ${GPU_VM}: available in ${AZURE_LOCATION}"
done

# =====================================================
# Step 6: Check GPU VM quota
# =====================================================
write_step "6" "Checking GPU VM quota..."

ALL_PASSED=true

# Check GPU quota for a single pool
# Args: pool_name, vm_size, quota_family, cores_per_vm, max_nodes
check_gpu_quota() {
    local POOL_NAME="$1" VM_SIZE="$2" FAMILY="$3" CORES_PER_VM="$4" MAX_NODES="$5"
    local CORES_NEEDED=$((CORES_PER_VM * MAX_NODES))

    QUOTA_JSON=$(az vm list-usage --location "$AZURE_LOCATION" \
        --query "[?contains(name.value, '${FAMILY}')]" \
        -o json 2>/dev/null || echo "[]")

    CURRENT_USAGE=$(echo "$QUOTA_JSON" | grep -o '"currentValue":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "0")
    QUOTA_LIMIT=$(echo "$QUOTA_JSON" | grep -o '"limit":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "0")
    AVAILABLE=$((QUOTA_LIMIT - CURRENT_USAGE))

    echo "   [${POOL_NAME}] ${VM_SIZE} — ${MAX_NODES} node(s) x ${CORES_PER_VM} cores = ${CORES_NEEDED} cores needed"

    if [ "$QUOTA_LIMIT" -eq 0 ]; then
        echo "   [${POOL_NAME}] WARNING: Could not determine quota (family: ${FAMILY})." >&2
        echo "   This may indicate zero quota in this subscription/region." >&2
        echo "   Request GPU quota at: ${QUOTA_URL}" >&2
        echo "   Proceeding anyway - provisioning will fail if quota is insufficient." >&2
    elif [ "$AVAILABLE" -lt "$CORES_NEEDED" ]; then
        echo "   [${POOL_NAME}] ERROR: Insufficient quota — ${AVAILABLE} cores available, ${CORES_NEEDED} required (${CURRENT_USAGE}/${QUOTA_LIMIT} used)" >&2
        echo "   Request quota increase at: ${QUOTA_URL}" >&2
        ALL_PASSED=false
    else
        echo "   [${POOL_NAME}] OK — ${AVAILABLE} cores available (${CURRENT_USAGE}/${QUOTA_LIMIT} used)"
    fi
}

check_gpu_quota "Deepstream" "$DEEPSTREAM_GPU_VM_SIZE" "$DEEPSTREAM_GPU_QUOTA_FAMILY" "$DEEPSTREAM_GPU_CORES_PER_VM" "$DEEPSTREAM_GPU_MAX_NODE_COUNT"
check_gpu_quota "Inference"  "$INFERENCE_GPU_VM_SIZE"  "$INFERENCE_GPU_QUOTA_FAMILY"  "$INFERENCE_GPU_CORES_PER_VM"  "$INFERENCE_GPU_MAX_NODE_COUNT"

if [ "$ALL_PASSED" = false ]; then
    exit 1
fi

# =====================================================
# Summary
# =====================================================
echo ""
write_banner "Pre-provision validation passed!"
echo ""
echo "  Subscription:    ${SUB_NAME:-$AZURE_SUBSCRIPTION_ID}"
echo "  Location:        ${AZURE_LOCATION}"
echo "  Environment:     ${AZURE_ENV_NAME}"
echo "  Deepstream GPU:  ${DEEPSTREAM_GPU_VM_SIZE} (${DEEPSTREAM_GPU_MAX_NODE_COUNT} node(s))"
echo "  Inference GPU:   ${INFERENCE_GPU_VM_SIZE} (${INFERENCE_GPU_MAX_NODE_COUNT} node(s))"
echo "  Providers:       all registered"
echo "  Tools:           all present"
echo ""
echo "Proceeding with provisioning..."
