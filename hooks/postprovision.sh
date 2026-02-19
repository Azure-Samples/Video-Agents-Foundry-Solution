#!/bin/bash

# =============================================================================
# Post-Provision Script: Connect AKS to Azure Arc and deploy VI extension
# =============================================================================

set -e

echo "=============================================="
echo "Post-provision: Video Indexer Arc Setup"
echo "=============================================="

if [ "$CREATE_IN_LOCAL" = "false" ]; then
    echo "Skipping postprovision.sh script execution as it is not in local."
    exit 0
fi

# =====================================================
# Validate required environment variables
# =====================================================
MISSING_VARS=""
for var in AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP AZURE_AKS_CLUSTER_NAME \
           AZURE_LOCATION AZURE_ENV_NAME AZURE_VIDEO_INDEXER_ACCOUNT_ID \
           AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE \
           AZURE_AKS_NODE_RESOURCE_GROUP; do
    eval val=\$$var
    if [ -z "$val" ]; then
        MISSING_VARS="${MISSING_VARS}  - ${var}
"
    fi
done

if [ -n "$MISSING_VARS" ]; then
    echo "ERROR: The following required environment variables are not set:" >&2
    printf "%s" "$MISSING_VARS" >&2
    echo "Run 'azd env get-values' to check your environment." >&2
    exit 1
fi

# =====================================================
# Check prerequisites
# =====================================================
for cmd in helm kubectl az; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' is required but not found in PATH." >&2
        exit 1
    fi
done

for ext in connectedk8s k8s-extension; do
    if ! az extension show --name "$ext" >/dev/null 2>&1; then
        echo "Installing Azure CLI extension: $ext"
        az extension add --name "$ext" --yes
    fi
done

# =====================================================
# Register required Azure providers
# =====================================================
echo ""
echo ">> Registering required Azure resource providers..."
for provider in Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.ExtendedLocation; do
    az provider register --namespace "$provider" --wait false 2>/dev/null || true
done
echo "   Provider registration initiated."

# =====================================================
# Authenticate and set subscription
# =====================================================
EXPIRED_TOKEN=$(az ad signed-in-user show --query 'id' -o tsv 2>/dev/null || true)

if [ -z "$EXPIRED_TOKEN" ]; then
    echo "No Azure user signed in. Please login."
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
echo ""
echo ">> Step 1: Getting AKS cluster credentials..."
az aks get-credentials \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_AKS_CLUSTER_NAME" \
    --admin \
    --overwrite-existing

KUBE_CONTEXT="${AZURE_AKS_CLUSTER_NAME}-admin"

echo "   AKS credentials configured (context: ${KUBE_CONTEXT})."

# =====================================================
# Step 2: Install NVIDIA GPU Operator
# =====================================================
echo ""
echo ">> Step 2: Installing NVIDIA GPU Operator (${GPU_OPERATOR_VERSION})..."

# Add NVIDIA Helm repo (idempotent)
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update

# Install or upgrade the GPU operator
helm upgrade -i gpu-operator --wait \
    -n gpu-operator --create-namespace \
    --version "$GPU_OPERATOR_VERSION" \
    --kube-context "$KUBE_CONTEXT" \
    nvidia/gpu-operator

echo "   NVIDIA GPU Operator installed."

# =====================================================
# Step 3: Connect AKS to Azure Arc
# =====================================================
ARC_CLUSTER_NAME="arc-${AZURE_AKS_CLUSTER_NAME}"
echo ""
echo ">> Step 3: Connecting AKS cluster to Azure Arc as '${ARC_CLUSTER_NAME}'..."

# Check if already connected
ARC_EXISTS=$(az connectedk8s show \
    --name "$ARC_CLUSTER_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query "name" -o tsv 2>/dev/null || true)

if [ -n "$ARC_EXISTS" ]; then
    echo "   Arc-connected cluster '$ARC_CLUSTER_NAME' already exists. Skipping."
else
    az connectedk8s connect \
        --name "$ARC_CLUSTER_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --location "$AZURE_LOCATION"
    echo "   AKS cluster connected to Azure Arc."
fi

# Save the Arc cluster name to azd env
azd env set AZURE_ARC_CLUSTER_NAME "$ARC_CLUSTER_NAME"

# =====================================================
# Step 4: Create Public IP and construct Endpoint URI
# =====================================================
echo ""
echo ">> Step 4: Creating Public IP and constructing Video Indexer endpoint URI..."

# Get AKS managed cluster resource group from Bicep output
AKS_MC_RG="$AZURE_AKS_NODE_RESOURCE_GROUP"

echo "   AKS MC resource group: ${AKS_MC_RG}"

# Generate or reuse DNS label
if [ -n "$AZURE_DNS_LABEL" ]; then
    DNS_LABEL="$AZURE_DNS_LABEL"
    echo "   Reusing existing DNS label: ${DNS_LABEL}"
else
    RANDOM_SUFFIX=$((RANDOM % 900 + 100))
    DNS_LABEL="${AZURE_ENV_NAME}${RANDOM_SUFFIX}"
    echo "   Generated DNS label: ${DNS_LABEL}"
fi

PUBLIC_IP_NAME="${AZURE_ENV_NAME}-inbound-ip"

# Check if public IP already exists
PUBLIC_IP_EXISTS=$(az network public-ip show \
    --resource-group "$AKS_MC_RG" \
    --name "$PUBLIC_IP_NAME" \
    --query "name" -o tsv 2>/dev/null || true)

if [ -n "$PUBLIC_IP_EXISTS" ]; then
    echo "   Public IP '${PUBLIC_IP_NAME}' already exists. Skipping creation."
else
    az network public-ip create \
        --resource-group "$AKS_MC_RG" \
        --name "$PUBLIC_IP_NAME" \
        --sku Standard \
        --allocation-method Static \
        --dns-name "$DNS_LABEL"
    echo "   Public IP '${PUBLIC_IP_NAME}' created with DNS label '${DNS_LABEL}'."
fi

# Get the static IP address
STATIC_IP=$(az network public-ip show \
    --resource-group "$AKS_MC_RG" \
    --name "$PUBLIC_IP_NAME" \
    --query "ipAddress" -o tsv)

echo "   Static IP: ${STATIC_IP}"

# Construct endpoint URI (HTTP by default — switch to https:// after configuring SSL/TLS)
VIDEO_INDEXER_ENDPOINT_URI="http://${DNS_LABEL}.${AZURE_LOCATION}.cloudapp.azure.com"
echo "   Endpoint URI: ${VIDEO_INDEXER_ENDPOINT_URI}"
echo "   NOTE: Using HTTP. To enable HTTPS, configure SSL/TLS on the Nginx Ingress Controller (see AKS-CLUSTER-SETUP.md)."

# Persist to azd env
azd env set AZURE_DNS_LABEL "${DNS_LABEL}"
azd env set AZURE_STATIC_IP "${STATIC_IP}"
azd env set AZURE_VIDEO_INDEXER_ENDPOINT_URI "${VIDEO_INDEXER_ENDPOINT_URI}"

# =====================================================
# Step 5: Enable App Routing (HTTP only)
# =====================================================
echo ""
echo ">> Step 5: Enabling App Routing on AKS cluster..."

APPROUTING_ENABLED=$(az aks show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_AKS_CLUSTER_NAME" \
    --query "ingressProfile.webAppRouting.enabled" -o tsv 2>/dev/null || true)

if [ "$APPROUTING_ENABLED" = "true" ]; then
    echo "   App Routing already enabled. Skipping."
else
    az aks approuting enable \
        -g "$AZURE_RESOURCE_GROUP" \
        -n "$AZURE_AKS_CLUSTER_NAME"
    echo "   App Routing enabled."
fi

# =====================================================
# Step 6: Create Nginx Ingress Controller (HTTP only)
# =====================================================
echo ""
echo ">> Step 6: Creating Nginx Ingress Controller..."

cat <<EOF | kubectl --context "$KUBE_CONTEXT" apply -f -
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
EOF

echo "   Nginx Ingress Controller created."

# =====================================================
# Step 7: Verify Ingress Controller
# =====================================================
echo ""
echo ">> Step 7: Verifying Ingress Controller..."

echo "   Waiting for external IP assignment (up to 120s)..."
TIMEOUT=120
ELAPSED=0
EXTERNAL_IP=""
while [ $ELAPSED -lt $TIMEOUT ]; do
    EXTERNAL_IP=$(kubectl --context "$KUBE_CONTEXT" get svc nginx -n app-routing-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ -n "$EXTERNAL_IP" ]; then
    echo "   Ingress Controller is ready."
    echo "   External IP: ${EXTERNAL_IP}"
    kubectl --context "$KUBE_CONTEXT" get svc nginx -n app-routing-system
else
    echo "   WARNING: External IP not yet assigned after ${TIMEOUT}s. Check manually:"
    echo "   kubectl --context ${KUBE_CONTEXT} get svc nginx -n app-routing-system -w"
fi

# =====================================================
# Step 8: Deploy Cert Manager via Bicep
# =====================================================
echo ""
echo ">> Step 8: Deploying Cert Manager extension..."

az deployment group create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --template-file ./infra/modules/cert-manager.bicep \
    --parameters \
        arcConnectedClusterName="$ARC_CLUSTER_NAME"

echo "   Cert Manager extension deployed."

# =====================================================
# Step 9: Deploy VI Arc Extension via Bicep
# =====================================================
echo ""
echo ">> Step 9: Deploying Video Indexer Arc extension..."

az deployment group create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --template-file ./infra/modules/vi-extension.bicep \
    --parameters \
        arcConnectedClusterName="$ARC_CLUSTER_NAME" \
        accountId="$AZURE_VIDEO_INDEXER_ACCOUNT_ID" \
        accountResourceId="$AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID" \
        videoIndexerEndpointUri="$VIDEO_INDEXER_ENDPOINT_URI" \
        deepstreamNodeSelectorValue="$AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE"

echo "   Video Indexer Arc extension deployed."

# =====================================================
# Step 10: Post-deployment health checks
# =====================================================
echo ""
echo ">> Step 10: Running post-deployment health checks..."

echo -n "   Arc connection status: "
ARC_STATUS=$(az connectedk8s show \
    --name "$ARC_CLUSTER_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query "connectivityStatus" -o tsv 2>/dev/null || echo "unknown")
echo "$ARC_STATUS"

echo -n "   GPU operator pods running: "
GPU_PODS=$(kubectl --context "$KUBE_CONTEXT" get pods -n gpu-operator --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "$GPU_PODS"

echo -n "   VI extension pods running: "
VI_PODS=$(kubectl --context "$KUBE_CONTEXT" get pods -n video-indexer --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "$VI_PODS"

# =====================================================
# Summary
# =====================================================
echo ""
echo "=============================================="
echo "Post-provision completed successfully!"
echo "=============================================="
echo ""
echo "Resources created:"
echo "  - AKS Cluster:      $AZURE_AKS_CLUSTER_NAME"
echo "  - Arc Cluster:      $ARC_CLUSTER_NAME"
echo "  - VI Account:       $AZURE_VIDEO_INDEXER_ACCOUNT_NAME"
echo "  - Storage Account:  $AZURE_STORAGE_ACCOUNT_NAME"
echo ""

echo "You can access the Video Indexer portal at: $VIDEO_INDEXER_ENDPOINT_URI"
case "$(uname)" in
    Darwin*) open "$VIDEO_INDEXER_ENDPOINT_URI" ;;
    Linux*) xdg-open "$VIDEO_INDEXER_ENDPOINT_URI" ;;
    *) echo "Unsupported OS" ;;
esac
