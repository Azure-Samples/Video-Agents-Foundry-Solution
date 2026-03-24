# =============================================================================
# Post-Up Script: Deployment health dashboard and next steps
# =============================================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/common.ps1"

Write-Banner "Post-Up: Health Check & Deployment Summary"

$HealthIssues = 0

# =====================================================
# Get AKS credentials for kubectl access
# =====================================================
Write-Host ""
Write-Host ">> Getting AKS credentials..."

$HasClusterAccess = $false
if ($env:AZURE_RESOURCE_GROUP -and $env:AZURE_AKS_CLUSTER_NAME) {
    try {
        $KubeContext = Connect-AksCluster
        $HasClusterAccess = $true
    }
    catch {
        Write-Host "   WARNING: Could not get AKS credentials. Skipping Kubernetes health checks."
    }
}
else {
    Write-Host "   WARNING: AZURE_RESOURCE_GROUP or AZURE_AKS_CLUSTER_NAME not set."
    Write-Host "   Skipping Kubernetes health checks."
}

# =====================================================
# Step 1: AKS Cluster Health
# =====================================================
Write-Host ""
Write-Host ">> Step 1: AKS Cluster Health..."

if ($HasClusterAccess) {
    $aksState = $null
    try {
        $aksState = (az aks show -g $env:AZURE_RESOURCE_GROUP -n $env:AZURE_AKS_CLUSTER_NAME `
            --query "provisioningState" -o tsv 2>$null)
    }
    catch {
        $aksState = "Unknown"
    }

    if ($aksState -eq "Succeeded") {
        Write-Host "   AKS provisioning state: $aksState"
    }
    else {
        Write-Host "   AKS provisioning state: $aksState (expected: Succeeded)"
        $HealthIssues++
    }

    try {
        $totalNodes = (kubectl --context $KubeContext get nodes --no-headers 2>$null | Measure-Object -Line).Lines
        $readyNodes = (kubectl --context $KubeContext get nodes --no-headers 2>$null | Select-String " Ready " | Measure-Object -Line).Lines
        Write-Host "   Nodes: $readyNodes/$totalNodes Ready"
    }
    catch {
        Write-Host "   Nodes: unable to determine"
        $HealthIssues++
    }

    try {
        $gpuNodes = (kubectl --context $KubeContext get nodes -l "accelerator=nvidia" --no-headers 2>$null | Measure-Object -Line).Lines
        if ($gpuNodes -gt 0) {
            Write-Host "   GPU nodes: $gpuNodes detected"
        }
        else {
            Write-Host "   GPU nodes: none detected (may still be provisioning)"
            $HealthIssues++
        }
    }
    catch {
        Write-Host "   GPU nodes: unable to determine"
        $HealthIssues++
    }
}
else {
    Write-Host "   Skipped (no cluster access)"
}

# =====================================================
# Step 2: GPU Operator Health
# =====================================================
Write-Host ""
Write-Host ">> Step 2: GPU Operator Health..."

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
            Write-Host "   GPU Operator pods: $gpuRunning/$gpuTotal Running"
            if ($gpuRunning -lt $gpuTotal) {
                Write-Host "   Some pods are still initializing (GPU driver install can take several minutes)"
            }
        }
        catch {
            Write-Host "   GPU Operator pods: unable to determine"
        }
    }
    else {
        Write-Host "   GPU Operator namespace not found"
        $HealthIssues++
    }
}
else {
    Write-Host "   Skipped (no cluster access)"
}

# =====================================================
# Step 3: Arc Connection Health
# =====================================================
Write-Host ""
Write-Host ">> Step 3: Arc Connection Health..."

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

    if ($arcStatus -eq "Connected") {
        Write-Host "   Arc cluster: $arcClusterName (Connected)"
    }
    else {
        Write-Host "   Arc cluster: $arcClusterName ($arcStatus)"
        $HealthIssues++
    }

    if ($HasClusterAccess) {
        try {
            $arcPods = Get-TotalPodCount -Namespace $NS_AZURE_ARC -KubeContext $KubeContext
            Write-Host "   Arc agent pods: $arcPods"
        }
        catch {
            Write-Host "   Arc agent pods: unable to determine"
        }
    }
}
else {
    Write-Host "   Arc cluster name not set. Skipping."
    $HealthIssues++
}

# =====================================================
# Step 4: Ingress & Networking Health
# =====================================================
Write-Host ""
Write-Host ">> Step 4: Ingress & Networking Health..."

if ($HasClusterAccess) {
    try {
        $ingressPods = Get-TotalPodCount -Namespace $NS_APP_ROUTING -KubeContext $KubeContext
        Write-Host "   Ingress pods (app-routing-system): $ingressPods"
    }
    catch {
        Write-Host "   Ingress pods: unable to determine"
    }

    if ($env:AZURE_STATIC_IP) {
        Write-Host "   Public IP: $($env:AZURE_STATIC_IP)"
    }
    else {
        Write-Host "   Public IP: not configured"
    }

    if ($env:AZURE_DNS_LABEL -and $env:AZURE_LOCATION) {
        $fqdn = "$($env:AZURE_DNS_LABEL).$($env:AZURE_LOCATION).cloudapp.azure.com"
        Write-Host "   FQDN: $fqdn"

        try {
            $dnsResult = Resolve-DnsName $fqdn -ErrorAction SilentlyContinue
            if ($dnsResult) {
                Write-Host "   DNS resolution: OK"
            }
            else {
                Write-Host "   DNS resolution: pending (may take a few minutes to propagate)"
            }
        }
        catch {
            Write-Host "   DNS resolution: pending (may take a few minutes to propagate)"
        }
    }
}
else {
    Write-Host "   Skipped (no cluster access)"
}

# =====================================================
# Step 5: Video Indexer Extension Health
# =====================================================
Write-Host ""
Write-Host ">> Step 5: Video Indexer Extension Health..."

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

    if ($viState -eq "Succeeded") {
        Write-Host "   VI Extension: Provisioned"
    }
    else {
        Write-Host "   VI Extension: $viState"
        $HealthIssues++
    }

    if ($HasClusterAccess) {
        try {
            $viRunning = Get-RunningPodCount -Namespace $NS_VIDEO_INDEXER -KubeContext $KubeContext
            $viTotal = Get-TotalPodCount -Namespace $NS_VIDEO_INDEXER -KubeContext $KubeContext
            Write-Host "   VI pods: $viRunning/$viTotal Running"
        }
        catch {
            Write-Host "   VI pods: unable to determine"
        }
    }
}
else {
    Write-Host "   Skipped (no Arc cluster configured)"
}

# =====================================================
# Step 6: Cert Manager Health
# =====================================================
Write-Host ""
Write-Host ">> Step 6: Cert Manager Health..."

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
            Write-Host "   Cert Manager pods: $cmRunning/$cmTotal Running"
        }
        catch {
            Write-Host "   Cert Manager pods: unable to determine"
        }
    }
    else {
        Write-Host "   Cert Manager namespace not found"
        $HealthIssues++
    }
}
else {
    Write-Host "   Skipped (no cluster access)"
}

# =====================================================
# Summary Dashboard
# =====================================================
Write-Host ""
Write-Banner "Video Indexer Arc - Deployment Complete"
Write-Host ""
Write-Host "  Resource Group:  $(if ($env:AZURE_RESOURCE_GROUP) { $env:AZURE_RESOURCE_GROUP } else { 'n/a' })"
Write-Host "  AKS Cluster:     $(if ($env:AZURE_AKS_CLUSTER_NAME) { $env:AZURE_AKS_CLUSTER_NAME } else { 'n/a' })"
Write-Host "  Arc Cluster:     $(if ($env:AZURE_ARC_CLUSTER_NAME) { $env:AZURE_ARC_CLUSTER_NAME } else { 'n/a' })"
Write-Host "  Location:        $(if ($env:AZURE_LOCATION) { $env:AZURE_LOCATION } else { 'n/a' })"
Write-Host ""

if ($env:AZURE_VIDEO_INDEXER_ENDPOINT_URI) {
    Write-Host "  Video Indexer:   $($env:AZURE_VIDEO_INDEXER_ENDPOINT_URI)"
}

Write-Host ""
if ($HealthIssues -eq 0) {
    Write-Host "  Health: ALL CHECKS PASSED"
}
else {
    Write-Host "  Health: $HealthIssues issue(s) detected (see above)"
    Write-Host ""
    Write-Host "  Some components may still be initializing."
    Write-Host "  Re-check in a few minutes with:"
    Write-Host "    kubectl get pods -A"
}

# =====================================================
# Next Steps
# =====================================================
Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Next Steps"
Write-Host "----------------------------------------------"
Write-Host ""
if ($env:AZURE_VIDEO_INDEXER_ENDPOINT_URI) {
    Write-Host "  1. Access Video Indexer at:"
    Write-Host "     $($env:AZURE_VIDEO_INDEXER_ENDPOINT_URI)"
}
Write-Host "  2. Upload a video to verify end-to-end indexing"
Write-Host "  3. Monitor GPU utilization:"
Write-Host "     kubectl top nodes"
Write-Host "  4. View VI extension logs:"
Write-Host "     kubectl logs -n $NS_VIDEO_INDEXER -l app=videoindexer --tail=100"
Write-Host "  5. To tear down all resources:"
Write-Host "     azd down"
Write-Host ""
Write-Host "  Useful commands:"
Write-Host "    kubectl get pods -A               # All pods"
Write-Host "    kubectl get nodes -o wide          # Node details"
Write-Host "    az connectedk8s show -g $($env:AZURE_RESOURCE_GROUP) -n $($env:AZURE_ARC_CLUSTER_NAME)"
Write-Host ""
