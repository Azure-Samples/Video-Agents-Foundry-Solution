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
