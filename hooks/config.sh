#!/usr/bin/env bash
# =============================================================================
# Shared Configuration: Constants used across all Bash hooks
# =============================================================================
# Source this file via: source "$(dirname "$0")/config.sh"

# ── Foundry Identity ────────────────────────────────────────────────────────
FOUNDRY_VERSION="1.0.0"
FOUNDRY_NAME="Video Agents Foundry Solution"

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

# ── Recommended VM families (4 families x 3 sizes each = 12 menu items) ──
# We pick up to 3 sizes from each family that exist in the region.
# The menu also always includes the default SKU and a "Custom" option.
# ── Recommended VM families per pool ──────────────────────────────────────
# Each entry is a regex pattern matched against VM names from az vm list-sizes.
# We pick up to SIZES_PER_FAMILY sizes from each family that exist in the region.
# The menu also always includes the default SKU and a "Custom" option.
SIZES_PER_FAMILY=3

# System pool: small VMs (2-16 cores) for control plane
SYSTEM_RECOMMENDED_FAMILIES=(
    "D[0-9]+a_v4$"       # Da v4:  Standard_D2a_v4 .. D16a_v4
    "D[0-9]+as_v5$"      # Das v5: Standard_D2as_v5 .. D16as_v5
    "D[0-9]+ds_v5$"      # Dds v5: Standard_D2ds_v5 .. D16ds_v5
    "D[0-9]+as_v6$"      # Das v6: Standard_D2as_v6 .. D16as_v6
)
SYSTEM_MAX_CORES=16

# Workload pool: large VMs (16-96 cores) for VI processing
WORKLOAD_RECOMMENDED_FAMILIES=(
    "D[0-9]+a_v4$"       # Da v4:  Standard_D32a_v4 .. D96a_v4
    "D[0-9]+as_v5$"      # Das v5: Standard_D32as_v5 .. D96as_v5
    "D[0-9]+ds_v5$"      # Dds v5: Standard_D32ds_v5 .. D96ds_v5
    "D[0-9]+as_v6$"      # Das v6: Standard_D32as_v6 .. D96as_v6
)
WORKLOAD_MIN_CORES=16

# GPU pools: all GPU families
GPU_RECOMMENDED_FAMILIES=(
    "A100_v4$"           # A100: Standard_NC24ads_A100_v4, NC48ads, NC96ads
    "A10_v5$"            # A10:  Standard_NV6ads_A10_v5, NV18ads, NV36ads
    "H100_v5$"           # H100: Standard_NC40ads_H100_v5, NC80adis
    "NC[0-9]+s_v3$"      # V100: Standard_NC6s_v3, NC12s_v3, NC24s_v3
)

# ── GPU VM name pattern → quota family mapping ───────────────────────────
# Used to resolve quota family from VM name without calling az vm list-skus.
# Parallel arrays: GPU_QUOTA_PATTERNS[i] is regex, GPU_QUOTA_FAMILIES[i] is the family name.
GPU_QUOTA_PATTERNS=(
    "A100_v4$"
    "A10_v5$"
    "H100_v5$"
    "NC[0-9]+s_v3$"
    "NC[0-9]+s_v2$"
    "NC[0-9]+as_T4"
    "A10_v4$"
    "NV[0-9]+as_v4$"
    "NV[0-9]+s_v3$"
)
GPU_QUOTA_FAMILIES=(
    "StandardNCADSA100v4Family"
    "StandardNVADSA10v5Family"
    "StandardNCadsH100v5Family"
    "standardNCSv3Family"
    "standardNCSv2Family"
    "Standard NCASv3_T4 Family"
    "StandardNCADSA10v4Family"
    "standardNVSv4Family"
    "standardNVSv3Family"
)

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

# ── AI Model Defaults ──────────────────────────────────────────────────────
# Used by the model quota check in preprovision.
# Must match ai-foundry.bicep: format='OpenAI', sku.name='GlobalStandard'
DEFAULT_AI_MODEL_NAME="gpt-5.2"
DEFAULT_AI_MODEL_FORMAT="OpenAI"
DEFAULT_AI_MODEL_DEPLOYMENT_TYPE="GlobalStandard"
AI_QUOTA_URL="https://ai.azure.com/managementCenter/quota"
