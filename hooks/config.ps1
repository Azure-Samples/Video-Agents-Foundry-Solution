# =============================================================================
# Shared Configuration: Constants used across all PowerShell hooks
# =============================================================================
# Source this file via: . "$PSScriptRoot/config.ps1"

# ── Compute ──────────────────────────────────────────────────────────────────
$Script:VI_VM_SIZE            = "Standard_NC24ads_A100_v4"
$Script:VI_GPU_QUOTA_FAMILY   = "StandardNCADSA100v4Family"
$Script:VI_GPU_CORES_NEEDED   = 24

# ── Kubernetes Namespaces ────────────────────────────────────────────────────
$Script:NS_GPU_OPERATOR       = "gpu-operator"
$Script:NS_VIDEO_INDEXER      = "video-indexer"
$Script:NS_APP_ROUTING        = "app-routing-system"
$Script:NS_AZURE_ARC          = "azure-arc"
$Script:NS_CERT_MANAGER       = "cert-manager"

# ── Naming Conventions ──────────────────────────────────────────────────────
$Script:ARC_CLUSTER_PREFIX    = "arc-"

# ── Timeouts (seconds) ─────────────────────────────────────────────────────
$Script:TIMEOUT_NS_CLEANUP    = 60
$Script:TIMEOUT_NS_DELETE     = 120
$Script:TIMEOUT_INGRESS_IP    = 120

# ── Helm ────────────────────────────────────────────────────────────────────
$Script:NVIDIA_HELM_REPO_NAME = "nvidia"
$Script:NVIDIA_HELM_REPO_URL  = "https://helm.ngc.nvidia.com/nvidia"

# ── Azure URLs ──────────────────────────────────────────────────────────────
$Script:QUOTA_URL             = "https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas"

# ── Required Azure Resource Providers ───────────────────────────────────────
$Script:REQUIRED_PROVIDERS    = @(
    "Microsoft.Kubernetes",
    "Microsoft.KubernetesConfiguration",
    "Microsoft.ExtendedLocation",
    "Microsoft.ContainerService",
    "Microsoft.Network"
)
