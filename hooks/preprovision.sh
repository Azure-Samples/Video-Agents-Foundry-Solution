#!/bin/bash

# =============================================================================
# Pre-Provision Script: Validate prerequisites before provisioning
# =============================================================================

set -e

echo "=============================================="
echo "Pre-provision: Validation & Pre-flight Checks"
echo "=============================================="

ERROR_COUNT=0

# =====================================================
# Step 1: Check Azure CLI authentication
# =====================================================
echo ""
echo ">> Step 1: Checking Azure CLI authentication..."

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
echo ""
echo ">> Step 2: Checking required CLI tools..."

for cmd in az helm kubectl; do
    if command -v "$cmd" >/dev/null 2>&1; then
        VERSION=$($cmd version --short 2>/dev/null || $cmd version --client --short 2>/dev/null || $cmd --version 2>/dev/null | head -1 || echo "installed")
        echo "   ${cmd}: OK (${VERSION})"
    else
        echo "   ${cmd}: MISSING" >&2
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
done

# Optional tools
for cmd in kubelogin jq; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "   ${cmd}: OK"
    else
        echo "   ${cmd}: not found (optional, but recommended)"
    fi
done

if [ "$ERROR_COUNT" -gt 0 ]; then
    echo "" >&2
    echo "   ERROR: ${ERROR_COUNT} required tool(s) missing. Install them before proceeding." >&2
    exit 1
fi

# =====================================================
# Step 3: Validate required environment variables
# =====================================================
echo ""
echo ">> Step 3: Validating pre-provision environment variables..."

MISSING_VARS=""
for var in AZURE_SUBSCRIPTION_ID AZURE_LOCATION AZURE_ENV_NAME; do
    eval val=\$$var 2>/dev/null || val=""
    if [ -z "$val" ]; then
        MISSING_VARS="${MISSING_VARS}  - ${var}
"
        echo "   ${var}: MISSING"
    else
        echo "   ${var}: ${val}"
    fi
done

if [ -n "$MISSING_VARS" ]; then
    echo "" >&2
    echo "   ERROR: The following required environment variables are not set:" >&2
    printf "%s" "$MISSING_VARS" >&2
    echo "   Set them with 'azd env set <KEY> <VALUE>'." >&2
    exit 1
fi

# =====================================================
# Step 4: Register required Azure resource providers
# =====================================================
echo ""
echo ">> Step 4: Checking Azure resource provider registrations..."

PROVIDERS_REGISTERING=0
for provider in Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.ExtendedLocation Microsoft.ContainerService Microsoft.Network; do
    STATE=$(az provider show -n "$provider" --query "registrationState" -o tsv 2>/dev/null || echo "Unknown")
    case "$STATE" in
        Registered)
            echo "   ${provider}: Registered"
            ;;
        Registering)
            echo "   ${provider}: Registering (in progress)"
            PROVIDERS_REGISTERING=$((PROVIDERS_REGISTERING + 1))
            ;;
        NotRegistered|Unregistered)
            echo "   ${provider}: Not registered - registering now..."
            az provider register --namespace "$provider" --wait false 2>/dev/null || true
            PROVIDERS_REGISTERING=$((PROVIDERS_REGISTERING + 1))
            ;;
        *)
            echo "   ${provider}: ${STATE} (unexpected state)"
            ;;
    esac
done

if [ "$PROVIDERS_REGISTERING" -gt 0 ]; then
    echo ""
    echo "   NOTE: ${PROVIDERS_REGISTERING} provider(s) are being registered."
    echo "   Registration can take 2-5 minutes. Provisioning will proceed,"
    echo "   but if it fails, wait a few minutes and retry."
fi

# =====================================================
# Step 5: Validate region supports required VM size
# =====================================================
echo ""
echo ">> Step 5: Checking region capability for GPU VMs..."

VM_SIZE="Standard_NC24ads_A100_v4"
VM_AVAILABLE=$(az vm list-sizes --location "$AZURE_LOCATION" \
    --query "[?name=='${VM_SIZE}']" -o tsv 2>/dev/null || true)

if [ -z "$VM_AVAILABLE" ]; then
    echo "   ERROR: VM size '${VM_SIZE}' is not available in region '${AZURE_LOCATION}'." >&2
    echo "   This VM is required for the GPU node pool." >&2
    echo "" >&2
    echo "   Available regions for ${VM_SIZE} include:" >&2
    echo "     eastus, eastus2, westus2, westus3, southcentralus," >&2
    echo "     northeurope, westeurope, southeastasia, australiaeast" >&2
    echo "" >&2
    echo "   Change region with: azd env set AZURE_LOCATION <region>" >&2
    exit 1
fi

echo "   ${VM_SIZE}: available in ${AZURE_LOCATION}"

# =====================================================
# Step 6: Check GPU VM quota
# =====================================================
echo ""
echo ">> Step 6: Checking GPU VM quota..."

QUOTA_JSON=$(az vm list-usage --location "$AZURE_LOCATION" \
    --query "[?contains(name.value, 'StandardNCADSA100v4Family')]" \
    -o json 2>/dev/null || echo "[]")

CURRENT_USAGE=$(echo "$QUOTA_JSON" | grep -o '"currentValue":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "0")
QUOTA_LIMIT=$(echo "$QUOTA_JSON" | grep -o '"limit":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "0")
AVAILABLE=$((QUOTA_LIMIT - CURRENT_USAGE))
NEEDED=24

if [ "$QUOTA_LIMIT" -eq 0 ]; then
    echo "   WARNING: Could not determine GPU quota for ${VM_SIZE}." >&2
    echo "   Family: StandardNCADSA100v4Family" >&2
    echo "   This may indicate zero quota in this subscription/region." >&2
    echo "" >&2
    echo "   Request GPU quota at:" >&2
    echo "   https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" >&2
    echo "" >&2
    echo "   Proceeding anyway - provisioning will fail if quota is insufficient." >&2
elif [ "$AVAILABLE" -lt "$NEEDED" ]; then
    echo "   ERROR: Insufficient GPU quota in ${AZURE_LOCATION}." >&2
    echo "   VM Size:   ${VM_SIZE} (${NEEDED} cores)" >&2
    echo "   Available: ${AVAILABLE} cores (${CURRENT_USAGE}/${QUOTA_LIMIT} used)" >&2
    echo "   Required:  ${NEEDED} cores" >&2
    echo "" >&2
    echo "   Request quota increase at:" >&2
    echo "   https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" >&2
    exit 1
else
    echo "   GPU quota: ${AVAILABLE} cores available (${CURRENT_USAGE}/${QUOTA_LIMIT} used)"
    echo "   Required:  ${NEEDED} cores for ${VM_SIZE}"
fi

# =====================================================
# Summary
# =====================================================
echo ""
echo "=============================================="
echo "Pre-provision validation passed!"
echo "=============================================="
echo ""
echo "  Subscription: ${SUB_NAME:-$AZURE_SUBSCRIPTION_ID}"
echo "  Location:     ${AZURE_LOCATION}"
echo "  Environment:  ${AZURE_ENV_NAME}"
echo "  GPU VM:       ${VM_SIZE} (${AVAILABLE:-?} cores available)"
echo "  Providers:    all registered"
echo "  Tools:        all present"
echo ""
echo "Proceeding with provisioning..."
