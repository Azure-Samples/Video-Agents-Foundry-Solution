#!/usr/bin/env bash
# =============================================================================
# Shared Configuration: Constants used across all Bash hooks
# =============================================================================
# Source this file via: source "$(dirname "$0")/config.sh"

# ── VM Size Defaults ─────────────────────────────────────────────────────
# These are the fallback values when no env var is set.
# The interactive menu (Step 4) lets the user override them.

DEFAULT_SYSTEM_VM_SIZE="Standard_D4a_v4"
DEFAULT_WORKLOAD_VM_SIZE="Standard_D32a_v4"
DEFAULT_DEEPSTREAM_GPU_SIZE="Standard_NC24ads_A100_v4"
DEFAULT_INFERENCE_GPU_SIZE="Standard_NC24ads_A100_v4"

# ── VM name-prefix filters (used to split az vm list-sizes into CPU / GPU) ─
CPU_VM_PREFIXES=("Standard_D")
GPU_VM_PREFIXES=("Standard_NC" "Standard_NV" "Standard_ND")

# ── Foundry flag & inference node count ──────────────────────────────────
# createFoundryProject=true  → Foundry handles model serving → 1 inference GPU node
# createFoundryProject=false → self-hosted inference          → 2 inference GPU nodes
CREATE_FOUNDRY_PROJECT="${CREATE_FOUNDRY_PROJECT:-false}"
if [ "$CREATE_FOUNDRY_PROJECT" = "true" ]; then
    _INFERENCE_NODE_DEFAULT=1
else
    _INFERENCE_NODE_DEFAULT=2
fi

# ── Resolved runtime values (env var wins, then default) ────────────────
DEEPSTREAM_GPU_VM_SIZE="${DEEPSTREAM_GPU_VM_SIZE:-$DEFAULT_DEEPSTREAM_GPU_SIZE}"
INFERENCE_GPU_VM_SIZE="${INFERENCE_GPU_VM_SIZE:-$DEFAULT_INFERENCE_GPU_SIZE}"
DEEPSTREAM_GPU_MAX_NODE_COUNT="${DEEPSTREAM_GPU_MAX_NODE_COUNT:-1}"
INFERENCE_GPU_MAX_NODE_COUNT="${INFERENCE_GPU_MAX_NODE_COUNT:-$_INFERENCE_NODE_DEFAULT}"

# ── Kubernetes Namespaces ────────────────────────────────────────────────────
NS_GPU_OPERATOR="gpu-operator"
NS_VIDEO_INDEXER="video-indexer"
NS_APP_ROUTING="app-routing-system"
NS_AZURE_ARC="azure-arc"
NS_CERT_MANAGER="cert-manager"

# ── Naming Conventions ──────────────────────────────────────────────────────
ARC_CLUSTER_PREFIX="arc-"

# ── Timeouts (seconds) ─────────────────────────────────────────────────────
TIMEOUT_INGRESS_IP=120

# ── Helm ────────────────────────────────────────────────────────────────────
NVIDIA_HELM_REPO_NAME="nvidia"
NVIDIA_HELM_REPO_URL="https://helm.ngc.nvidia.com/nvidia"

# ── Azure URLs ──────────────────────────────────────────────────────────────
QUOTA_URL="https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas"
GPU_QUOTA_DOC_URL="https://github.com/Azure-Samples/azure-video-indexer-samples/blob/master/VideoIndexerEnabledByArc/aks/AKS-CLUSTER-SETUP.md#how-to-request-gpu-quota"

# ── Required Azure Resource Providers ───────────────────────────────────────
REQUIRED_PROVIDERS=(
    "Microsoft.Kubernetes"
    "Microsoft.KubernetesConfiguration"
    "Microsoft.ExtendedLocation"
)
