# =============================================================================
# Post-Up Script: Deployment health dashboard and next steps
# =============================================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/common.ps1"

if ($env:SKIP_POST_PROVISION -eq 'true') {
    # CI / devcontainer mode. Skip health dashboard because kubectl + cluster
    # access not guaranteed. `azd up --no-prompt` may still have run a real
    # Bicep deployment — verify cluster health out-of-band if needed.
    Log-Info "Skipping postup health dashboard (SKIP_POST_PROVISION=true)."
    Log-Info "If a real Bicep deployment occurred, verify cluster health via 'az aks show' or the Azure Portal."
    exit 0
}

$totalSteps = 6
$HealthResults = @()

Write-FoundryBanner -Phase "Health Dashboard"

# =====================================================
# Get AKS credentials for kubectl access
# =====================================================
$HasClusterAccess = $false
if ($env:AZURE_RESOURCE_GROUP -and $env:AZURE_AKS_CLUSTER_NAME) {
    try {
        Log-Info "Getting AKS credentials..."
        $KubeContext = Connect-AksCluster
        $HasClusterAccess = $true
        Log-Success "AKS credentials configured"
    }
    catch {
        Log-Warning "Could not get AKS credentials. Skipping Kubernetes health checks."
    }
}
else {
    Log-Warning "AZURE_RESOURCE_GROUP or AZURE_AKS_CLUSTER_NAME not set."
    Log-Info "Skipping Kubernetes health checks."
}

# =====================================================
# Step 1: AKS Cluster Health
# =====================================================
Log-Step -Number 1 -Total $totalSteps -Title "AKS Cluster Health"

if ($HasClusterAccess) {
    $aksState = $null
    try {
        $aksState = (az aks show -g $env:AZURE_RESOURCE_GROUP -n $env:AZURE_AKS_CLUSTER_NAME `
            --query "provisioningState" -o tsv 2>$null)
    }
    catch {
        $aksState = "Unknown"
    }

    $aksStatus = if ($aksState -eq "Succeeded") { "Pass" } else { "Fail" }
    Write-HealthRow -Name "AKS provisioning state" -Status $aksStatus -Detail $aksState
    $HealthResults += @{ Name = "AKS provisioning state"; Status = $aksStatus; Detail = $aksState }

    try {
        $totalNodes = (kubectl --context $KubeContext get nodes --no-headers 2>$null | Measure-Object -Line).Lines
        $readyNodes = (kubectl --context $KubeContext get nodes --no-headers 2>$null | Select-String " Ready " | Measure-Object -Line).Lines
        $nodeStatus = if ($readyNodes -eq $totalNodes) { "Pass" } else { "Warn" }
        $nodeDetail = "$readyNodes/$totalNodes Ready"
    }
    catch {
        $nodeStatus = "Fail"
        $nodeDetail = "unable to determine"
    }
    Write-HealthRow -Name "Cluster nodes" -Status $nodeStatus -Detail $nodeDetail
    $HealthResults += @{ Name = "Cluster nodes"; Status = $nodeStatus; Detail = $nodeDetail }

    try {
        $gpuNodes = (kubectl --context $KubeContext get nodes -l "nvidia.com/gpu.present=true" --no-headers 2>$null | Measure-Object -Line).Lines
        if ($gpuNodes -gt 0) {
            $gpuNodeStatus = "Pass"
            $gpuNodeDetail = "$gpuNodes detected"
        }
        else {
            $gpuNodeStatus = "Warn"
            $gpuNodeDetail = "none detected (may still be provisioning)"
        }
    }
    catch {
        $gpuNodeStatus = "Fail"
        $gpuNodeDetail = "unable to determine"
    }
    Write-HealthRow -Name "GPU nodes" -Status $gpuNodeStatus -Detail $gpuNodeDetail
    $HealthResults += @{ Name = "GPU nodes"; Status = $gpuNodeStatus; Detail = $gpuNodeDetail }
}
else {
    Write-HealthRow -Name "AKS Cluster" -Status "Skip" -Detail "no cluster access"
    $HealthResults += @{ Name = "AKS Cluster"; Status = "Skip"; Detail = "no cluster access" }
}

# =====================================================
# Step 2: GPU Operator Health
# =====================================================
Log-Step -Number 2 -Total $totalSteps -Title "GPU Operator Health"

if ($HasClusterAccess) {
    $gpuNsExists = $null
    try {
        $gpuNsExists = kubectl --context $KubeContext get namespace $NS_GPU_OPERATOR --no-headers 2>$null
    }
    catch {
        $gpuNsExists = $null
    }

    if ($gpuNsExists) {
        try {
            $gpuRunning = Get-RunningPodCount -Namespace $NS_GPU_OPERATOR -KubeContext $KubeContext
            $gpuTotal = Get-TotalPodCount -Namespace $NS_GPU_OPERATOR -KubeContext $KubeContext
            $gpuPodStatus = if ($gpuRunning -eq $gpuTotal -and $gpuTotal -gt 0) { "Pass" } elseif ($gpuRunning -gt 0) { "Warn" } else { "Fail" }
            $gpuPodDetail = "$gpuRunning/$gpuTotal Running"
            if ($gpuRunning -lt $gpuTotal) {
                $gpuPodDetail += " (GPU driver install can take several minutes)"
            }
        }
        catch {
            $gpuPodStatus = "Fail"
            $gpuPodDetail = "unable to determine"
        }
    }
    else {
        $gpuPodStatus = "Fail"
        $gpuPodDetail = "namespace not found"
    }
    Write-HealthRow -Name "GPU Operator" -Status $gpuPodStatus -Detail $gpuPodDetail
    $HealthResults += @{ Name = "GPU Operator"; Status = $gpuPodStatus; Detail = $gpuPodDetail }
}
else {
    Write-HealthRow -Name "GPU Operator" -Status "Skip" -Detail "no cluster access"
    $HealthResults += @{ Name = "GPU Operator"; Status = "Skip"; Detail = "no cluster access" }
}

# =====================================================
# Step 3: Arc Connection Health
# =====================================================
Log-Step -Number 3 -Total $totalSteps -Title "Arc Connection Health"

$arcClusterName = $env:AZURE_ARC_CLUSTER_NAME
if ($arcClusterName) {
    $arcStatus = $null
    try {
        $arcStatus = (az connectedk8s show `
            --name $arcClusterName `
            --resource-group $env:AZURE_RESOURCE_GROUP `
            --query "connectivityStatus" -o tsv 2>$null)
    }
    catch {
        $arcStatus = "Unknown"
    }

    $arcHealth = if ($arcStatus -eq "Connected") { "Pass" } else { "Warn" }
    Write-HealthRow -Name "Arc connection" -Status $arcHealth -Detail "$arcClusterName ($arcStatus)"
    $HealthResults += @{ Name = "Arc connection"; Status = $arcHealth; Detail = "$arcClusterName ($arcStatus)" }

    if ($HasClusterAccess) {
        try {
            $arcPods = Get-TotalPodCount -Namespace $NS_AZURE_ARC -KubeContext $KubeContext
            $arcPodStatus = if ($arcPods -gt 0) { "Pass" } else { "Warn" }
            Write-HealthRow -Name "Arc agent pods" -Status $arcPodStatus -Detail "$arcPods running"
            $HealthResults += @{ Name = "Arc agent pods"; Status = $arcPodStatus; Detail = "$arcPods running" }
        }
        catch {
            Write-HealthRow -Name "Arc agent pods" -Status "Fail" -Detail "unable to determine"
            $HealthResults += @{ Name = "Arc agent pods"; Status = "Fail"; Detail = "unable to determine" }
        }
    }
}
else {
    Write-HealthRow -Name "Arc connection" -Status "Fail" -Detail "cluster name not set"
    $HealthResults += @{ Name = "Arc connection"; Status = "Fail"; Detail = "cluster name not set" }
}

# =====================================================
# Step 4: Ingress & Networking Health
# =====================================================
Log-Step -Number 4 -Total $totalSteps -Title "Ingress & Networking Health"

if ($HasClusterAccess) {
    try {
        $ingressPods = Get-TotalPodCount -Namespace $NS_APP_ROUTING -KubeContext $KubeContext
        $ingressStatus = if ($ingressPods -gt 0) { "Pass" } else { "Warn" }
        Write-HealthRow -Name "Ingress pods" -Status $ingressStatus -Detail "$ingressPods in $NS_APP_ROUTING"
        $HealthResults += @{ Name = "Ingress pods"; Status = $ingressStatus; Detail = "$ingressPods in $NS_APP_ROUTING" }
    }
    catch {
        Write-HealthRow -Name "Ingress pods" -Status "Fail" -Detail "unable to determine"
        $HealthResults += @{ Name = "Ingress pods"; Status = "Fail"; Detail = "unable to determine" }
    }

    if ($env:AZURE_STATIC_IP) {
        Write-HealthRow -Name "Public IP" -Status "Pass" -Detail $env:AZURE_STATIC_IP
        $HealthResults += @{ Name = "Public IP"; Status = "Pass"; Detail = $env:AZURE_STATIC_IP }
    }
    else {
        Write-HealthRow -Name "Public IP" -Status "Warn" -Detail "not configured"
        $HealthResults += @{ Name = "Public IP"; Status = "Warn"; Detail = "not configured" }
    }

    if ($env:AZURE_DNS_LABEL -and $env:AZURE_LOCATION) {
        $fqdn = "$($env:AZURE_DNS_LABEL).$($env:AZURE_LOCATION).cloudapp.azure.com"
        try {
            $dnsResult = Resolve-DnsName $fqdn -ErrorAction SilentlyContinue
            if ($dnsResult) {
                Write-HealthRow -Name "DNS resolution" -Status "Pass" -Detail $fqdn
                $HealthResults += @{ Name = "DNS resolution"; Status = "Pass"; Detail = $fqdn }
            }
            else {
                Write-HealthRow -Name "DNS resolution" -Status "Warn" -Detail "pending propagation"
                $HealthResults += @{ Name = "DNS resolution"; Status = "Warn"; Detail = "pending propagation" }
            }
        }
        catch {
            Write-HealthRow -Name "DNS resolution" -Status "Warn" -Detail "pending propagation"
            $HealthResults += @{ Name = "DNS resolution"; Status = "Warn"; Detail = "pending propagation" }
        }
    }
}
else {
    Write-HealthRow -Name "Ingress & Networking" -Status "Skip" -Detail "no cluster access"
    $HealthResults += @{ Name = "Ingress & Networking"; Status = "Skip"; Detail = "no cluster access" }
}

# =====================================================
# Step 5: Video Indexer Extension Health
# =====================================================
Log-Step -Number 5 -Total $totalSteps -Title "Video Indexer Extension Health"

if ($arcClusterName) {
    $viState = $null
    try {
        $viState = (az k8s-extension show `
            --resource-group $env:AZURE_RESOURCE_GROUP `
            --cluster-name $arcClusterName `
            --cluster-type connectedClusters `
            --name videoindexer `
            --query "provisioningState" -o tsv 2>$null)
    }
    catch {
        $viState = "Unknown"
    }

    $viExtStatus = if ($viState -eq "Succeeded") { "Pass" } else { "Warn" }
    Write-HealthRow -Name "VI Extension" -Status $viExtStatus -Detail $viState
    $HealthResults += @{ Name = "VI Extension"; Status = $viExtStatus; Detail = $viState }

    if ($HasClusterAccess) {
        try {
            $viRunning = Get-RunningPodCount -Namespace $NS_VIDEO_INDEXER -KubeContext $KubeContext
            $viTotal = Get-TotalPodCount -Namespace $NS_VIDEO_INDEXER -KubeContext $KubeContext
            $viPodStatus = if ($viRunning -eq $viTotal -and $viTotal -gt 0) { "Pass" } elseif ($viRunning -gt 0) { "Warn" } else { "Fail" }
            Write-HealthRow -Name "VI pods" -Status $viPodStatus -Detail "$viRunning/$viTotal Running"
            $HealthResults += @{ Name = "VI pods"; Status = $viPodStatus; Detail = "$viRunning/$viTotal Running" }
        }
        catch {
            Write-HealthRow -Name "VI pods" -Status "Fail" -Detail "unable to determine"
            $HealthResults += @{ Name = "VI pods"; Status = "Fail"; Detail = "unable to determine" }
        }
    }
}
else {
    Write-HealthRow -Name "VI Extension" -Status "Skip" -Detail "no Arc cluster configured"
    $HealthResults += @{ Name = "VI Extension"; Status = "Skip"; Detail = "no Arc cluster configured" }
}

# =====================================================
# Step 6: Cert Manager Health
# =====================================================
Log-Step -Number 6 -Total $totalSteps -Title "Cert Manager Health"

if ($HasClusterAccess) {
    $cmNsExists = $null
    try {
        $cmNsExists = kubectl --context $KubeContext get namespace $NS_CERT_MANAGER --no-headers 2>$null
    }
    catch {
        $cmNsExists = $null
    }

    if ($cmNsExists) {
        try {
            $cmRunning = Get-RunningPodCount -Namespace $NS_CERT_MANAGER -KubeContext $KubeContext
            $cmTotal = Get-TotalPodCount -Namespace $NS_CERT_MANAGER -KubeContext $KubeContext
            $cmStatus = if ($cmRunning -eq $cmTotal -and $cmTotal -gt 0) { "Pass" } elseif ($cmRunning -gt 0) { "Warn" } else { "Fail" }
            $cmDetail = "$cmRunning/$cmTotal Running"
        }
        catch {
            $cmStatus = "Fail"
            $cmDetail = "unable to determine"
        }
    }
    else {
        $cmStatus = "Fail"
        $cmDetail = "namespace not found"
    }
    Write-HealthRow -Name "Cert Manager" -Status $cmStatus -Detail $cmDetail
    $HealthResults += @{ Name = "Cert Manager"; Status = $cmStatus; Detail = $cmDetail }
}
else {
    Write-HealthRow -Name "Cert Manager" -Status "Skip" -Detail "no cluster access"
    $HealthResults += @{ Name = "Cert Manager"; Status = "Skip"; Detail = "no cluster access" }
}

# =====================================================
# Summary Dashboard
# =====================================================
$passed   = ($HealthResults | Where-Object { $_.Status -eq "Pass" }).Count
$failed   = ($HealthResults | Where-Object { $_.Status -eq "Fail" }).Count
$warnings = ($HealthResults | Where-Object { $_.Status -eq "Warn" }).Count
$total    = $HealthResults.Count

Write-Host ""
Write-BoxBanner -Text "Deployment Summary" -Style Double -Width 56
Write-Host ""

Write-Section "Resources"
Write-KeyValue "Resource Group" "$(if ($env:AZURE_RESOURCE_GROUP) { $env:AZURE_RESOURCE_GROUP } else { 'n/a' })"
Write-KeyValue "AKS Cluster"    "$(if ($env:AZURE_AKS_CLUSTER_NAME) { $env:AZURE_AKS_CLUSTER_NAME } else { 'n/a' })"
Write-KeyValue "Arc Cluster"    "$(if ($env:AZURE_ARC_CLUSTER_NAME) { $env:AZURE_ARC_CLUSTER_NAME } else { 'n/a' })"
Write-KeyValue "Location"       "$(if ($env:AZURE_LOCATION) { $env:AZURE_LOCATION } else { 'n/a' })"

Write-SummaryBlock -Passed $passed -Failed $failed -Warnings $warnings -Total $total

if ($failed -gt 0) {
    Log-Warning "Some components may still be initializing."
    Log-Info "Re-check in a few minutes with: kubectl get pods -A"
    Write-Host ""
}

# =====================================================
# Next Steps
# =====================================================
Write-Section "Next Steps"
Write-Host ""

if ($env:AZURE_VI_PORTAL_URL) {
    $portalUrl = $env:AZURE_VI_PORTAL_URL
    Log-Success "Video Indexer portal: $portalUrl"
    Write-KeyValue "1. Access portal" $portalUrl
    Start-Process $portalUrl
}
Write-KeyValue "2. Test chat" "Chat with video agent"
Write-KeyValue "3. Add camera"        "add custom cameras from RTSP streams"
Write-KeyValue "4. Tear down"         "azd down"

# SSL certificate warning
if ($env:AZURE_VIDEO_INDEXER_ENDPOINT_URI) {
    Write-Host ""
    Log-Warning "SSL Certificate Notice"
    Log-Info "The VI endpoint ($env:AZURE_VIDEO_INDEXER_ENDPOINT_URI) uses a self-signed certificate."
    Log-Info "Before using the VI Portal, you must trust the certificate in your browser:"
    Log-Info "  1. Open $env:AZURE_VIDEO_INDEXER_ENDPOINT_URI in your browser"
    Log-Info "  2. Accept the certificate warning / proceed to the site"
    Log-Info "  3. Return to the VI Portal - it will now connect to your endpoint"
}

Write-Host ""
