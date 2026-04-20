#!/bin/bash

# =============================================================================
# Pre-Up Validation: Validate environment variables before provisioning
# =============================================================================
# Runs as the azd 'preup' hook. Catches misconfigured env vars before Bicep
# starts (which saves time on expensive GPU provisioning failures).
# Pattern adapted from get-started-with-ai-agents/scripts/validate_env_vars.sh
# =============================================================================

set -eo pipefail
has_error=false

validate_env_var() {
    local var_name="$1"
    local pattern="$2"
    local example="$3"
    local value="${!var_name}"

    # Optional — skip if unset or empty
    [ -z "$value" ] && return 0

    if ! echo "$value" | grep -qE "$pattern"; then
        echo "  [ERROR] Invalid value for '$var_name': '$value'"
        echo "          Expected format: $example"
        has_error=true
    fi
}

echo ""
echo "  Validating environment variables..."
echo ""

# ── UUID format ──────────────────────────────────────────────────────────
uuid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
validate_env_var "AZURE_SUBSCRIPTION_ID" "$uuid_pattern" "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
validate_env_var "AZURE_PRINCIPAL_ID" "$uuid_pattern" "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# ── VM sizes must start with Standard_ ────────────────────────────────────
vm_pattern='^Standard_[A-Za-z0-9_]+$'
validate_env_var "SYSTEM_VM_SIZE" "$vm_pattern" "Standard_D4a_v4"
validate_env_var "WORKLOAD_VM_SIZE" "$vm_pattern" "Standard_D32a_v4"
validate_env_var "DEEPSTREAM_GPU_VM_SIZE" "$vm_pattern" "Standard_NC24ads_A100_v4"
validate_env_var "INFERENCE_GPU_VM_SIZE" "$vm_pattern" "Standard_NC24ads_A100_v4"

# ── Boolean flags ──────────────────────────────────────────────────────────
bool_pattern='^(true|false)$'
validate_env_var "CREATE_FOUNDRY_PROJECT" "$bool_pattern" "true or false"
validate_env_var "CREATE_ROLE_FOR_USER" "$bool_pattern" "true or false"
validate_env_var "MEDIA_STREAMER_ENABLED" "$bool_pattern" "true or false"

# ── Storage SKU ────────────────────────────────────────────────────────────
sku_pattern='^Standard_(LRS|ZRS|GRS)$'
validate_env_var "STORAGE_SKU_NAME" "$sku_pattern" "Standard_LRS, Standard_ZRS, or Standard_GRS"

# ── Location must be non-empty lowercase alphanumeric if set ───────────────
location_pattern='^[a-z0-9]+(-[a-z0-9]+)*$'
validate_env_var "AZURE_LOCATION" "$location_pattern" "eastus2"

if [ "$has_error" = true ]; then
    echo ""
    echo "  [FAILED] Environment validation failed. Fix the values above before provisioning."
    echo "           Use 'azd env set <VAR> <VALUE>' to correct them."
    echo ""
    exit 1
fi

echo "  [OK] Environment variables validated successfully."
echo ""
