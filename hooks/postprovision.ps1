# =============================================================================
# Post-Provision Script: Connect AKS to Azure Arc and deploy VI extension
# =============================================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/common.ps1"

$totalSteps = 12

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
        Log-Info "Installing Azure CLI extension: $ext..."
        az extension add --name $ext --yes 2>$null
        Log-Success "Installed extension: $ext"
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

Log-Info "Fetching AKS credentials..."
$KubeContext = Connect-AksCluster
Log-Success "AKS credentials configured"
Write-KeyValue "Context" $KubeContext

# =====================================================
# Step 2: Install NVIDIA GPU Operator
# =====================================================
Log-Step -Number 2 -Total $totalSteps -Title "Installing NVIDIA GPU Operator ($gpuOperatorVersion)"

# Add NVIDIA Helm repo (idempotent)
Log-Info "Adding NVIDIA Helm repo..."
helm repo add $NVIDIA_HELM_REPO_NAME $NVIDIA_HELM_REPO_URL 2>$null
helm repo update 2>$null
Log-Success "NVIDIA Helm repo ready"

Log-Info "Installing GPU Operator (this may take a few minutes)..."
helm upgrade -i gpu-operator --wait `
    -n $NS_GPU_OPERATOR --create-namespace `
    --version $gpuOperatorVersion `
    --kube-context $KubeContext `
    nvidia/gpu-operator
Log-Success "NVIDIA GPU Operator installed"

# =====================================================
# Step 3: Connect AKS to Azure Arc
# =====================================================
$ARC_CLUSTER_NAME = "${ARC_CLUSTER_PREFIX}$env:AZURE_AKS_CLUSTER_NAME"
# Defensive clamp: Azure Arc cluster names must be <= 63 chars
if ($ARC_CLUSTER_NAME.Length -gt 63) {
    $ARC_CLUSTER_NAME = $ARC_CLUSTER_NAME.Substring(0, 63).TrimEnd('-')
}
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
    Log-Info "Connecting cluster to Azure Arc..."
    az connectedk8s connect `
        --name "$ARC_CLUSTER_NAME" `
        --resource-group "$env:AZURE_RESOURCE_GROUP" `
        --location "$env:AZURE_LOCATION"
    Log-Success "AKS cluster connected to Azure Arc"
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
    Log-Info "Creating public IP '$PUBLIC_IP_NAME'..."
    az network public-ip create `
        --resource-group "$AKS_MC_RG" `
        --name "$PUBLIC_IP_NAME" `
        --sku Standard `
        --allocation-method Static `
        --dns-name "$DNS_LABEL" 2>&1 | Out-Null
    Log-Success "Public IP '$PUBLIC_IP_NAME' created with DNS label '$DNS_LABEL'"
}

# Get the static IP address
$STATIC_IP = (az network public-ip show `
        --resource-group "$AKS_MC_RG" `
        --name "$PUBLIC_IP_NAME" `
        --query "ipAddress" -o tsv)

Write-KeyValue "Static IP" $STATIC_IP

$VIDEO_INDEXER_ENDPOINT_URI = "https://${DNS_LABEL}.$($env:AZURE_LOCATION).cloudapp.azure.com"
Write-KeyValue "Endpoint URI" $VIDEO_INDEXER_ENDPOINT_URI

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
    Log-Info "Enabling App Routing..."
    az aks approuting enable `
        -g "$env:AZURE_RESOURCE_GROUP" `
        -n "$env:AZURE_AKS_CLUSTER_NAME"
    Log-Success "App Routing enabled"
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

Log-Info "Applying Nginx Ingress Controller..."
$NGINX_YAML | kubectl --context $KubeContext apply -f -
Log-Success "Nginx Ingress Controller created"

# =====================================================
# Step 7: Verify Ingress Controller
# =====================================================
Log-Step -Number 7 -Total $totalSteps -Title "Verifying Ingress Controller"

Log-Info "Waiting for external IP assignment (up to ${TIMEOUT_INGRESS_IP}s)..."
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
    Log-Success "Ingress Controller is ready"
    Write-KeyValue "External IP" $ExternalIP
}
else {
    Log-Warning "External IP not assigned after ${TIMEOUT_INGRESS_IP}s"
    Log-Info "Check manually: kubectl --context $KubeContext get svc nginx -n $NS_APP_ROUTING -w"
}

# =====================================================
# Step 8: Deploy Cert Manager via Bicep
# =====================================================
Log-Step -Number 8 -Total $totalSteps -Title "Deploying Cert Manager Extension"

Log-Info "Deploying Cert Manager..."
az deployment group create `
    --resource-group "$env:AZURE_RESOURCE_GROUP" `
    --template-file ./infra/modules/cert-manager.bicep `
    --parameters `
    arcConnectedClusterName="$ARC_CLUSTER_NAME"
Log-Success "Cert Manager extension deployed"

# =====================================================
# Step 9: Deploy VI Arc Extension via Bicep
# =====================================================
Log-Step -Number 9 -Total $totalSteps -Title "Deploying Video Indexer Arc Extension"

$inferenceAgentEnabled = if ($env:CREATE_FOUNDRY_PROJECT -eq 'true') { 'false' } else { 'true' }
$mediaStreamerEnabled = if ($env:MEDIA_STREAMER_ENABLED -eq 'false') { 'false' } else { 'true' }

Log-Info "Deploying VI Arc extension (this may take several minutes)..."
az deployment group create `
    --resource-group "$env:AZURE_RESOURCE_GROUP" `
    --template-file ./infra/modules/vi-extension.bicep `
    --parameters `
    arcConnectedClusterName="$ARC_CLUSTER_NAME" `
    accountId="$env:AZURE_VIDEO_INDEXER_ACCOUNT_ID" `
    accountResourceId="$env:AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID" `
    videoIndexerEndpointUri="$VIDEO_INDEXER_ENDPOINT_URI" `
    deepstreamNodeSelectorValue="$env:AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE" `
    inferenceNodeSelectorValue="$env:AZURE_INFERENCE_NODE_SELECTOR_VALUE" `
    inferenceAgentEnabled=$inferenceAgentEnabled `
    mediaStreamerEnabled=$mediaStreamerEnabled
Log-Success "Video Indexer Arc extension deployed"


Log-Info "Assigning permissions to Arc extension managed identity..."
$principalId = (az k8s-extension show `
        --resource-group "$env:AZURE_RESOURCE_GROUP" `
        --cluster-name "$ARC_CLUSTER_NAME" `
        --cluster-type connectedClusters `
        --name videoindexer `
        --query "identity.principalId" -o tsv 2>$null)

$accountResourceId = $env:AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID

if (-not $principalId) {
    Log-Error "Extension managed identity principalId not found. Cannot assign permissions."
}
elseif (-not $accountResourceId) {
    Log-Error "Video Indexer account resource ID not found. Cannot assign permissions."
}
else {
    # TODO: Replace 'Contributor' with a purpose-built least-privilege role (e.g. 'Video Indexer Contributor')
    # when one becomes available. Currently scoped to the VI account resource only.
    Log-Info "Adding Role Assignment for principal '$principalId'..."

    # Check if the role assignment already exists before attempting to create
    $existingAssignment = (az role assignment list `
            --assignee $principalId `
            --role Contributor `
            --scope $accountResourceId `
            --query "[0].id" -o tsv 2>$null)

    if ($existingAssignment) {
        Log-Success "Role assignment already exists. Skipping."
    }
    else {
        $roleErr = $null
        az role assignment create `
            --assignee-object-id $principalId `
            --assignee-principal-type ServicePrincipal `
            --role Contributor `
            --scope $accountResourceId 2>&1 | ForEach-Object {
                if ($_ -match 'ERROR|WARN') { $roleErr = $_ }
            }
        if ($LASTEXITCODE -ne 0) {
            Log-Error "Failed to create role assignment: $roleErr"
            Log-Error "The VI extension may not function correctly without this permission."
        }
        else {
            Log-Success "Permissions assigned to Arc extension managed identity"
        }
    }
}


# =====================================================
# Acquire VI Extension Access Token (used by Steps 10-11)
# =====================================================
$viAccessToken = $null
$viApiBase = $null
$viHeaders = $null

if ($mediaStreamerEnabled -eq 'false') {
    Log-Info "Media streamer disabled (MEDIA_STREAMER_ENABLED=false). Skipping token acquisition, camera, and agent job setup."
}
else {
    $extensionId = (az k8s-extension show `
            --resource-group "$env:AZURE_RESOURCE_GROUP" `
            --cluster-name "$ARC_CLUSTER_NAME" `
            --cluster-type connectedClusters `
            --name videoindexer `
            --query "id" -o tsv 2>$null)

    if (-not $extensionId) {
        Log-Warning "Failed to retrieve VI extension ID. Skipping camera and agent job setup."
    }
    else {
        $armToken = (az account get-access-token --resource https://management.azure.com/ --query "accessToken" -o tsv 2>$null)
        if (-not $armToken) {
            Log-Warning "Failed to get ARM access token. Skipping camera and agent job setup."
        }
        else {
            Log-Info "Generating VI extension access token..."
            $tokenUrl = "https://management.azure.com$($env:AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID)/generateExtensionAccessToken?api-version=2023-06-02-preview"
            $tokenBody = @{
                permissionType = "Contributor"
                scope          = "Account"
                extensionId    = $extensionId
            } | ConvertTo-Json

            try {
                $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenUrl `
                    -Headers @{
                        "Authorization" = "Bearer $armToken"
                        "Content-Type"  = "application/json"
                    } `
                    -Body $tokenBody
                $viAccessToken = $tokenResponse.accessToken
            }
            catch {
                Log-Warning "Failed to generate VI extension access token: $($_.Exception.Message)"
            }

            if ($viAccessToken) {
                Log-Success "VI extension access token obtained"
                $viApiBase = "$VIDEO_INDEXER_ENDPOINT_URI/Accounts/$env:AZURE_VIDEO_INDEXER_ACCOUNT_ID"
                $viHeaders = @{
                    "Authorization" = "Bearer $viAccessToken"
                    "Content-Type"  = "application/json"
                }
                # TODO: Remove -SkipCertificateCheck once a valid TLS certificate is configured
                # on the Nginx Ingress Controller (e.g. via cert-manager ClusterIssuer).
                # The endpoint uses HTTPS but the ingress does not yet have a trusted certificate.
                $viSkipCert = $true
            }
        }
    }

    # =====================================================
    # Step 10: Create Sample Camera
    # =====================================================
    Log-Step -Number 10 -Total $totalSteps -Title "Creating Sample Camera"

    $cameraName = "flags"
    $cameraRtspUrl = "rtsp://media-server.video-indexer:8554/$cameraName"
    $cameraId = $null

    if (-not $viAccessToken) {
        Log-Warning "No VI access token available. Skipping camera creation."
    }
    else {
        Log-Info "Creating camera '$cameraName'..."
        $cameraBody = @{
            Name                       = $cameraName
            Description                = $cameraName
            RtspUrl                    = $cameraRtspUrl
            LiveStreamingEnabled       = $true
            RecordingEnabled           = $true
            IsPinned                   = $true
            RecordingsRetentionInHours = 72
            UseCameraNtp               = $false
        } | ConvertTo-Json -Depth 3

        try {
            $invokeParams = @{ Method = 'Post'; Uri = "$viApiBase/cameras"; Headers = $viHeaders; Body = $cameraBody }
            if ($viSkipCert) { $invokeParams['SkipCertificateCheck'] = $true }
            $cameraResponse = Invoke-RestMethod @invokeParams
            $cameraId = $cameraResponse.id
            Log-Success "Camera '$cameraName' created"
            Write-KeyValue "Camera ID" $cameraId
        }
        catch {
            Log-Warning "Failed to create camera: $($_.Exception.Message)"
        }
    }

    # =====================================================
    # Step 11: Create Agent Job
    # =====================================================
    Log-Step -Number 11 -Total $totalSteps -Title "Creating Agent Job"

    if (-not $viAccessToken) {
        Log-Warning "No VI access token available. Skipping agent job creation."
    }
    elseif (-not $cameraId) {
        Log-Warning "No camera available. Skipping agent job creation."
    }
    else {
        # Get the first available agent
        $agentId = $null
        try {
            $invokeParams = @{ Method = 'Get'; Uri = "$viApiBase/agents"; Headers = $viHeaders }
            if ($viSkipCert) { $invokeParams['SkipCertificateCheck'] = $true }
            $agentsResponse = Invoke-RestMethod @invokeParams
            $agent = $agentsResponse.results | Select-Object -First 1
            if ($agent) {
                $agentId = $agent.agentId
                Write-KeyValue "Agent" $agent.name
            }
        }
        catch {
            Log-Warning "Failed to query agents: $($_.Exception.Message)"
        }

        if (-not $agentId) {
            Log-Warning "No agents found. Skipping agent job creation."
        }
        else {
            Log-Info "Creating agent job..."
            $agentJobBody = @{
                agentId            = $agentId
                cameraId           = $cameraId
                name               = "sample-agent-job"
                description        = "Sample agent job created during provisioning"
                eventName          = "sample-event"
                enabled            = $true
                prompt             = 'In the current frame, is there a flag of a country? Answer shortly in a JSON format: {"isDetected": true if a flag was detected or false if not, "answer": a full frame and flag textual description}'
                callbackUrl        = ""
                intervalInSeconds  = 20
                retentionInSeconds = 86400
            } | ConvertTo-Json -Depth 3

            try {
                $invokeParams = @{ Method = 'Post'; Uri = "$viApiBase/AgentJobs"; Headers = $viHeaders; Body = $agentJobBody }
                if ($viSkipCert) { $invokeParams['SkipCertificateCheck'] = $true }
                $jobResponse = Invoke-RestMethod @invokeParams
                Log-Success "Agent job created"
                Write-KeyValue "Job ID" $jobResponse.id
            }
            catch {
                Log-Warning "Failed to create agent job: $($_.Exception.Message)"
            }
        }
    }

}

# =====================================================
# Step 12: Post-deployment health checks
# =====================================================
Log-Step -Number 12 -Total $totalSteps -Title "Running Post-Deployment Health Checks"

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
