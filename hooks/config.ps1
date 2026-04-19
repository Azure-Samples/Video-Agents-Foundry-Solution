# =============================================================================
# Shared Configuration: Constants used across all PowerShell hooks
# =============================================================================
# Source this file via: . "$PSScriptRoot/config.ps1"

# ── Foundry Identity ────────────────────────────────────────────────────────
$script:FoundryVersion = "1.0.0"
$script:FoundryName    = "Video Agents Foundry Solution"

# ── VM Size Defaults ─────────────────────────────────────────────────────
# These are the fallback values when no env var is set.
# The interactive menu (Step 4) lets the user override them.

$Script:DEFAULT_SYSTEM_VM_SIZE      = "Standard_D4a_v4"
$Script:DEFAULT_WORKLOAD_VM_SIZE    = "Standard_D32a_v4"
$Script:DEFAULT_DEEPSTREAM_GPU_SIZE = "Standard_NC24ads_A100_v4"
$Script:DEFAULT_INFERENCE_GPU_SIZE  = "Standard_NC24ads_A100_v4"

# ── VM name-prefix filters (used to split az vm list-sizes into CPU / GPU) ─
$Script:CPU_VM_PREFIXES = @('Standard_D')
$Script:GPU_VM_PREFIXES = @('Standard_NC', 'Standard_NV', 'Standard_ND')

# ── Recommended VM families per pool ──────────────────────────────────────
# Each entry is a regex pattern matched against VM names from az vm list-sizes.
# We pick up to SIZES_PER_FAMILY sizes from each family that exist in the region.
# The menu also always includes the default SKU and a "Custom" option.
$Script:SIZES_PER_FAMILY = 3

# System pool: small VMs (2-16 cores) for control plane
$Script:SYSTEM_RECOMMENDED_FAMILIES = @(
    'D\d+a_v4$'       # Da v4:  Standard_D2a_v4 .. D16a_v4
    'D\d+as_v5$'      # Das v5: Standard_D2as_v5 .. D16as_v5
    'D\d+ds_v5$'      # Dds v5: Standard_D2ds_v5 .. D16ds_v5
    'D\d+as_v6$'      # Das v6: Standard_D2as_v6 .. D16as_v6
)
$Script:SYSTEM_MAX_CORES = 16

# Workload pool: large VMs (16-96 cores) for VI processing
$Script:WORKLOAD_RECOMMENDED_FAMILIES = @(
    'D\d+a_v4$'       # Da v4:  Standard_D32a_v4 .. D96a_v4
    'D\d+as_v5$'      # Das v5: Standard_D32as_v5 .. D96as_v5
    'D\d+ds_v5$'      # Dds v5: Standard_D32ds_v5 .. D96ds_v5
    'D\d+as_v6$'      # Das v6: Standard_D32as_v6 .. D96as_v6
)
$Script:WORKLOAD_MIN_CORES = 16

# Max node counts per pool (must match infra/modules/aks.bicep defaults).
# Used to size the quota filter on the VM selection menu
# (total cores needed = vmCores * maxNodes).
$Script:SYSTEM_MAX_NODE_COUNT   = if ($env:SYSTEM_MAX_NODE_COUNT)   { [int]$env:SYSTEM_MAX_NODE_COUNT }   else { 2 }
$Script:WORKLOAD_MAX_NODE_COUNT = if ($env:WORKLOAD_MAX_NODE_COUNT) { [int]$env:WORKLOAD_MAX_NODE_COUNT } else { 10 }

# GPU pools: all GPU families
$Script:GPU_RECOMMENDED_FAMILIES = @(
    'A100_v4$'         # A100: Standard_NC24ads_A100_v4, NC48ads, NC96ads
    'A10_v5$'          # A10:  Standard_NV6ads_A10_v5, NV18ads, NV36ads
    'H100_v5$'         # H100: Standard_NC40ads_H100_v5, NC80adis
    'NC\d+s_v3$'       # V100: Standard_NC6s_v3, NC12s_v3, NC24s_v3
)

# ── GPU VM name pattern → quota family mapping ───────────────────────────
# Used to resolve quota family from VM name without calling az vm list-skus.
# Keys are regex patterns, values are the exact family name from az vm list-usage.
$Script:GPU_QUOTA_FAMILY_MAP = [ordered]@{
    'A100_v4$'      = 'StandardNCADSA100v4Family'
    'A10_v5$'       = 'StandardNVADSA10v5Family'
    'H100_v5$'      = 'StandardNCadsH100v5Family'
    'NC\d+s_v3$'    = 'standardNCSv3Family'
    'NC\d+s_v2$'    = 'standardNCSv2Family'
    'NC\d+as_T4'    = 'Standard NCASv3_T4 Family'
    'A10_v4$'       = 'StandardNCADSA10v4Family'
    'NV\d+as_v4$'   = 'standardNVSv4Family'
    'NV\d+s_v3$'    = 'standardNVSv3Family'
}

# ── Foundry flag & inference node count ──────────────────────────────────
# createFoundryProject=true  → Foundry handles model serving → 1 inference GPU node
# createFoundryProject=false → self-hosted inference          → 2 inference GPU nodes
# Default must match infra/main.parameters.json (${CREATE_FOUNDRY_PROJECT=true}).
$Script:CREATE_FOUNDRY_PROJECT = if ([string]::IsNullOrEmpty($env:CREATE_FOUNDRY_PROJECT)) {
    $true
} else {
    ($env:CREATE_FOUNDRY_PROJECT -eq 'true')
}
$inferenceNodeDefault = if ($CREATE_FOUNDRY_PROJECT) { 1 } else { 2 }

# ── Resolved runtime values (env var wins, then default) ────────────────
$Script:DEEPSTREAM_GPU_VM_SIZE        = if ($env:DEEPSTREAM_GPU_VM_SIZE)        { $env:DEEPSTREAM_GPU_VM_SIZE }        else { $DEFAULT_DEEPSTREAM_GPU_SIZE }
$Script:INFERENCE_GPU_VM_SIZE         = if ($env:INFERENCE_GPU_VM_SIZE)         { $env:INFERENCE_GPU_VM_SIZE }         else { $DEFAULT_INFERENCE_GPU_SIZE }
$Script:DEEPSTREAM_GPU_MAX_NODE_COUNT = if ($env:DEEPSTREAM_GPU_MAX_NODE_COUNT) { [int]$env:DEEPSTREAM_GPU_MAX_NODE_COUNT } else { 1 }
$Script:INFERENCE_GPU_MAX_NODE_COUNT  = if ($env:INFERENCE_GPU_MAX_NODE_COUNT)  { [int]$env:INFERENCE_GPU_MAX_NODE_COUNT }  else { $inferenceNodeDefault }

# ── Kubernetes Namespaces ────────────────────────────────────────────────────
$Script:NS_GPU_OPERATOR = "gpu-operator"
$Script:NS_VIDEO_INDEXER = "video-indexer"
$Script:NS_APP_ROUTING = "app-routing-system"
$Script:NS_AZURE_ARC = "azure-arc"
$Script:NS_CERT_MANAGER = "cert-manager"

# ── Naming Conventions ──────────────────────────────────────────────────────
$Script:ARC_CLUSTER_PREFIX = "arc-"

# ── Timeouts (seconds) ─────────────────────────────────────────────────────
$Script:TIMEOUT_INGRESS_IP = 120

# ── Helm ────────────────────────────────────────────────────────────────────
$Script:NVIDIA_HELM_REPO_NAME = "nvidia"
$Script:NVIDIA_HELM_REPO_URL = "https://helm.ngc.nvidia.com/nvidia"

# ── Azure URLs ──────────────────────────────────────────────────────────────
$Script:QUOTA_URL = "https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas"
$Script:GPU_QUOTA_DOC_URL = "https://github.com/Azure-Samples/azure-video-indexer-samples/blob/master/VideoIndexerEnabledByArc/aks/AKS-CLUSTER-SETUP.md#how-to-request-gpu-quota"

# ── Required Azure Resource Providers ───────────────────────────────────────
$Script:REQUIRED_PROVIDERS = @(
    "Microsoft.Kubernetes",
    "Microsoft.KubernetesConfiguration",
    "Microsoft.ExtendedLocation"
)

# ── AI Model Defaults ──────────────────────────────────────────────────────
# Used by the model quota check in preprovision.
# Must match ai-foundry.bicep: format='OpenAI', sku.name='GlobalStandard'
$Script:DEFAULT_AI_MODEL_NAME            = "gpt-5.2"
$Script:DEFAULT_AI_MODEL_FORMAT          = "OpenAI"
$Script:DEFAULT_AI_MODEL_DEPLOYMENT_TYPE = "GlobalStandard"
$Script:AI_QUOTA_URL                     = "https://ai.azure.com/managementCenter/quota"
