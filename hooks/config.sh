#!/usr/bin/env bash
# =============================================================================
# Shared Configuration: Constants used across all Bash hooks
# =============================================================================
# Source this file via: source "$(dirname "$0")/config.sh"

# ── GPU Compute (set via azd env vars, defaults in main.bicepparam) ──────
# Deepstream GPU pool
DEEPSTREAM_GPU_VM_SIZE="${DEEPSTREAM_GPU_VM_SIZE:?Set via: azd env set DEEPSTREAM_GPU_VM_SIZE <value>}"
DEEPSTREAM_GPU_QUOTA_FAMILY="StandardNVADSA10v5Family"
DEEPSTREAM_GPU_MAX_NODE_COUNT="${DEEPSTREAM_GPU_MAX_NODE_COUNT:?Set via: azd env set DEEPSTREAM_GPU_MAX_NODE_COUNT <value>}"

# Inference GPU pool
INFERENCE_GPU_VM_SIZE="${INFERENCE_GPU_VM_SIZE:?Set via: azd env set INFERENCE_GPU_VM_SIZE <value>}"
INFERENCE_GPU_QUOTA_FAMILY="StandardNCADSA100v4Family"
INFERENCE_GPU_MAX_NODE_COUNT="${INFERENCE_GPU_MAX_NODE_COUNT:?Set via: azd env set INFERENCE_GPU_MAX_NODE_COUNT <value>}"

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
