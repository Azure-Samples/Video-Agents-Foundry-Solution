#!/bin/bash

# =============================================================================
# Post-Provision Script: Connect AKS to Azure Arc and deploy VI extension
# =============================================================================

set -e

source "$(dirname "$0")/common.sh"

TOTAL_STEPS=10

write_foundry_banner "Post-Provision Setup"

if [ "$CREATE_IN_LOCAL" = "false" ]; then
    log_info "Skipping postprovision script for non-local deployment."
    exit 0
fi

# =====================================================
# Validate required environment variables
# =====================================================
assert_env_vars AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP AZURE_AKS_CLUSTER_NAME \
    AZURE_LOCATION AZURE_ENV_NAME AZURE_VIDEO_INDEXER_ACCOUNT_ID \
    AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE \
    AZURE_AKS_NODE_RESOURCE_GROUP

# NOTE: CLI tools (az, helm, kubectl) are validated in preprovision. No need to re-check here.

# =====================================================
# Ensure required Azure CLI extensions are installed
# =====================================================
for ext in connectedk8s k8s-extension; do
    if ! az extension show --name "$ext" >/dev/null 2>&1; then
        run_with_spinner "Installing Azure CLI extension: $ext" "Installed extension: $ext" \
            az extension add --name "$ext" --yes
    fi
done

# NOTE: Azure resource providers are registered in preprovision. No need to re-register here.

# =====================================================
# Authenticate and set subscription
# =====================================================
EXPIRED_TOKEN=$(az ad signed-in-user show --query 'id' -o tsv 2>/dev/null || true)

if [ -z "$EXPIRED_TOKEN" ]; then
    log_warning "No Azure user signed in. Please login."
    az login -o none
fi

az account set -s "$AZURE_SUBSCRIPTION_ID"

# =====================================================
# Configuration
# =====================================================
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v25.10.01}"

# =====================================================
# Step 1: Get AKS credentials
# =====================================================
log_step 1 $TOTAL_STEPS "Getting AKS Cluster Credentials"

_SPINNER_FRAME=0; spinner_tick "Fetching AKS credentials"
KUBE_CONTEXT=$(connect_aks_cluster)
spinner_complete "AKS credentials configured"

write_key_value "Context" "$KUBE_CONTEXT"

# =====================================================
# Step 2: Install NVIDIA GPU Operator
# =====================================================
log_step 2 $TOTAL_STEPS "Installing NVIDIA GPU Operator ($GPU_OPERATOR_VERSION)"

run_with_spinner "Adding NVIDIA Helm repo" "NVIDIA Helm repo ready" \
    bash -c "helm repo add $NVIDIA_HELM_REPO_NAME $NVIDIA_HELM_REPO_URL 2>/dev/null; helm repo update 2>/dev/null"

run_with_spinner "Installing GPU Operator" "NVIDIA GPU Operator installed" \
    helm upgrade -i gpu-operator --wait \
        -n "$NS_GPU_OPERATOR" --create-namespace \
        --version "$GPU_OPERATOR_VERSION" \
        --kube-context "$KUBE_CONTEXT" \
        nvidia/gpu-operator

# =====================================================
# Step 3: Connect AKS to Azure Arc
# =====================================================
ARC_CLUSTER_NAME="${ARC_CLUSTER_PREFIX}${AZURE_AKS_CLUSTER_NAME}"
log_step 3 $TOTAL_STEPS "Connecting AKS to Azure Arc"

write_key_value "Arc cluster name" "$ARC_CLUSTER_NAME"

# Check if already connected
ARC_EXISTS=$(az connectedk8s show \
    --name "$ARC_CLUSTER_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query "name" -o tsv 2>/dev/null || true)

if [ -n "$ARC_EXISTS" ]; then
    log_success "Arc-connected cluster already exists. Skipping."
else
    run_with_spinner "Connecting cluster to Azure Arc" "AKS cluster connected to Azure Arc" \
        az connectedk8s connect \
            --name "$ARC_CLUSTER_NAME" \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --location "$AZURE_LOCATION"
fi

# Save the Arc cluster name to azd env
azd env set AZURE_ARC_CLUSTER_NAME "$ARC_CLUSTER_NAME"

# =====================================================
# Step 4: Create Public IP and construct Endpoint URI
# =====================================================
log_step 4 $TOTAL_STEPS "Creating Public IP and Endpoint URI"

# Get AKS managed cluster resource group from Bicep output
AKS_MC_RG="$AZURE_AKS_NODE_RESOURCE_GROUP"

write_key_value "MC resource group" "$AKS_MC_RG"

# Generate or reuse DNS label
if [ -n "$AZURE_DNS_LABEL" ]; then
    DNS_LABEL="$AZURE_DNS_LABEL"
    log_info "Reusing existing DNS label: $DNS_LABEL"
else
    RANDOM_SUFFIX=$((RANDOM % 900 + 100))
    DNS_LABEL="${AZURE_ENV_NAME}${RANDOM_SUFFIX}"
    log_info "Generated DNS label: $DNS_LABEL"
fi

PUBLIC_IP_NAME="${AZURE_ENV_NAME}-inbound-ip"

# Check if public IP already exists
PUBLIC_IP_EXISTS=$(az network public-ip show \
    --resource-group "$AKS_MC_RG" \
    --name "$PUBLIC_IP_NAME" \
    --query "name" -o tsv 2>/dev/null || true)

if [ -n "$PUBLIC_IP_EXISTS" ]; then
    log_success "Public IP '$PUBLIC_IP_NAME' already exists. Skipping."
else
    run_with_spinner "Creating public IP '$PUBLIC_IP_NAME'" "Public IP '$PUBLIC_IP_NAME' created with DNS label '$DNS_LABEL'" \
        az network public-ip create \
            --resource-group "$AKS_MC_RG" \
            --name "$PUBLIC_IP_NAME" \
            --sku Standard \
            --allocation-method Static \
            --dns-name "$DNS_LABEL"
fi

# Get the static IP address
STATIC_IP=$(az network public-ip show \
    --resource-group "$AKS_MC_RG" \
    --name "$PUBLIC_IP_NAME" \
    --query "ipAddress" -o tsv)

write_key_value "Static IP" "$STATIC_IP"

# Construct endpoint URI (HTTP by default)
VIDEO_INDEXER_ENDPOINT_URI="http://${DNS_LABEL}.${AZURE_LOCATION}.cloudapp.azure.com"
write_key_value "Endpoint URI" "$VIDEO_INDEXER_ENDPOINT_URI"
log_warning "Using HTTP. To enable HTTPS, configure SSL/TLS on the Nginx Ingress Controller."

# Persist to azd env
azd env set AZURE_DNS_LABEL "${DNS_LABEL}"
azd env set AZURE_STATIC_IP "${STATIC_IP}"
azd env set AZURE_VIDEO_INDEXER_ENDPOINT_URI "${VIDEO_INDEXER_ENDPOINT_URI}"

# =====================================================
# Step 5: Enable App Routing (HTTP only)
# =====================================================
log_step 5 $TOTAL_STEPS "Enabling App Routing on AKS Cluster"

APPROUTING_ENABLED=$(az aks show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_AKS_CLUSTER_NAME" \
    --query "ingressProfile.webAppRouting.enabled" -o tsv 2>/dev/null || true)

if [ "$APPROUTING_ENABLED" = "true" ]; then
    log_success "App Routing already enabled. Skipping."
else
    run_with_spinner "Enabling App Routing" "App Routing enabled" \
        az aks approuting enable \
            -g "$AZURE_RESOURCE_GROUP" \
            -n "$AZURE_AKS_CLUSTER_NAME"
fi

# =====================================================
# Step 6: Create Nginx Ingress Controller (HTTP only)
# =====================================================
log_step 6 $TOTAL_STEPS "Creating Nginx Ingress Controller"

run_with_spinner "Applying Nginx Ingress Controller" "Nginx Ingress Controller created" \
    bash -c "cat <<INNEREOF | kubectl --context '$KUBE_CONTEXT' apply -f -
apiVersion: approuting.kubernetes.azure.com/v1alpha1
kind: NginxIngressController
metadata:
  name: nginx
spec:
  ingressClassName: nginx
  controllerNamePrefix: nginx
  loadBalancerAnnotations:
    service.beta.kubernetes.io/azure-pip-name: ${PUBLIC_IP_NAME}
    service.beta.kubernetes.io/azure-load-balancer-resource-group: ${AKS_MC_RG}
INNEREOF"

# =====================================================
# Step 7: Verify Ingress Controller
# =====================================================
log_step 7 $TOTAL_STEPS "Verifying Ingress Controller"

log_info "Waiting for external IP assignment (up to ${TIMEOUT_INGRESS_IP}s)..."
ELAPSED=0
EXTERNAL_IP=""
_SPINNER_FRAME=0
while [ $ELAPSED -lt $TIMEOUT_INGRESS_IP ]; do
    EXTERNAL_IP=$(kubectl --context "$KUBE_CONTEXT" get svc nginx -n "$NS_APP_ROUTING" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
    spinner_tick "Waiting for external IP"
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ -n "$EXTERNAL_IP" ]; then
    spinner_complete "Ingress Controller is ready"
    write_key_value "External IP" "$EXTERNAL_IP"
else
    spinner_fail "External IP not assigned after ${TIMEOUT_INGRESS_IP}s"
    log_warning "Check manually: kubectl --context $KUBE_CONTEXT get svc nginx -n $NS_APP_ROUTING -w"
fi

# =====================================================
# Step 8: Deploy Cert Manager via Bicep
# =====================================================
log_step 8 $TOTAL_STEPS "Deploying Cert Manager Extension"

run_with_spinner "Deploying Cert Manager" "Cert Manager extension deployed" \
    az deployment group create \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --template-file ./infra/modules/cert-manager.bicep \
        --parameters \
            arcConnectedClusterName="$ARC_CLUSTER_NAME"

# =====================================================
# Step 9: Deploy VI Arc Extension via Bicep
# =====================================================
log_step 9 $TOTAL_STEPS "Deploying Video Indexer Arc Extension"

run_with_spinner "Deploying VI Arc extension" "Video Indexer Arc extension deployed" \
    az deployment group create \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --template-file ./infra/modules/vi-extension.bicep \
        --parameters \
            arcConnectedClusterName="$ARC_CLUSTER_NAME" \
            accountId="$AZURE_VIDEO_INDEXER_ACCOUNT_ID" \
            accountResourceId="$AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID" \
            videoIndexerEndpointUri="$VIDEO_INDEXER_ENDPOINT_URI" \
            deepstreamNodeSelectorValue="$AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE" \
            inferenceNodeSelectorValue="$AZURE_INFERENCE_NODE_SELECTOR_VALUE"

# =====================================================
# Step 10: Post-deployment health checks
# =====================================================
log_step 10 $TOTAL_STEPS "Running Post-Deployment Health Checks"

ARC_STATUS=$(az connectedk8s show \
    --name "$ARC_CLUSTER_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query "connectivityStatus" -o tsv 2>/dev/null || echo "unknown")
ARC_HEALTH="Pass"; [ "$ARC_STATUS" != "Connected" ] && ARC_HEALTH="Warn"
write_health_row "Arc connection" "$ARC_HEALTH" "$ARC_STATUS"

GPU_PODS=$(get_running_pod_count "$NS_GPU_OPERATOR" "$KUBE_CONTEXT")
GPU_HEALTH="Pass"; [ "$GPU_PODS" -eq 0 ] && GPU_HEALTH="Warn"
write_health_row "GPU operator pods" "$GPU_HEALTH" "$GPU_PODS running"

VI_PODS=$(get_running_pod_count "$NS_VIDEO_INDEXER" "$KUBE_CONTEXT")
VI_HEALTH="Pass"; [ "$VI_PODS" -eq 0 ] && VI_HEALTH="Warn"
write_health_row "VI extension pods" "$VI_HEALTH" "$VI_PODS running"

# =====================================================
# Summary
# =====================================================
echo ""
write_box_banner "Post-Provision Complete"

write_section "Deployed Resources"
write_key_value "AKS Cluster"     "$AZURE_AKS_CLUSTER_NAME"
write_key_value "Arc Cluster"     "$ARC_CLUSTER_NAME"
write_key_value "VI Account"      "${AZURE_VIDEO_INDEXER_ACCOUNT_NAME:-n/a}"
write_key_value "Storage Account" "${AZURE_STORAGE_ACCOUNT_NAME:-n/a}"
if [ -n "${AI_FOUNDRY_ACCOUNT_NAME:-}" ]; then
    write_key_value "AI Foundry Hub"   "$AI_FOUNDRY_ACCOUNT_NAME"
    write_key_value "AI Foundry Model" "${AI_FOUNDRY_MODEL_DEPLOYMENT:-n/a}"
    write_key_value "AI Endpoint"      "${AI_FOUNDRY_AI_SERVICES_ENDPOINT:-n/a}"
fi

echo ""
log_success "Video Indexer portal: $VIDEO_INDEXER_ENDPOINT_URI"
case "$(uname)" in
    Darwin*) open "$VIDEO_INDEXER_ENDPOINT_URI" ;;
    Linux*) xdg-open "$VIDEO_INDEXER_ENDPOINT_URI" 2>/dev/null || true ;;
    *) true ;;
esac
