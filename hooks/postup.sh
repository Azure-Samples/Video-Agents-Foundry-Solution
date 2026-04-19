#!/bin/bash

# =============================================================================
# Post-Up Script: Deployment health dashboard and next steps
# =============================================================================

set -eo pipefail
source "$(dirname "$0")/common.sh"

TOTAL_STEPS=6
HEALTH_PASSED=0
HEALTH_FAILED=0
HEALTH_WARNINGS=0
HEALTH_TOTAL=0

_track_health() {
    local status="$1"
    HEALTH_TOTAL=$((HEALTH_TOTAL + 1))
    case "$status" in
        Pass) HEALTH_PASSED=$((HEALTH_PASSED + 1)) ;;
        Fail) HEALTH_FAILED=$((HEALTH_FAILED + 1)) ;;
        Warn) HEALTH_WARNINGS=$((HEALTH_WARNINGS + 1)) ;;
    esac
}

write_foundry_banner "Health Dashboard"

# =====================================================
# Get AKS credentials for kubectl access
# =====================================================
HAS_CLUSTER_ACCESS=false
if [ -z "${AZURE_RESOURCE_GROUP:-}" ] || [ -z "${AZURE_AKS_CLUSTER_NAME:-}" ]; then
    log_warning "AZURE_RESOURCE_GROUP or AZURE_AKS_CLUSTER_NAME not set."
    log_info "Skipping Kubernetes health checks."
else
    log_info "Getting AKS credentials..."
    KUBE_CONTEXT=$(connect_aks_cluster 2>/dev/null) && HAS_CLUSTER_ACCESS=true
    if [ "$HAS_CLUSTER_ACCESS" = true ]; then
        log_success "AKS credentials configured"
    else
        log_warning "Could not get AKS credentials."
        log_warning "Skipping Kubernetes health checks."
    fi
fi

# =====================================================
# Step 1: AKS Cluster Health
# =====================================================
log_step 1 $TOTAL_STEPS "AKS Cluster Health"

if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
    AKS_STATE=$(az aks show -g "$AZURE_RESOURCE_GROUP" -n "$AZURE_AKS_CLUSTER_NAME" \
        --query "provisioningState" -o tsv 2>/dev/null || echo "Unknown")
    AKS_STATUS="Pass"; [ "$AKS_STATE" != "Succeeded" ] && AKS_STATUS="Fail"
    write_health_row "AKS provisioning state" "$AKS_STATUS" "$AKS_STATE"
    _track_health "$AKS_STATUS"

    TOTAL_NODES=$(kubectl --context "$KUBE_CONTEXT" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    READY_NODES=$(kubectl --context "$KUBE_CONTEXT" get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
    NODE_STATUS="Pass"; [ "$READY_NODES" != "$TOTAL_NODES" ] && NODE_STATUS="Warn"
    write_health_row "Cluster nodes" "$NODE_STATUS" "${READY_NODES}/${TOTAL_NODES} Ready"
    _track_health "$NODE_STATUS"

    GPU_NODES=$(kubectl --context "$KUBE_CONTEXT" get nodes -l "accelerator=nvidia" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    GPU_NODE_STATUS="Pass"; [ "$GPU_NODES" -eq 0 ] && GPU_NODE_STATUS="Warn"
    GPU_NODE_DETAIL="$GPU_NODES detected"
    [ "$GPU_NODES" -eq 0 ] && GPU_NODE_DETAIL="none detected (may still be provisioning)"
    write_health_row "GPU nodes" "$GPU_NODE_STATUS" "$GPU_NODE_DETAIL"
    _track_health "$GPU_NODE_STATUS"
else
    write_health_row "AKS Cluster" "Skip" "no cluster access"
fi

# =====================================================
# Step 2: GPU Operator Health
# =====================================================
log_step 2 $TOTAL_STEPS "GPU Operator Health"

if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
    GPU_NS_EXISTS=$(kubectl --context "$KUBE_CONTEXT" get namespace "$NS_GPU_OPERATOR" --no-headers 2>/dev/null || true)
    if [ -n "$GPU_NS_EXISTS" ]; then
        GPU_RUNNING=$(get_running_pod_count "$NS_GPU_OPERATOR" "$KUBE_CONTEXT")
        GPU_TOTAL=$(get_total_pod_count "$NS_GPU_OPERATOR" "$KUBE_CONTEXT")
        GPU_POD_STATUS="Pass"
        [ "$GPU_RUNNING" -lt "$GPU_TOTAL" ] && GPU_POD_STATUS="Warn"
        [ "$GPU_RUNNING" -eq 0 ] && GPU_POD_STATUS="Fail"
        GPU_DETAIL="${GPU_RUNNING}/${GPU_TOTAL} Running"
        [ "$GPU_RUNNING" -lt "$GPU_TOTAL" ] && GPU_DETAIL="${GPU_DETAIL} (GPU driver install can take several minutes)"
        write_health_row "GPU Operator" "$GPU_POD_STATUS" "$GPU_DETAIL"
        _track_health "$GPU_POD_STATUS"
    else
        write_health_row "GPU Operator" "Fail" "namespace not found"
        _track_health "Fail"
    fi
else
    write_health_row "GPU Operator" "Skip" "no cluster access"
fi

# =====================================================
# Step 3: Arc Connection Health
# =====================================================
log_step 3 $TOTAL_STEPS "Arc Connection Health"

ARC_CLUSTER_NAME="${AZURE_ARC_CLUSTER_NAME:-}"
if [ -n "$ARC_CLUSTER_NAME" ]; then
    ARC_STATUS=$(az connectedk8s show \
        --name "$ARC_CLUSTER_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --query "connectivityStatus" -o tsv 2>/dev/null || echo "Unknown")
    ARC_HEALTH="Pass"; [ "$ARC_STATUS" != "Connected" ] && ARC_HEALTH="Warn"
    write_health_row "Arc connection" "$ARC_HEALTH" "$ARC_CLUSTER_NAME ($ARC_STATUS)"
    _track_health "$ARC_HEALTH"

    if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
        ARC_PODS=$(get_total_pod_count "$NS_AZURE_ARC" "$KUBE_CONTEXT")
        ARC_POD_STATUS="Pass"; [ "$ARC_PODS" -eq 0 ] && ARC_POD_STATUS="Warn"
        write_health_row "Arc agent pods" "$ARC_POD_STATUS" "$ARC_PODS running"
        _track_health "$ARC_POD_STATUS"
    fi
else
    write_health_row "Arc connection" "Fail" "cluster name not set"
    _track_health "Fail"
fi

# =====================================================
# Step 4: Ingress & Networking Health
# =====================================================
log_step 4 $TOTAL_STEPS "Ingress & Networking Health"

if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
    INGRESS_PODS=$(get_total_pod_count "$NS_APP_ROUTING" "$KUBE_CONTEXT")
    INGRESS_STATUS="Pass"; [ "$INGRESS_PODS" -eq 0 ] && INGRESS_STATUS="Warn"
    write_health_row "Ingress pods" "$INGRESS_STATUS" "$INGRESS_PODS in $NS_APP_ROUTING"
    _track_health "$INGRESS_STATUS"

    if [ -n "${AZURE_STATIC_IP:-}" ]; then
        write_health_row "Public IP" "Pass" "$AZURE_STATIC_IP"
        _track_health "Pass"
    else
        write_health_row "Public IP" "Warn" "not configured"
        _track_health "Warn"
    fi

    if [ -n "${AZURE_DNS_LABEL:-}" ] && [ -n "${AZURE_LOCATION:-}" ]; then
        FQDN="${AZURE_DNS_LABEL}.${AZURE_LOCATION}.cloudapp.azure.com"
        DNS_RESOLVED=$(host "$FQDN" 2>/dev/null | grep -c "has address" || \
            nslookup "$FQDN" 2>/dev/null | grep -c "Address:" || echo "0")
        if [ "$DNS_RESOLVED" -gt 0 ]; then
            write_health_row "DNS resolution" "Pass" "$FQDN"
            _track_health "Pass"
        else
            write_health_row "DNS resolution" "Warn" "pending propagation"
            _track_health "Warn"
        fi
    fi
else
    write_health_row "Ingress & Networking" "Skip" "no cluster access"
fi

# =====================================================
# Step 5: Video Indexer Extension Health
# =====================================================
log_step 5 $TOTAL_STEPS "Video Indexer Extension Health"

if [ -n "$ARC_CLUSTER_NAME" ]; then
    VI_STATE=$(az k8s-extension show \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --cluster-name "$ARC_CLUSTER_NAME" \
        --cluster-type connectedClusters \
        --name videoindexer \
        --query "provisioningState" -o tsv 2>/dev/null || echo "Unknown")
    VI_EXT_STATUS="Pass"; [ "$VI_STATE" != "Succeeded" ] && VI_EXT_STATUS="Warn"
    write_health_row "VI Extension" "$VI_EXT_STATUS" "$VI_STATE"
    _track_health "$VI_EXT_STATUS"

    if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
        VI_RUNNING=$(get_running_pod_count "$NS_VIDEO_INDEXER" "$KUBE_CONTEXT")
        VI_TOTAL=$(get_total_pod_count "$NS_VIDEO_INDEXER" "$KUBE_CONTEXT")
        VI_POD_STATUS="Pass"
        [ "$VI_RUNNING" -lt "$VI_TOTAL" ] && VI_POD_STATUS="Warn"
        [ "$VI_RUNNING" -eq 0 ] && [ "$VI_TOTAL" -gt 0 ] && VI_POD_STATUS="Fail"
        write_health_row "VI pods" "$VI_POD_STATUS" "${VI_RUNNING}/${VI_TOTAL} Running"
        _track_health "$VI_POD_STATUS"
    fi
else
    write_health_row "VI Extension" "Skip" "no Arc cluster configured"
fi

# =====================================================
# Step 6: Cert Manager Health
# =====================================================
log_step 6 $TOTAL_STEPS "Cert Manager Health"

if [ "$HAS_CLUSTER_ACCESS" = "true" ]; then
    CM_NS_EXISTS=$(kubectl --context "$KUBE_CONTEXT" get namespace "$NS_CERT_MANAGER" --no-headers 2>/dev/null || true)
    if [ -n "$CM_NS_EXISTS" ]; then
        CM_RUNNING=$(get_running_pod_count "$NS_CERT_MANAGER" "$KUBE_CONTEXT")
        CM_TOTAL=$(get_total_pod_count "$NS_CERT_MANAGER" "$KUBE_CONTEXT")
        CM_STATUS="Pass"
        [ "$CM_RUNNING" -lt "$CM_TOTAL" ] && CM_STATUS="Warn"
        [ "$CM_RUNNING" -eq 0 ] && [ "$CM_TOTAL" -gt 0 ] && CM_STATUS="Fail"
        write_health_row "Cert Manager" "$CM_STATUS" "${CM_RUNNING}/${CM_TOTAL} Running"
        _track_health "$CM_STATUS"
    else
        write_health_row "Cert Manager" "Fail" "namespace not found"
        _track_health "Fail"
    fi
else
    write_health_row "Cert Manager" "Skip" "no cluster access"
fi

# =====================================================
# Summary Dashboard
# =====================================================
echo ""
write_box_banner "Deployment Summary" "" "Double" 56

write_section "Resources"
write_key_value "Resource Group" "${AZURE_RESOURCE_GROUP:-n/a}"
write_key_value "AKS Cluster"    "${AZURE_AKS_CLUSTER_NAME:-n/a}"
write_key_value "Arc Cluster"    "${AZURE_ARC_CLUSTER_NAME:-n/a}"
write_key_value "Location"       "${AZURE_LOCATION:-n/a}"

write_summary_block "$HEALTH_PASSED" "$HEALTH_FAILED" "$HEALTH_WARNINGS" "$HEALTH_TOTAL"

if [ "$HEALTH_FAILED" -gt 0 ]; then
    log_warning "Some components may still be initializing."
    log_info "Re-check in a few minutes with: kubectl get pods -A"
    echo ""
fi

# =====================================================
# Next Steps
# =====================================================
write_section "Next Steps"
echo ""

if [ -n "${AZURE_VI_PORTAL_URL:-}" ]; then
    PORTAL_URL="$AZURE_VI_PORTAL_URL"
    log_success "Video Indexer portal: $PORTAL_URL"
    write_key_value "1. Access portal" "$PORTAL_URL"
    case "$(uname)" in
        Darwin*) open "$PORTAL_URL" ;;
        Linux*) xdg-open "$PORTAL_URL" 2>/dev/null || true ;;
        MINGW*|MSYS*|CYGWIN*) start "$PORTAL_URL" 2>/dev/null || true ;;
        *) true ;;
    esac
fi
write_key_value "2. Test chat" "Chat with video agent"
write_key_value "3. Add camera"        "add custom cameras from RTSP streams"
write_key_value "4. Tear down"         "azd down"


echo ""
