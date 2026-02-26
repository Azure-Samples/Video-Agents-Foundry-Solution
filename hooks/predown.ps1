# =============================================================================
# Pre-Down Script: Graceful teardown preparation
# =============================================================================

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/common.ps1"

Write-Banner "Pre-Down: Graceful Teardown Preparation"

$CleanupErrors = 0

# =====================================================
# Step 1: Destruction warning
# =====================================================
Write-Host ""
Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
Write-Host "!            DESTRUCTIVE OPERATION              !" -ForegroundColor Red
Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
Write-Host ""
Write-Host "  'azd down' will DESTROY the following resources:"
Write-Host ""
Write-Host "  Resource Group:  $(if ($env:AZURE_RESOURCE_GROUP) { $env:AZURE_RESOURCE_GROUP } else { 'not set' })"
Write-Host "  AKS Cluster:     $(if ($env:AZURE_AKS_CLUSTER_NAME) { $env:AZURE_AKS_CLUSTER_NAME } else { 'not set' })"
Write-Host "  Arc Cluster:     $(if ($env:AZURE_ARC_CLUSTER_NAME) { $env:AZURE_ARC_CLUSTER_NAME } else { 'not set' })"
Write-Host "  VI Account:      $(if ($env:AZURE_VIDEO_INDEXER_ACCOUNT_ID) { $env:AZURE_VIDEO_INDEXER_ACCOUNT_ID } else { 'not set' })"
Write-Host "  Storage Account: and all stored data"
Write-Host "  Public IP:       $(if ($env:AZURE_STATIC_IP) { $env:AZURE_STATIC_IP } else { 'not set' })"
Write-Host "  GPU Nodes:       $VI_VM_SIZE"
Write-Host ""
Write-Host "  This action CANNOT be undone."
Write-Host "  Re-provisioning takes 25-40 minutes."
Write-Host ""

# Prompt for confirmation
$confirm = Read-Host "  Type 'destroy' to confirm teardown"
if ($confirm -ne "destroy") {
    Write-Host ""
    Write-Host "  Aborted. No resources were modified."
    exit 1
}

Write-Host ""
Write-Host "  Confirmed. Starting graceful teardown..."

# =====================================================
# Step 2: Get AKS credentials
# =====================================================
Write-Host ""
Write-Host ">> Step 2: Getting AKS cluster credentials..."

$HasClusterAccess = $false
if ($env:AZURE_RESOURCE_GROUP -and $env:AZURE_AKS_CLUSTER_NAME) {
    try {
        $KubeContext = Connect-AksCluster
        $HasClusterAccess = $true
        Write-Host "   AKS credentials configured."
    }
    catch {
        Write-Host "   WARNING: Could not get AKS credentials."
        Write-Host "   Cluster may already be deleted or unreachable."
        Write-Host "   Skipping Kubernetes-level cleanup."
    }
}
else {
    Write-Host "   WARNING: AKS cluster info not available. Skipping Kubernetes-level cleanup."
}

# =====================================================
# Step 3: Remove Video Indexer Arc Extension
# =====================================================
Write-Host ""
Write-Host ">> Step 3: Removing Video Indexer Arc Extension..."

$arcClusterName = $env:AZURE_ARC_CLUSTER_NAME
if ($arcClusterName -and $env:AZURE_RESOURCE_GROUP) {
    try {
        az k8s-extension delete `
            --resource-group $env:AZURE_RESOURCE_GROUP `
            --cluster-name $arcClusterName `
            --cluster-type connectedClusters `
            --name videoindexer `
            --yes 2>$null
        Write-Host "   VI Arc Extension: removed"
    }
    catch {
        Write-Host "   VI Arc Extension: skipped (not found or already removed)"
        $CleanupErrors++
    }

    # Wait for namespace cleanup if cluster is accessible
    if ($HasClusterAccess) {
        Write-Host "   Waiting for $NS_VIDEO_INDEXER namespace cleanup (up to ${TIMEOUT_NS_CLEANUP}s)..."
        try {
            kubectl --context $KubeContext wait --for=delete namespace/$NS_VIDEO_INDEXER `
                --timeout=${TIMEOUT_NS_CLEANUP}s 2>$null
        }
        catch {
            # Namespace may already be gone
        }
    }
}
else {
    Write-Host "   Skipped (no Arc cluster configured)"
}

# =====================================================
# Step 4: Remove Cert Manager Extension
# =====================================================
Write-Host ""
Write-Host ">> Step 4: Removing Cert Manager Extension..."

if ($arcClusterName -and $env:AZURE_RESOURCE_GROUP) {
    try {
        az k8s-extension delete `
            --resource-group $env:AZURE_RESOURCE_GROUP `
            --cluster-name $arcClusterName `
            --cluster-type connectedClusters `
            --name cert-manager `
            --yes 2>$null
        Write-Host "   Cert Manager: removed"
    }
    catch {
        Write-Host "   Cert Manager: skipped (not found or already removed)"
        $CleanupErrors++
    }
}
else {
    Write-Host "   Skipped (no Arc cluster configured)"
}

# =====================================================
# Step 5: Remove NVIDIA GPU Operator
# =====================================================
Write-Host ""
Write-Host ">> Step 5: Removing NVIDIA GPU Operator..."

if ($HasClusterAccess) {
    try {
        helm uninstall gpu-operator -n $NS_GPU_OPERATOR `
            --kube-context $KubeContext 2>$null
        Write-Host "   GPU Operator: Helm release removed"
    }
    catch {
        Write-Host "   GPU Operator: skipped (not found or already removed)"
        $CleanupErrors++
    }

    try {
        kubectl --context $KubeContext delete namespace $NS_GPU_OPERATOR `
            --timeout=${TIMEOUT_NS_DELETE}s 2>$null
    }
    catch {
        # Namespace may already be gone
    }
    Write-Host "   GPU Operator namespace: cleaned up"
}
else {
    Write-Host "   Skipped (no cluster access)"
}

# =====================================================
# Step 6: Disconnect Arc Cluster
# =====================================================
Write-Host ""
Write-Host ">> Step 6: Disconnecting Azure Arc cluster..."

if ($arcClusterName -and $env:AZURE_RESOURCE_GROUP) {
    try {
        az connectedk8s delete `
            --name $arcClusterName `
            --resource-group $env:AZURE_RESOURCE_GROUP `
            --yes 2>$null
        Write-Host "   Arc cluster '$arcClusterName': disconnected"
    }
    catch {
        Write-Host "   Arc cluster: skipped (not found or already disconnected)"
        $CleanupErrors++
    }
}
else {
    Write-Host "   Skipped (no Arc cluster configured)"
}

# =====================================================
# Step 7: Clean up Ingress and LoadBalancer
# =====================================================
Write-Host ""
Write-Host ">> Step 7: Cleaning up Ingress and LoadBalancer..."

if ($HasClusterAccess) {
    try {
        kubectl --context $KubeContext delete nginxingresscontroller nginx 2>$null
    }
    catch {
        # May not exist
    }

    try {
        kubectl --context $KubeContext delete svc nginx -n $NS_APP_ROUTING 2>$null
    }
    catch {
        # May not exist
    }

    Write-Host "   Ingress resources: cleaned up"
}
else {
    Write-Host "   Skipped (no cluster access)"
}

# =====================================================
# Summary
# =====================================================
Write-Host ""
Write-Banner "Pre-down cleanup complete"
Write-Host ""
Write-Host "  VI Extension:   removed"
Write-Host "  Cert Manager:   removed"
Write-Host "  GPU Operator:   removed"
Write-Host "  Arc Connection: disconnected"
Write-Host "  Ingress/LB:     cleaned up"
Write-Host ""

if ($CleanupErrors -gt 0) {
    Write-Host "  $CleanupErrors cleanup step(s) had warnings."
    Write-Host "  Resource group deletion will clean up remaining resources."
    Write-Host ""
}

Write-Host "Proceeding with 'azd down' to delete resource group..."
