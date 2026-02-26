#!/bin/bash

# =============================================================================
# Post-Up Script: Deployment health dashboard and next steps
# =============================================================================

set -e

echo "=============================================="
echo "Post-Up: Health Check & Deployment Summary"
echo "=============================================="

HEALTH_ISSUES=0

# =====================================================
# Get AKS credentials for kubectl access
# =====================================================
echo ""
echo ">> Getting AKS credentials..."

if [ -z "${AZURE_RESOURCE_GROUP:-}" ] || [ -z "${AZURE_AKS_CLUSTER_NAME:-}" ]; then
    echo "   WARNING: AZURE_RESOURCE_GROUP or AZURE_AKS_CLUSTER_NAME not set."
    echo "   Skipping Kubernetes health checks."
    HAS_CLUSTER_ACCESS=false
else
    az aks get-credentials \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --name "$AZURE_AKS_CLUSTER_NAME" \
        --admin \
        --overwrite-existing 2>/dev/null || {
        echo "   WARNING: Could not get AKS credentials. Skipping Kubernetes health checks."
        HAS_CLUSTER_ACCESS=false
    }
    HAS_CLUSTER_ACCESS=true
    KUBE_CONTEXT="${AZURE_AKS_CLUSTER_NAME}-admin"
fi

# =====================================================
# Step 1: AKS Cluster Health
# =====================================================
echo ""
echo ">> Step 1: AKS Cluster Health..."

if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
    AKS_STATE=$(az aks show -g "$AZURE_RESOURCE_GROUP" -n "$AZURE_AKS_CLUSTER_NAME" \
        --query "provisioningState" -o tsv 2>/dev/null || echo "Unknown")

    if [ "$AKS_STATE" = "Succeeded" ]; then
        echo "   AKS provisioning state: ${AKS_STATE}"
    else
        echo "   AKS provisioning state: ${AKS_STATE} (expected: Succeeded)"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi

    TOTAL_NODES=$(kubectl --context "$KUBE_CONTEXT" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    READY_NODES=$(kubectl --context "$KUBE_CONTEXT" get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
    echo "   Nodes: ${READY_NODES}/${TOTAL_NODES} Ready"

    GPU_NODES=$(kubectl --context "$KUBE_CONTEXT" get nodes -l "accelerator=nvidia" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [ "$GPU_NODES" -gt 0 ]; then
        echo "   GPU nodes: ${GPU_NODES} detected"
    else
        echo "   GPU nodes: none detected (may still be provisioning)"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi
else
    echo "   Skipped (no cluster access)"
fi

# =====================================================
# Step 2: GPU Operator Health
# =====================================================
echo ""
echo ">> Step 2: GPU Operator Health..."

if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
    GPU_NS_EXISTS=$(kubectl --context "$KUBE_CONTEXT" get namespace gpu-operator --no-headers 2>/dev/null || true)
    if [ -n "$GPU_NS_EXISTS" ]; then
        GPU_RUNNING=$(kubectl --context "$KUBE_CONTEXT" get pods -n gpu-operator \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
        GPU_TOTAL=$(kubectl --context "$KUBE_CONTEXT" get pods -n gpu-operator \
            --no-headers 2>/dev/null | wc -l | tr -d ' ')
        echo "   GPU Operator pods: ${GPU_RUNNING}/${GPU_TOTAL} Running"
        if [ "$GPU_RUNNING" -lt "$GPU_TOTAL" ]; then
            echo "   Some pods are still initializing (GPU driver install can take several minutes)"
        fi
    else
        echo "   GPU Operator namespace not found"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi
else
    echo "   Skipped (no cluster access)"
fi

# =====================================================
# Step 3: Arc Connection Health
# =====================================================
echo ""
echo ">> Step 3: Arc Connection Health..."

ARC_CLUSTER_NAME="${AZURE_ARC_CLUSTER_NAME:-}"
if [ -n "$ARC_CLUSTER_NAME" ]; then
    ARC_STATUS=$(az connectedk8s show \
        --name "$ARC_CLUSTER_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --query "connectivityStatus" -o tsv 2>/dev/null || echo "Unknown")

    if [ "$ARC_STATUS" = "Connected" ]; then
        echo "   Arc cluster: ${ARC_CLUSTER_NAME} (Connected)"
    else
        echo "   Arc cluster: ${ARC_CLUSTER_NAME} (${ARC_STATUS})"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi

    if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
        ARC_PODS=$(kubectl --context "$KUBE_CONTEXT" get pods -n azure-arc \
            --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        echo "   Arc agent pods: ${ARC_PODS}"
    fi
else
    echo "   Arc cluster name not set. Skipping."
    HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
fi

# =====================================================
# Step 4: Ingress & Networking Health
# =====================================================
echo ""
echo ">> Step 4: Ingress & Networking Health..."

if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
    INGRESS_PODS=$(kubectl --context "$KUBE_CONTEXT" get pods -n app-routing-system \
        --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    echo "   Ingress pods (app-routing-system): ${INGRESS_PODS}"

    if [ -n "${AZURE_STATIC_IP:-}" ]; then
        echo "   Public IP: ${AZURE_STATIC_IP}"
    else
        echo "   Public IP: not configured"
    fi

    if [ -n "${AZURE_DNS_LABEL:-}" ] && [ -n "${AZURE_LOCATION:-}" ]; then
        FQDN="${AZURE_DNS_LABEL}.${AZURE_LOCATION}.cloudapp.azure.com"
        echo "   FQDN: ${FQDN}"

        DNS_RESOLVED=$(host "$FQDN" 2>/dev/null | grep -c "has address" || \
            nslookup "$FQDN" 2>/dev/null | grep -c "Address:" || echo "0")
        if [ "$DNS_RESOLVED" -gt 0 ]; then
            echo "   DNS resolution: OK"
        else
            echo "   DNS resolution: pending (may take a few minutes to propagate)"
        fi
    fi
else
    echo "   Skipped (no cluster access)"
fi

# =====================================================
# Step 5: Video Indexer Extension Health
# =====================================================
echo ""
echo ">> Step 5: Video Indexer Extension Health..."

if [ -n "$ARC_CLUSTER_NAME" ]; then
    VI_STATE=$(az k8s-extension show \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --cluster-name "$ARC_CLUSTER_NAME" \
        --cluster-type connectedClusters \
        --name videoindexer \
        --query "provisioningState" -o tsv 2>/dev/null || echo "Unknown")

    if [ "$VI_STATE" = "Succeeded" ]; then
        echo "   VI Extension: Provisioned"
    else
        echo "   VI Extension: ${VI_STATE}"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi

    if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
        VI_RUNNING=$(kubectl --context "$KUBE_CONTEXT" get pods -n video-indexer \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        VI_TOTAL=$(kubectl --context "$KUBE_CONTEXT" get pods -n video-indexer \
            --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        echo "   VI pods: ${VI_RUNNING}/${VI_TOTAL} Running"
    fi
else
    echo "   Skipped (no Arc cluster configured)"
fi

# =====================================================
# Step 6: Cert Manager Health
# =====================================================
echo ""
echo ">> Step 6: Cert Manager Health..."

if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
    CM_NS_EXISTS=$(kubectl --context "$KUBE_CONTEXT" get namespace cert-manager --no-headers 2>/dev/null || true)
    if [ -n "$CM_NS_EXISTS" ]; then
        CM_RUNNING=$(kubectl --context "$KUBE_CONTEXT" get pods -n cert-manager \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
        CM_TOTAL=$(kubectl --context "$KUBE_CONTEXT" get pods -n cert-manager \
            --no-headers 2>/dev/null | wc -l | tr -d ' ')
        echo "   Cert Manager pods: ${CM_RUNNING}/${CM_TOTAL} Running"
    else
        echo "   Cert Manager namespace not found"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi
else
    echo "   Skipped (no cluster access)"
fi

# =====================================================
# Summary Dashboard
# =====================================================
echo ""
echo "=============================================="
echo "  Video Indexer Arc - Deployment Complete"
echo "=============================================="
echo ""
echo "  Resource Group:  ${AZURE_RESOURCE_GROUP:-n/a}"
echo "  AKS Cluster:     ${AZURE_AKS_CLUSTER_NAME:-n/a}"
echo "  Arc Cluster:     ${AZURE_ARC_CLUSTER_NAME:-n/a}"
echo "  Location:        ${AZURE_LOCATION:-n/a}"
echo ""

ENDPOINT_URI="${AZURE_VIDEO_INDEXER_ENDPOINT_URI:-}"
if [ -n "$ENDPOINT_URI" ]; then
    echo "  Video Indexer:   ${ENDPOINT_URI}"
fi

echo ""
if [ "$HEALTH_ISSUES" -eq 0 ]; then
    echo "  Health: ALL CHECKS PASSED"
else
    echo "  Health: ${HEALTH_ISSUES} issue(s) detected (see above)"
    echo ""
    echo "  Some components may still be initializing."
    echo "  Re-check in a few minutes with:"
    echo "    kubectl get pods -A"
fi

# =====================================================
# Next Steps
# =====================================================
echo ""
echo "----------------------------------------------"
echo "  Next Steps"
echo "----------------------------------------------"
echo ""
if [ -n "$ENDPOINT_URI" ]; then
    echo "  1. Access Video Indexer at:"
    echo "     ${ENDPOINT_URI}"
fi
echo "  2. Upload a video to verify end-to-end indexing"
echo "  3. Monitor GPU utilization:"
echo "     kubectl top nodes"
echo "  4. View VI extension logs:"
echo "     kubectl logs -n video-indexer -l app=videoindexer --tail=100"
echo "  5. To tear down all resources:"
echo "     azd down"
echo ""
echo "  Useful commands:"
echo "    kubectl get pods -A               # All pods"
echo "    kubectl get nodes -o wide          # Node details"
echo "    az connectedk8s show -g ${AZURE_RESOURCE_GROUP:-RG} -n ${AZURE_ARC_CLUSTER_NAME:-ARC}"
echo ""
