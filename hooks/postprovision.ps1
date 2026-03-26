# =============================================================================
# Post-Provision Script: Connect AKS to Azure Arc and deploy VI extension
# =============================================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/common.ps1"

Write-Banner "Post-provision: Video Indexer Arc Setup"

if ($env:CREATE_IN_LOCAL -eq "false") {
    Write-Host "Skipping postprovision script for non local."
    exit 0
}

# =====================================================
# Validate required environment variables
# =====================================================
Assert-EnvVars @(
    'AZURE_SUBSCRIPTION_ID',
    'AZURE_RESOURCE_GROUP',
    'AZURE_AKS_CLUSTER_NAME',
    'AZURE_LOCATION',
    'AZURE_ENV_NAME',
    'AZURE_VIDEO_INDEXER_ACCOUNT_ID',
    'AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID',
    'AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE',
    'AZURE_AKS_NODE_RESOURCE_GROUP'
)

# NOTE: CLI tools (az, helm, kubectl) are validated in preprovision. No need to re-check here.

# =====================================================
# Ensure required Azure CLI extensions are installed
# =====================================================
foreach ($ext in @('connectedk8s', 'k8s-extension')) {
    $installed = az extension show --name $ext 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $installed) {
        Write-Host "Installing Azure CLI extension: $ext"
        az extension add --name $ext --yes
    }
}

# NOTE: Azure resource providers are registered in preprovision. No need to re-register here.

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
Write-Step "1" "Getting AKS cluster credentials..."
$KubeContext = Connect-AksCluster
Write-Host "   AKS credentials configured (context: $KubeContext)."

# =====================================================
# Step 2: Install NVIDIA GPU Operator
# =====================================================
Write-Step "2" "Installing NVIDIA GPU Operator ($gpuOperatorVersion)..."

# Add NVIDIA Helm repo (idempotent)
helm repo add $NVIDIA_HELM_REPO_NAME $NVIDIA_HELM_REPO_URL 2>$null
helm repo update

# Install or upgrade the GPU operator
helm upgrade -i gpu-operator --wait `
    -n $NS_GPU_OPERATOR --create-namespace `
    --version $gpuOperatorVersion `
    --kube-context $KubeContext `
    nvidia/gpu-operator

Write-Host "   NVIDIA GPU Operator installed."

# =====================================================
# Step 3: Connect AKS to Azure Arc
# =====================================================
$ARC_CLUSTER_NAME = "${ARC_CLUSTER_PREFIX}$env:AZURE_AKS_CLUSTER_NAME"
Write-Step "3" "Connecting AKS cluster to Azure Arc as '$ARC_CLUSTER_NAME'..."

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
Write-Step "4" "Creating Public IP and constructing Video Indexer endpoint URI..."

# Get AKS managed cluster resource group from Bicep output
$AKS_MC_RG = $env:AZURE_AKS_NODE_RESOURCE_GROUP

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

# Construct endpoint URI (HTTP by default — switch to https:// after configuring SSL/TLS)
$VIDEO_INDEXER_ENDPOINT_URI = "http://${DNS_LABEL}.$($env:AZURE_LOCATION).cloudapp.azure.com"
Write-Host "   Endpoint URI: $VIDEO_INDEXER_ENDPOINT_URI"
Write-Host "   NOTE: Using HTTP. To enable HTTPS, configure SSL/TLS on the Nginx Ingress Controller (see AKS-CLUSTER-SETUP.md)."

# Persist to azd env
azd env set AZURE_DNS_LABEL "$DNS_LABEL"
azd env set AZURE_STATIC_IP "$STATIC_IP"
azd env set AZURE_VIDEO_INDEXER_ENDPOINT_URI "$VIDEO_INDEXER_ENDPOINT_URI"

# =====================================================
# Step 5: Enable App Routing (HTTP only)
# =====================================================
Write-Step "5" "Enabling App Routing on AKS cluster..."

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
Write-Step "6" "Creating Nginx Ingress Controller..."

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
Write-Step "7" "Verifying Ingress Controller..."

Write-Host "   Waiting for external IP assignment (up to ${TIMEOUT_INGRESS_IP}s)..."
$Elapsed = 0
$ExternalIP = $null
while ($Elapsed -lt $TIMEOUT_INGRESS_IP) {
    try {
        $ExternalIP = (kubectl --context $KubeContext get svc nginx -n $NS_APP_ROUTING -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null)
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
    kubectl --context $KubeContext get svc nginx -n $NS_APP_ROUTING
}
else {
    Write-Host "   WARNING: External IP not yet assigned after ${TIMEOUT_INGRESS_IP}s. Check manually:"
    Write-Host "   kubectl --context $KubeContext get svc nginx -n $NS_APP_ROUTING -w"
}

# =====================================================
# Step 8: Deploy Cert Manager via Bicep
# =====================================================
Write-Step "8" "Deploying Cert Manager extension..."

az deployment group create `
    --resource-group "$env:AZURE_RESOURCE_GROUP" `
    --template-file ./infra/modules/cert-manager.bicep `
    --parameters `
    arcConnectedClusterName="$ARC_CLUSTER_NAME"

Write-Host "   Cert Manager extension deployed."

# =====================================================
# Step 9: Deploy VI Arc Extension via Bicep
# =====================================================
Write-Step "9" "Deploying Video Indexer Arc extension..."

az deployment group create `
    --resource-group "$env:AZURE_RESOURCE_GROUP" `
    --template-file ./infra/modules/vi-extension.bicep `
    --parameters `
    arcConnectedClusterName="$ARC_CLUSTER_NAME" `
    accountId="$env:AZURE_VIDEO_INDEXER_ACCOUNT_ID" `
    accountResourceId="$env:AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID" `
    videoIndexerEndpointUri="$VIDEO_INDEXER_ENDPOINT_URI" `
    deepstreamNodeSelectorValue="$env:AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE" `
    inferenceNodeSelectorValue="$env:AZURE_INFERENCE_NODE_SELECTOR_VALUE"

Write-Host "   Video Indexer Arc extension deployed."

# =====================================================
# Step 10: Post-deployment health checks
# =====================================================
Write-Step "10" "Running post-deployment health checks..."

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

$gpuPods = Get-RunningPodCount -Namespace $NS_GPU_OPERATOR -KubeContext $KubeContext
Write-Host "   GPU operator pods running: $gpuPods"

$viPods = Get-RunningPodCount -Namespace $NS_VIDEO_INDEXER -KubeContext $KubeContext
Write-Host "   VI extension pods running: $viPods"

# =====================================================
# Summary
# =====================================================
Write-Host ""
Write-Banner "Post-provision completed successfully!"
Write-Host ""
Write-Host "Resources created:"
Write-Host "  - AKS Cluster:      $env:AZURE_AKS_CLUSTER_NAME"
Write-Host "  - Arc Cluster:      $ARC_CLUSTER_NAME"
Write-Host "  - VI Account:       $env:AZURE_VIDEO_INDEXER_ACCOUNT_NAME"
Write-Host "  - Storage Account:  $env:AZURE_STORAGE_ACCOUNT_NAME"
if ($env:AI_FOUNDRY_ACCOUNT_NAME) {
    Write-Host "  - AI Foundry Hub:   $env:AI_FOUNDRY_ACCOUNT_NAME"
    Write-Host "  - AI Foundry Model: $env:AI_FOUNDRY_MODEL_DEPLOYMENT"
    Write-Host "  - AI Endpoint:      $env:AI_FOUNDRY_AI_SERVICES_ENDPOINT"
}
Write-Host ""

Write-Host "You can access the Video Indexer portal at: $VIDEO_INDEXER_ENDPOINT_URI"
Start-Process $VIDEO_INDEXER_ENDPOINT_URI
