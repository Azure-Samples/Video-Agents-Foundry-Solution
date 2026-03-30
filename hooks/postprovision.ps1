# =============================================================================
# Post-Provision Script: Connect AKS to Azure Arc and deploy VI extension
# =============================================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/common.ps1"

$totalSteps = 10

Write-FoundryBanner -Phase "Post-Provision Setup"

if ($env:CREATE_IN_LOCAL -eq "false") {
    Log-Info "Skipping postprovision script for non-local deployment."
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
        Invoke-WithSpinner -Message "Installing Azure CLI extension: $ext" -Action {
            az extension add --name $ext --yes 2>$null
        } -SuccessMessage "Installed extension: $ext"
    }
}

# NOTE: Azure resource providers are registered in preprovision. No need to re-register here.

# =====================================================
# Authenticate and set subscription
# =====================================================
$EXPIRED_TOKEN = (az ad signed-in-user show --query 'id' -o tsv 2>$null)

if (-not $EXPIRED_TOKEN) {
    Log-Warning "No Azure user signed in. Please login."
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
Log-Step -Number 1 -Total $totalSteps -Title "Getting AKS Cluster Credentials"

$KubeContext = Invoke-WithSpinner -Message "Fetching AKS credentials" -Action {
    Connect-AksCluster
} -SuccessMessage "AKS credentials configured"

Write-KeyValue "Context" $KubeContext

# =====================================================
# Step 2: Install NVIDIA GPU Operator
# =====================================================
Log-Step -Number 2 -Total $totalSteps -Title "Installing NVIDIA GPU Operator ($gpuOperatorVersion)"

# Add NVIDIA Helm repo (idempotent)
Invoke-WithSpinner -Message "Adding NVIDIA Helm repo" -Action {
    helm repo add $NVIDIA_HELM_REPO_NAME $NVIDIA_HELM_REPO_URL 2>$null
    helm repo update 2>$null
} -SuccessMessage "NVIDIA Helm repo ready"

Invoke-WithSpinner -Message "Installing GPU Operator" -Action {
    helm upgrade -i gpu-operator --wait `
        -n $NS_GPU_OPERATOR --create-namespace `
        --version $gpuOperatorVersion `
        --kube-context $KubeContext `
        nvidia/gpu-operator 2>&1 | Out-Null
} -SuccessMessage "NVIDIA GPU Operator installed"

# =====================================================
# Step 3: Connect AKS to Azure Arc
# =====================================================
$ARC_CLUSTER_NAME = "${ARC_CLUSTER_PREFIX}$env:AZURE_AKS_CLUSTER_NAME"
Log-Step -Number 3 -Total $totalSteps -Title "Connecting AKS to Azure Arc"

Write-KeyValue "Arc cluster name" $ARC_CLUSTER_NAME

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
    Log-Success "Arc-connected cluster already exists. Skipping."
}
else {
    Invoke-WithSpinner -Message "Connecting cluster to Azure Arc" -Action {
        az connectedk8s connect `
            --name "$ARC_CLUSTER_NAME" `
            --resource-group "$env:AZURE_RESOURCE_GROUP" `
            --location "$env:AZURE_LOCATION" 2>&1 | Out-Null
    } -SuccessMessage "AKS cluster connected to Azure Arc"
}

# Save the Arc cluster name to azd env
azd env set AZURE_ARC_CLUSTER_NAME "$ARC_CLUSTER_NAME"

# =====================================================
# Step 4: Create Public IP and construct Endpoint URI
# =====================================================
Log-Step -Number 4 -Total $totalSteps -Title "Creating Public IP and Endpoint URI"

# Get AKS managed cluster resource group from Bicep output
$AKS_MC_RG = $env:AZURE_AKS_NODE_RESOURCE_GROUP

Write-KeyValue "MC resource group" $AKS_MC_RG

# Generate or reuse DNS label
if ($env:AZURE_DNS_LABEL) {
    $DNS_LABEL = $env:AZURE_DNS_LABEL
    Log-Info "Reusing existing DNS label: $DNS_LABEL"
}
else {
    $RANDOM_SUFFIX = Get-Random -Minimum 100 -Maximum 1000
    $DNS_LABEL = "$($env:AZURE_ENV_NAME)$RANDOM_SUFFIX"
    Log-Info "Generated DNS label: $DNS_LABEL"
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
    Log-Success "Public IP '$PUBLIC_IP_NAME' already exists. Skipping."
}
else {
    Invoke-WithSpinner -Message "Creating public IP '$PUBLIC_IP_NAME'" -Action {
        az network public-ip create `
            --resource-group "$AKS_MC_RG" `
            --name "$PUBLIC_IP_NAME" `
            --sku Standard `
            --allocation-method Static `
            --dns-name "$DNS_LABEL" 2>&1 | Out-Null
    } -SuccessMessage "Public IP '$PUBLIC_IP_NAME' created with DNS label '$DNS_LABEL'"
}

# Get the static IP address
$STATIC_IP = (az network public-ip show `
        --resource-group "$AKS_MC_RG" `
        --name "$PUBLIC_IP_NAME" `
        --query "ipAddress" -o tsv)

Write-KeyValue "Static IP" $STATIC_IP

# Construct endpoint URI (HTTP by default — switch to https:// after configuring SSL/TLS)
$VIDEO_INDEXER_ENDPOINT_URI = "http://${DNS_LABEL}.$($env:AZURE_LOCATION).cloudapp.azure.com"
Write-KeyValue "Endpoint URI" $VIDEO_INDEXER_ENDPOINT_URI
Log-Warning "Using HTTP. To enable HTTPS, configure SSL/TLS on the Nginx Ingress Controller."

# Persist to azd env
azd env set AZURE_DNS_LABEL "$DNS_LABEL"
azd env set AZURE_STATIC_IP "$STATIC_IP"
azd env set AZURE_VIDEO_INDEXER_ENDPOINT_URI "$VIDEO_INDEXER_ENDPOINT_URI"

# =====================================================
# Step 5: Enable App Routing (HTTP only)
# =====================================================
Log-Step -Number 5 -Total $totalSteps -Title "Enabling App Routing on AKS Cluster"

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
    Log-Success "App Routing already enabled. Skipping."
}
else {
    Invoke-WithSpinner -Message "Enabling App Routing" -Action {
        az aks approuting enable `
            -g "$env:AZURE_RESOURCE_GROUP" `
            -n "$env:AZURE_AKS_CLUSTER_NAME" 2>&1 | Out-Null
    } -SuccessMessage "App Routing enabled"
}

# =====================================================
# Step 6: Create Nginx Ingress Controller (HTTP only)
# =====================================================
Log-Step -Number 6 -Total $totalSteps -Title "Creating Nginx Ingress Controller"

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

Invoke-WithSpinner -Message "Applying Nginx Ingress Controller" -Action {
    $NGINX_YAML | kubectl --context $KubeContext apply -f - 2>&1 | Out-Null
} -SuccessMessage "Nginx Ingress Controller created"

# =====================================================
# Step 7: Verify Ingress Controller
# =====================================================
Log-Step -Number 7 -Total $totalSteps -Title "Verifying Ingress Controller"

Log-Info "Waiting for external IP assignment (up to ${TIMEOUT_INGRESS_IP}s)..."
$Elapsed = 0
$ExternalIP = $null
$spinner = Start-Spinner "Waiting for external IP"
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
    Invoke-SpinnerTick $spinner
    Start-Sleep -Seconds 5
    $Elapsed += 5
}

if ($ExternalIP) {
    Complete-Spinner -Spinner $spinner -Message "Ingress Controller is ready"
    Write-KeyValue "External IP" $ExternalIP
}
else {
    Fail-Spinner -Spinner $spinner -Message "External IP not assigned after ${TIMEOUT_INGRESS_IP}s"
    Log-Warning "Check manually: kubectl --context $KubeContext get svc nginx -n $NS_APP_ROUTING -w"
}

# =====================================================
# Step 8: Deploy Cert Manager via Bicep
# =====================================================
Log-Step -Number 8 -Total $totalSteps -Title "Deploying Cert Manager Extension"

Invoke-WithSpinner -Message "Deploying Cert Manager" -Action {
    az deployment group create `
        --resource-group "$env:AZURE_RESOURCE_GROUP" `
        --template-file ./infra/modules/cert-manager.bicep `
        --parameters `
        arcConnectedClusterName="$ARC_CLUSTER_NAME" 2>&1 | Out-Null
} -SuccessMessage "Cert Manager extension deployed"

# =====================================================
# Step 9: Deploy VI Arc Extension via Bicep
# =====================================================
Log-Step -Number 9 -Total $totalSteps -Title "Deploying Video Indexer Arc Extension"

Invoke-WithSpinner -Message "Deploying VI Arc extension" -Action {
    az deployment group create `
        --resource-group "$env:AZURE_RESOURCE_GROUP" `
        --template-file ./infra/modules/vi-extension.bicep `
        --parameters `
        arcConnectedClusterName="$ARC_CLUSTER_NAME" `
        accountId="$env:AZURE_VIDEO_INDEXER_ACCOUNT_ID" `
        accountResourceId="$env:AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID" `
        videoIndexerEndpointUri="$VIDEO_INDEXER_ENDPOINT_URI" `
        deepstreamNodeSelectorValue="$env:AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE" `
        inferenceNodeSelectorValue="$env:AZURE_INFERENCE_NODE_SELECTOR_VALUE" 2>&1 | Out-Null
} -SuccessMessage "Video Indexer Arc extension deployed"

# =====================================================
# Step 10: Post-deployment health checks
# =====================================================
Log-Step -Number 10 -Total $totalSteps -Title "Running Post-Deployment Health Checks"

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
$arcHealth = if ($arcStatus -eq "Connected") { "Pass" } else { "Warn" }
Write-HealthRow -Name "Arc connection" -Status $arcHealth -Detail $arcStatus

$gpuPods = Get-RunningPodCount -Namespace $NS_GPU_OPERATOR -KubeContext $KubeContext
$gpuHealth = if ($gpuPods -gt 0) { "Pass" } else { "Warn" }
Write-HealthRow -Name "GPU operator pods" -Status $gpuHealth -Detail "$gpuPods running"

$viPods = Get-RunningPodCount -Namespace $NS_VIDEO_INDEXER -KubeContext $KubeContext
$viHealth = if ($viPods -gt 0) { "Pass" } else { "Warn" }
Write-HealthRow -Name "VI extension pods" -Status $viHealth -Detail "$viPods running"

# =====================================================
# Summary
# =====================================================
Write-Host ""
Write-BoxBanner -Text "Post-Provision Complete" -Style Double

Write-Section "Deployed Resources"
Write-KeyValue "AKS Cluster"     $env:AZURE_AKS_CLUSTER_NAME
Write-KeyValue "Arc Cluster"     $ARC_CLUSTER_NAME
Write-KeyValue "VI Account"      $env:AZURE_VIDEO_INDEXER_ACCOUNT_NAME
Write-KeyValue "Storage Account" $env:AZURE_STORAGE_ACCOUNT_NAME
if ($env:AI_FOUNDRY_ACCOUNT_NAME) {
    Write-KeyValue "AI Foundry Hub"   $env:AI_FOUNDRY_ACCOUNT_NAME
    Write-KeyValue "AI Foundry Model" $env:AI_FOUNDRY_MODEL_DEPLOYMENT
    Write-KeyValue "AI Endpoint"      $env:AI_FOUNDRY_AI_SERVICES_ENDPOINT
}

Write-Host ""
Log-Success "Video Indexer portal: $VIDEO_INDEXER_ENDPOINT_URI"
Start-Process $VIDEO_INDEXER_ENDPOINT_URI
