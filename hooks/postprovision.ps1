# =============================================================================
# Post-Provision Script: Connect AKS to Azure Arc and deploy VI extension
# =============================================================================

$ErrorActionPreference = "Stop"

Write-Host "=============================================="
Write-Host "Post-provision: Video Indexer Arc Setup"
Write-Host "=============================================="

if ($env:CREATE_IN_LOCAL -eq "false") {
    Write-Host "Skipping postprovision script for non local."
    exit 0
}

# =====================================================
# Validate required environment variables
# =====================================================
$requiredVars = @(
    'AZURE_SUBSCRIPTION_ID',
    'AZURE_RESOURCE_GROUP',
    'AZURE_AKS_CLUSTER_NAME',
    'AZURE_LOCATION',
    'AZURE_ENV_NAME',
    'AZURE_VIDEO_INDEXER_ACCOUNT_ID',
    'AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID',
    'AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE'
)

$missing = $requiredVars | Where-Object { -not (Get-Item "env:$_" -ErrorAction SilentlyContinue) }
if ($missing) {
    Write-Error "The following required environment variables are not set:`n  $($missing -join "`n  ")`nRun 'azd env get-values' to check your environment."
    exit 1
}

# =====================================================
# Check prerequisites
# =====================================================
foreach ($cmd in @('helm', 'kubectl', 'az')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "'$cmd' is required but not found in PATH."
        exit 1
    }
}

foreach ($ext in @('connectedk8s', 'k8s-extension')) {
    $installed = az extension show --name $ext 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $installed) {
        Write-Host "Installing Azure CLI extension: $ext"
        az extension add --name $ext --yes
    }
}

# =====================================================
# Register required Azure providers
# =====================================================
Write-Host ""
Write-Host ">> Registering required Azure resource providers..."
foreach ($provider in @('Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.ExtendedLocation')) {
    az provider register --namespace $provider --wait false 2>$null
}
Write-Host "   Provider registration initiated."

# =====================================================
# Authenticate and set subscription
# =====================================================
$EXPIRED_TOKEN = (az ad signed-in-user show --query 'id' -o tsv 2>$null)

if (-not $EXPIRED_TOKEN) {
    Write-Host "No Azure user signed in. Please login."
    az login -o none
}

az account set -s $env:AZURE_SUBSCRIPTION_ID

# =====================================================
# Configuration
# =====================================================
$gpuOperatorVersion = if ($env:GPU_OPERATOR_VERSION) { $env:GPU_OPERATOR_VERSION } else { "v25.10.01" }

# =====================================================
# Step 1: Get AKS credentials
# =====================================================
Write-Host ""
Write-Host ">> Step 1: Getting AKS cluster credentials..."
az aks get-credentials `
    --resource-group "$env:AZURE_RESOURCE_GROUP" `
    --name "$env:AZURE_AKS_CLUSTER_NAME" `
    --admin `
    --overwrite-existing

$KubeContext = "$($env:AZURE_AKS_CLUSTER_NAME)-admin"

Write-Host "   AKS credentials configured (context: $KubeContext)."

# =====================================================
# Step 2: Install NVIDIA GPU Operator
# =====================================================
Write-Host ""
Write-Host ">> Step 2: Installing NVIDIA GPU Operator ($gpuOperatorVersion)..."

# Add NVIDIA Helm repo (idempotent)
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>$null
helm repo update

# Install or upgrade the GPU operator
helm upgrade -i gpu-operator --wait `
    -n gpu-operator --create-namespace `
    --version $gpuOperatorVersion `
    --kube-context $KubeContext `
    nvidia/gpu-operator

Write-Host "   NVIDIA GPU Operator installed."

# =====================================================
# Step 3: Connect AKS to Azure Arc
# =====================================================
$ARC_CLUSTER_NAME = "arc-$env:AZURE_AKS_CLUSTER_NAME"
Write-Host ""
Write-Host ">> Step 3: Connecting AKS cluster to Azure Arc as '$ARC_CLUSTER_NAME'..."

# Check if already connected
$ARC_EXISTS = $null
try {
    $ARC_EXISTS = (az connectedk8s show `
            --name "$ARC_CLUSTER_NAME" `
            --resource-group "$env:AZURE_RESOURCE_GROUP" `
            --query "name" -o tsv 2>$null)
}
catch {
    $ARC_EXISTS = $null
}

if ($ARC_EXISTS) {
    Write-Host "   Arc-connected cluster '$ARC_CLUSTER_NAME' already exists. Skipping."
}
else {
    az connectedk8s connect `
        --name "$ARC_CLUSTER_NAME" `
        --resource-group "$env:AZURE_RESOURCE_GROUP" `
        --location "$env:AZURE_LOCATION"
    Write-Host "   AKS cluster connected to Azure Arc."
}

# Save the Arc cluster name to azd env
azd env set AZURE_ARC_CLUSTER_NAME "$ARC_CLUSTER_NAME"

# =====================================================
# Step 4: Create Public IP and construct Endpoint URI
# =====================================================
Write-Host ""
Write-Host ">> Step 4: Creating Public IP and constructing Video Indexer endpoint URI..."

# Get AKS managed cluster resource group
$AKS_MC_RG = (az aks show `
        --resource-group "$env:AZURE_RESOURCE_GROUP" `
        --name "$env:AZURE_AKS_CLUSTER_NAME" `
        --query "nodeResourceGroup" -o tsv)

Write-Host "   AKS MC resource group: $AKS_MC_RG"

# Generate or reuse DNS label
if ($env:AZURE_DNS_LABEL) {
    $DNS_LABEL = $env:AZURE_DNS_LABEL
    Write-Host "   Reusing existing DNS label: $DNS_LABEL"
}
else {
    $RANDOM_SUFFIX = Get-Random -Minimum 100 -Maximum 1000
    $DNS_LABEL = "$($env:AZURE_ENV_NAME)$RANDOM_SUFFIX"
    Write-Host "   Generated DNS label: $DNS_LABEL"
}

$PUBLIC_IP_NAME = "$($env:AZURE_ENV_NAME)-inbound-ip"

# Check if public IP already exists
$PUBLIC_IP_EXISTS = $null
try {
    $PUBLIC_IP_EXISTS = (az network public-ip show `
            --resource-group "$AKS_MC_RG" `
            --name "$PUBLIC_IP_NAME" `
            --query "name" -o tsv 2>$null)
}
catch {
    $PUBLIC_IP_EXISTS = $null
}

if ($PUBLIC_IP_EXISTS) {
    Write-Host "   Public IP '$PUBLIC_IP_NAME' already exists. Skipping creation."
}
else {
    az network public-ip create `
        --resource-group "$AKS_MC_RG" `
        --name "$PUBLIC_IP_NAME" `
        --sku Standard `
        --allocation-method Static `
        --dns-name "$DNS_LABEL"
    Write-Host "   Public IP '$PUBLIC_IP_NAME' created with DNS label '$DNS_LABEL'."
}

# Get the static IP address
$STATIC_IP = (az network public-ip show `
        --resource-group "$AKS_MC_RG" `
        --name "$PUBLIC_IP_NAME" `
        --query "ipAddress" -o tsv)

Write-Host "   Static IP: $STATIC_IP"

# Construct endpoint URI
$VIDEO_INDEXER_ENDPOINT_URI = "https://${DNS_LABEL}.$($env:AZURE_LOCATION).cloudapp.azure.com"
Write-Host "   Endpoint URI: $VIDEO_INDEXER_ENDPOINT_URI"

# Persist to azd env
azd env set AZURE_DNS_LABEL "$DNS_LABEL"
azd env set AZURE_STATIC_IP "$STATIC_IP"
azd env set AZURE_VIDEO_INDEXER_ENDPOINT_URI "$VIDEO_INDEXER_ENDPOINT_URI"

# =====================================================
# Step 5: Enable App Routing (HTTP only)
# =====================================================
Write-Host ""
Write-Host ">> Step 5: Enabling App Routing on AKS cluster..."

$approutingEnabled = $null
try {
    $approutingEnabled = (az aks show `
            --resource-group "$env:AZURE_RESOURCE_GROUP" `
            --name "$env:AZURE_AKS_CLUSTER_NAME" `
            --query "ingressProfile.webAppRouting.enabled" -o tsv 2>$null)
}
catch {
    $approutingEnabled = $null
}

if ($approutingEnabled -eq "true") {
    Write-Host "   App Routing already enabled. Skipping."
}
else {
    az aks approuting enable `
        -g "$env:AZURE_RESOURCE_GROUP" `
        -n "$env:AZURE_AKS_CLUSTER_NAME"
    Write-Host "   App Routing enabled."
}

# =====================================================
# Step 6: Create Nginx Ingress Controller (HTTP only)
# =====================================================
Write-Host ""
Write-Host ">> Step 6: Creating Nginx Ingress Controller..."

$NGINX_YAML = @"
apiVersion: approuting.kubernetes.azure.com/v1alpha1
kind: NginxIngressController
metadata:
  name: nginx
spec:
  ingressClassName: nginx
  controllerNamePrefix: nginx
  loadBalancerAnnotations:
    service.beta.kubernetes.io/azure-pip-name: $PUBLIC_IP_NAME
    service.beta.kubernetes.io/azure-load-balancer-resource-group: $AKS_MC_RG
"@

$NGINX_YAML | kubectl --context $KubeContext apply -f -

Write-Host "   Nginx Ingress Controller created."

# =====================================================
# Step 7: Verify Ingress Controller
# =====================================================
Write-Host ""
Write-Host ">> Step 7: Verifying Ingress Controller..."

Write-Host "   Waiting for external IP assignment (up to 120s)..."
$Timeout = 120
$Elapsed = 0
$ExternalIP = $null
while ($Elapsed -lt $Timeout) {
    try {
        $ExternalIP = (kubectl --context $KubeContext get svc nginx -n app-routing-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null)
    }
    catch {
        $ExternalIP = $null
    }
    if ($ExternalIP) {
        break
    }
    Start-Sleep -Seconds 5
    $Elapsed += 5
}

if ($ExternalIP) {
    Write-Host "   Ingress Controller is ready."
    Write-Host "   External IP: $ExternalIP"
    kubectl --context $KubeContext get svc nginx -n app-routing-system
}
else {
    Write-Host "   WARNING: External IP not yet assigned after ${Timeout}s. Check manually:"
    Write-Host "   kubectl --context $KubeContext get svc nginx -n app-routing-system -w"
}

# =====================================================
# Step 8: Deploy Cert Manager via Bicep
# =====================================================
Write-Host ""
Write-Host ">> Step 8: Deploying Cert Manager extension..."

az deployment group create `
    --resource-group "$env:AZURE_RESOURCE_GROUP" `
    --template-file ./infra/modules/cert-manager.bicep `
    --parameters `
    arcConnectedClusterName="$ARC_CLUSTER_NAME"

Write-Host "   Cert Manager extension deployed."

# =====================================================
# Step 9: Deploy VI Arc Extension via Bicep
# =====================================================
Write-Host ""
Write-Host ">> Step 9: Deploying Video Indexer Arc extension..."

az deployment group create `
    --resource-group "$env:AZURE_RESOURCE_GROUP" `
    --template-file ./infra/modules/vi-extension.bicep `
    --parameters `
    arcConnectedClusterName="$ARC_CLUSTER_NAME" `
    accountId="$env:AZURE_VIDEO_INDEXER_ACCOUNT_ID" `
    accountResourceId="$env:AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID" `
    videoIndexerEndpointUri="$VIDEO_INDEXER_ENDPOINT_URI" `
    deepstreamNodeSelectorValue="$env:AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE"

Write-Host "   Video Indexer Arc extension deployed."

# =====================================================
# Step 10: Post-deployment health checks
# =====================================================
Write-Host ""
Write-Host ">> Step 10: Running post-deployment health checks..."

$arcStatus = $null
try {
    $arcStatus = (az connectedk8s show `
            --name "$ARC_CLUSTER_NAME" `
            --resource-group "$env:AZURE_RESOURCE_GROUP" `
            --query "connectivityStatus" -o tsv 2>$null)
}
catch {
    $arcStatus = "unknown"
}
Write-Host "   Arc connection status: $arcStatus"

try {
    $gpuPods = (kubectl --context $KubeContext get pods -n gpu-operator --field-selector=status.phase=Running --no-headers 2>$null | Measure-Object -Line).Lines
}
catch {
    $gpuPods = 0
}
Write-Host "   GPU operator pods running: $gpuPods"

try {
    $viPods = (kubectl --context $KubeContext get pods -n video-indexer --field-selector=status.phase=Running --no-headers 2>$null | Measure-Object -Line).Lines
}
catch {
    $viPods = 0
}
Write-Host "   VI extension pods running: $viPods"

# =====================================================
# Summary
# =====================================================
Write-Host ""
Write-Host "=============================================="
Write-Host "Post-provision completed successfully!"
Write-Host "=============================================="
Write-Host ""
Write-Host "Resources created:"
Write-Host "  - AKS Cluster:      $env:AZURE_AKS_CLUSTER_NAME"
Write-Host "  - Arc Cluster:      $ARC_CLUSTER_NAME"
Write-Host "  - VI Account:       $env:AZURE_VIDEO_INDEXER_ACCOUNT_NAME"
Write-Host "  - Storage Account:  $env:AZURE_STORAGE_ACCOUNT_NAME"
Write-Host ""

Write-Host "You can access the Video Indexer portal at: $VIDEO_INDEXER_ENDPOINT_URI"
Start-Process $VIDEO_INDEXER_ENDPOINT_URI
