# =============================================================================
# Shared Configuration: Constants used across all PowerShell hooks
# =============================================================================
# Source this file via: . "$PSScriptRoot/config.ps1"

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

# ── Foundry flag & inference node count ──────────────────────────────────
# createFoundryProject=true  → Foundry handles model serving → 1 inference GPU node
# createFoundryProject=false → self-hosted inference          → 2 inference GPU nodes
$Script:CREATE_FOUNDRY_PROJECT = ($env:CREATE_FOUNDRY_PROJECT -eq 'true')
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
