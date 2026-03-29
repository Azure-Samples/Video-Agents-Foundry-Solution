# =============================================================================
# Shared Configuration: Constants used across all PowerShell hooks
# =============================================================================
# Source this file via: . "$PSScriptRoot/config.ps1"

# ── GPU Compute (set via azd env vars, defaults in main.bicepparam) ──────
# Deepstream GPU pool


$A100 = "Standard_NC24ads_A100_v4" # A10/A100/H100

$DeepstreamVmSize = $A100
$InferenceVmSize = $A100

$Script:DEEPSTREAM_GPU_VM_SIZE = if ($env:DEEPSTREAM_GPU_VM_SIZE) { $env:DEEPSTREAM_GPU_VM_SIZE } else {$DeepstreamVmSize }
$Script:DEEPSTREAM_GPU_MAX_NODE_COUNT = if ($env:DEEPSTREAM_GPU_MAX_NODE_COUNT) { [int]$env:DEEPSTREAM_GPU_MAX_NODE_COUNT } else { 1 }

# Inference GPU pool
$Script:INFERENCE_GPU_VM_SIZE = if ($env:INFERENCE_GPU_VM_SIZE) { $env:INFERENCE_GPU_VM_SIZE } else { $InferenceVmSize }
# Inference node count: 1 when Foundry handles model serving, 2 otherwise (mirrors main.bicep)
$Script:CREATE_FOUNDRY_PROJECT = if ($env:CREATE_FOUNDRY_PROJECT -eq 'true') { $true } else { $false }
$inferenceDefault = if ($CREATE_FOUNDRY_PROJECT) { 1 } else { 2 }
$Script:INFERENCE_GPU_MAX_NODE_COUNT = if ($env:INFERENCE_GPU_MAX_NODE_COUNT) { [int]$env:INFERENCE_GPU_MAX_NODE_COUNT } else { $inferenceDefault }

# ── CPU VM Catalog (for system/workload pools) ───────────────────────────
$Script:CPU_VM_CATALOG = @(
    @{ Sku = "Standard_D4a_v4";   Cores = 4;  RAM = "16 GB";  Desc = "General purpose" }
    @{ Sku = "Standard_D8a_v4";   Cores = 8;  RAM = "32 GB";  Desc = "General purpose" }
    @{ Sku = "Standard_D16a_v4";  Cores = 16; RAM = "64 GB";  Desc = "General purpose" }
    @{ Sku = "Standard_D32a_v4";  Cores = 32; RAM = "128 GB"; Desc = "General purpose" }
    @{ Sku = "Standard_D48a_v4";  Cores = 48; RAM = "192 GB"; Desc = "General purpose" }
    @{ Sku = "Standard_D4as_v5";  Cores = 4;  RAM = "16 GB";  Desc = "General purpose v5" }
    @{ Sku = "Standard_D8as_v5";  Cores = 8;  RAM = "32 GB";  Desc = "General purpose v5" }
    @{ Sku = "Standard_D16as_v5"; Cores = 16; RAM = "64 GB";  Desc = "General purpose v5" }
    @{ Sku = "Standard_D32as_v5"; Cores = 32; RAM = "128 GB"; Desc = "General purpose v5" }
    @{ Sku = "Standard_D48as_v5"; Cores = 48; RAM = "192 GB"; Desc = "General purpose v5" }
)

# ── GPU VM Catalog (for deepstream/inference pools) ──────────────────────
$Script:GPU_VM_CATALOG = @(
    @{ Sku = "Standard_NC24ads_A100_v4";  Cores = 24; RAM = "220 GB"; GPU = "1x A100 80GB"; Family = "StandardNCADSA100v4Family"; Desc = "A100 (recommended)" }
    @{ Sku = "Standard_NC48ads_A100_v4";  Cores = 48; RAM = "440 GB"; GPU = "2x A100 80GB"; Family = "StandardNCADSA100v4Family"; Desc = "A100 dual" }
    @{ Sku = "Standard_NC96ads_A100_v4";  Cores = 96; RAM = "880 GB"; GPU = "4x A100 80GB"; Family = "StandardNCADSA100v4Family"; Desc = "A100 quad" }
    @{ Sku = "Standard_NV36ads_A10_v5";   Cores = 36; RAM = "440 GB"; GPU = "1x A10 24GB";  Family = "StandardNVADSA10v5Family";  Desc = "A10" }
    @{ Sku = "Standard_NV72ads_A10_v5";   Cores = 72; RAM = "880 GB"; GPU = "2x A10 24GB";  Family = "StandardNVADSA10v5Family";  Desc = "A10 dual" }
    @{ Sku = "Standard_NC40ads_H100_v5";  Cores = 40; RAM = "320 GB"; GPU = "1x H100 80GB"; Family = "StandardNCadsH100v5Family"; Desc = "H100" }
    @{ Sku = "Standard_NC80adis_H100_v5"; Cores = 80; RAM = "640 GB"; GPU = "2x H100 80GB"; Family = "StandardNCadsH100v5Family"; Desc = "H100 dual" }
    @{ Sku = "Standard_NC6s_v3";          Cores = 6;  RAM = "112 GB"; GPU = "1x V100 16GB"; Family = "StandardNCSv3Family";       Desc = "V100" }
    @{ Sku = "Standard_NC12s_v3";         Cores = 12; RAM = "224 GB"; GPU = "2x V100 16GB"; Family = "StandardNCSv3Family";       Desc = "V100 dual" }
    @{ Sku = "Standard_NC24s_v3";         Cores = 24; RAM = "448 GB"; GPU = "4x V100 16GB"; Family = "StandardNCSv3Family";       Desc = "V100 quad" }
)

# ── GPU Family Lookup Map ────────────────────────────────────────────────
$Script:GPU_FAMILY_MAP = @{}
foreach ($entry in $Script:GPU_VM_CATALOG) {
    $Script:GPU_FAMILY_MAP[$entry.Sku] = $entry.Family
}

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
