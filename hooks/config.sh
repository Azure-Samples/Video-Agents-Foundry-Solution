#!/usr/bin/env bash
# =============================================================================
# Shared Configuration: Constants used across all Bash hooks
# =============================================================================
# Source this file via: source "$(dirname "$0")/config.sh"

# ── Compute ──────────────────────────────────────────────────────────────────
VI_VM_SIZE="Standard_NC24ads_A100_v4"
VI_GPU_QUOTA_FAMILY="StandardNCADSA100v4Family"
VI_GPU_CORES_NEEDED=24

# ── Kubernetes Namespaces ────────────────────────────────────────────────────
NS_GPU_OPERATOR="gpu-operator"
NS_VIDEO_INDEXER="video-indexer"
NS_APP_ROUTING="app-routing-system"
NS_AZURE_ARC="azure-arc"
NS_CERT_MANAGER="cert-manager"

# ── Naming Conventions ──────────────────────────────────────────────────────
ARC_CLUSTER_PREFIX="arc-"

# ── Timeouts (seconds) ─────────────────────────────────────────────────────
TIMEOUT_NS_CLEANUP=60
TIMEOUT_NS_DELETE=120
TIMEOUT_INGRESS_IP=120

# ── Helm ────────────────────────────────────────────────────────────────────
NVIDIA_HELM_REPO_NAME="nvidia"
NVIDIA_HELM_REPO_URL="https://helm.ngc.nvidia.com/nvidia"

# ── Azure URLs ──────────────────────────────────────────────────────────────
QUOTA_URL="https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas"

# ── Required Azure Resource Providers ───────────────────────────────────────
REQUIRED_PROVIDERS=(
    "Microsoft.Kubernetes"
    "Microsoft.KubernetesConfiguration"
    "Microsoft.ExtendedLocation"
    "Microsoft.ContainerService"
    "Microsoft.Network"
)
