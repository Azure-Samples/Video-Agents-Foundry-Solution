# =============================================================================
# Shared Configuration: Constants used across all PowerShell hooks
# =============================================================================
# Source this file via: . "$PSScriptRoot/config.ps1"

# ── GPU Compute (set via azd env vars, defaults in main.bicepparam) ──────
# Deepstream GPU pool

$A10 = "Standard_NV36ads_A10_v5"
$A10Family = "StandardNVADSA10v5Family"
$A100 = "Standard_NC24ads_A100_v4"
$A100Family = "StandardNCADSA100v4Family"
$T4 = "Standard_NC16as_T4_v3"
$T4Family = "Standard NCASv3_T4 Family"

$Script:DEEPSTREAM_GPU_VM_SIZE = if ($env:DEEPSTREAM_GPU_VM_SIZE) { $env:DEEPSTREAM_GPU_VM_SIZE } else { $T4 }
$Script:DEEPSTREAM_GPU_QUOTA_FAMILY = $T4Family
$Script:DEEPSTREAM_GPU_MAX_NODE_COUNT = if ($env:DEEPSTREAM_GPU_MAX_NODE_COUNT) { [int]$env:DEEPSTREAM_GPU_MAX_NODE_COUNT } else { 1 }

# Inference GPU pool
$Script:INFERENCE_GPU_VM_SIZE = if ($env:INFERENCE_GPU_VM_SIZE) { $env:INFERENCE_GPU_VM_SIZE } else { $T4 }
$Script:INFERENCE_GPU_QUOTA_FAMILY = $T4Family
$Script:INFERENCE_GPU_MAX_NODE_COUNT = if ($env:INFERENCE_GPU_MAX_NODE_COUNT) { [int]$env:INFERENCE_GPU_MAX_NODE_COUNT } else { 2 }

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
