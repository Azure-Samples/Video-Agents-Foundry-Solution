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
# Step 5: Validate region supports required VM size
# =====================================================
write_step "5" "Checking region capability for GPU VMs..."

VM_AVAILABLE=$(az vm list-sizes --location "$AZURE_LOCATION" \
    --query "[?name=='${VI_VM_SIZE}']" -o tsv 2>/dev/null || true)

if [ -z "$VM_AVAILABLE" ]; then
    echo "   ERROR: VM size '${VI_VM_SIZE}' is not available in region '${AZURE_LOCATION}'." >&2
    echo "   This VM is required for the GPU node pool." >&2
    echo "" >&2
    echo "   Available regions for ${VI_VM_SIZE} include:" >&2
    echo "     eastus, eastus2, westus2, westus3, southcentralus," >&2
    echo "     northeurope, westeurope, southeastasia, australiaeast" >&2
    echo "" >&2
    echo "   Change region with: azd env set AZURE_LOCATION <region>" >&2
    exit 1
fi

echo "   ${VI_VM_SIZE}: available in ${AZURE_LOCATION}"

# =====================================================
# Step 6: Check GPU VM quota
# =====================================================
write_step "6" "Checking GPU VM quota..."

QUOTA_JSON=$(az vm list-usage --location "$AZURE_LOCATION" \
    --query "[?contains(name.value, '${VI_GPU_QUOTA_FAMILY}')]" \
    -o json 2>/dev/null || echo "[]")

CURRENT_USAGE=$(echo "$QUOTA_JSON" | grep -o '"currentValue":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "0")
QUOTA_LIMIT=$(echo "$QUOTA_JSON" | grep -o '"limit":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "0")
AVAILABLE=$((QUOTA_LIMIT - CURRENT_USAGE))

if [ "$QUOTA_LIMIT" -eq 0 ]; then
    echo "   WARNING: Could not determine GPU quota for ${VI_VM_SIZE}." >&2
    echo "   Family: ${VI_GPU_QUOTA_FAMILY}" >&2
    echo "   This may indicate zero quota in this subscription/region." >&2
    echo "" >&2
    echo "   Request GPU quota at:" >&2
    echo "   ${QUOTA_URL}" >&2
    echo "" >&2
    echo "   Proceeding anyway - provisioning will fail if quota is insufficient." >&2
elif [ "$AVAILABLE" -lt "$VI_GPU_CORES_NEEDED" ]; then
    echo "   ERROR: Insufficient GPU quota in ${AZURE_LOCATION}." >&2
    echo "   VM Size:   ${VI_VM_SIZE} (${VI_GPU_CORES_NEEDED} cores)" >&2
    echo "   Available: ${AVAILABLE} cores (${CURRENT_USAGE}/${QUOTA_LIMIT} used)" >&2
    echo "   Required:  ${VI_GPU_CORES_NEEDED} cores" >&2
    echo "" >&2
    echo "   Request quota increase at:" >&2
    echo "   ${QUOTA_URL}" >&2
    exit 1
else
    echo "   GPU quota: ${AVAILABLE} cores available (${CURRENT_USAGE}/${QUOTA_LIMIT} used)"
    echo "   Required:  ${VI_GPU_CORES_NEEDED} cores for ${VI_VM_SIZE}"
fi

# =====================================================
# Summary
# =====================================================
echo ""
write_banner "Pre-provision validation passed!"
echo ""
echo "  Subscription: ${SUB_NAME:-$AZURE_SUBSCRIPTION_ID}"
echo "  Location:     ${AZURE_LOCATION}"
echo "  Environment:  ${AZURE_ENV_NAME}"
echo "  GPU VM:       ${VI_VM_SIZE} (${AVAILABLE:-?} cores available)"
echo "  Providers:    all registered"
echo "  Tools:        all present"
echo ""
echo "Proceeding with provisioning..."
