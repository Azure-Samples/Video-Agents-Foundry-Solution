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

# ── CPU VM Catalog (for system/workload pools) ───────────────────────────
# Format: "SKU|Cores|RAM|Description"
CPU_VM_CATALOG=(
    "Standard_D4a_v4|4|16 GB|General purpose"
    "Standard_D8a_v4|8|32 GB|General purpose"
    "Standard_D16a_v4|16|64 GB|General purpose"
    "Standard_D32a_v4|32|128 GB|General purpose"
    "Standard_D48a_v4|48|192 GB|General purpose"
    "Standard_D4as_v5|4|16 GB|General purpose v5"
    "Standard_D8as_v5|8|32 GB|General purpose v5"
    "Standard_D16as_v5|16|64 GB|General purpose v5"
    "Standard_D32as_v5|32|128 GB|General purpose v5"
    "Standard_D48as_v5|48|192 GB|General purpose v5"
)

# ── GPU VM Catalog (for deepstream/inference pools) ──────────────────────
# Format: "SKU|Cores|RAM|GPU|QuotaFamily|Description"
GPU_VM_CATALOG=(
    "Standard_NC24ads_A100_v4|24|220 GB|1x A100 80GB|StandardNCADSA100v4Family|A100 (recommended)"
    "Standard_NC48ads_A100_v4|48|440 GB|2x A100 80GB|StandardNCADSA100v4Family|A100 dual"
    "Standard_NC96ads_A100_v4|96|880 GB|4x A100 80GB|StandardNCADSA100v4Family|A100 quad"
    "Standard_NV36ads_A10_v5|36|440 GB|1x A10 24GB|StandardNVADSA10v5Family|A10"
    "Standard_NV72ads_A10_v5|72|880 GB|2x A10 24GB|StandardNVADSA10v5Family|A10 dual"
    "Standard_NC40ads_H100_v5|40|320 GB|1x H100 80GB|StandardNCadsH100v5Family|H100"
    "Standard_NC80adis_H100_v5|80|640 GB|2x H100 80GB|StandardNCadsH100v5Family|H100 dual"
    "Standard_NC6s_v3|6|112 GB|1x V100 16GB|standardNCSv3Family|V100"
    "Standard_NC12s_v3|12|224 GB|2x V100 16GB|standardNCSv3Family|V100 dual"
    "Standard_NC24s_v3|24|448 GB|4x V100 16GB|standardNCSv3Family|V100 quad"
)

# ── GPU Family Lookup Map ────────────────────────────────────────────────
declare -A GPU_FAMILY_MAP
for entry in "${GPU_VM_CATALOG[@]}"; do
    sku=$(echo "$entry" | cut -d'|' -f1)
    family=$(echo "$entry" | cut -d'|' -f5)
    GPU_FAMILY_MAP["$sku"]="$family"
done

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
