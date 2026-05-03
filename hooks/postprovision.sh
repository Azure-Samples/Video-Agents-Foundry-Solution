#!/bin/bash

# =============================================================================
# Post-Provision Script: Connect AKS to Azure Arc and deploy VI extension
# =============================================================================

set -eo pipefail
source "$(dirname "$0")/common.sh"

TOTAL_STEPS=12

write_foundry_banner "Post-Provision Setup"

if [ "$SKIP_POST_PROVISION" = "true" ]; then
    log_info "Skipping postprovision script (SKIP_POST_PROVISION=true)."
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
        log_info "Installing Azure CLI extension: $ext..."
        az extension add --name "$ext" --yes 2>/dev/null
        log_success "Installed extension: $ext"
    fi
done

# NOTE: Azure resource providers are registered in preprovision. No need to re-register here.

# =====================================================
# Authenticate and set subscription
# =====================================================
SIGNED_IN_USER_ID=$(az ad signed-in-user show --query 'id' -o tsv 2>/dev/null | tr -d '\r' || true)

if [ -z "$SIGNED_IN_USER_ID" ]; then
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

log_info "Fetching AKS credentials..."
KUBE_CONTEXT=$(connect_aks_cluster)
log_success "AKS credentials configured"
write_key_value "Context" "$KUBE_CONTEXT"

# =====================================================
# Step 2: Install NVIDIA GPU Operator
# =====================================================
log_step 2 $TOTAL_STEPS "Installing NVIDIA GPU Operator ($GPU_OPERATOR_VERSION)"

# Add NVIDIA Helm repo (idempotent)
log_info "Adding NVIDIA Helm repo..."
helm repo add "$NVIDIA_HELM_REPO_NAME" "$NVIDIA_HELM_REPO_URL" 2>/dev/null || true
helm repo update 2>/dev/null
log_success "NVIDIA Helm repo ready"

log_info "Installing GPU Operator (this may take a few minutes)..."
helm upgrade -i gpu-operator --wait \
    -n "$NS_GPU_OPERATOR" --create-namespace \
    --version "$GPU_OPERATOR_VERSION" \
    --kube-context "$KUBE_CONTEXT" \
    nvidia/gpu-operator
log_success "NVIDIA GPU Operator installed"

# =====================================================
# Step 3: Connect AKS to Azure Arc
# =====================================================
ARC_CLUSTER_NAME="${ARC_CLUSTER_PREFIX}${AZURE_AKS_CLUSTER_NAME}"
# Azure Arc cluster name rules: lowercase alnum + hyphen, no leading/trailing hyphen, <=63 chars
ARC_CLUSTER_NAME=$(echo "$ARC_CLUSTER_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')
ARC_CLUSTER_NAME=$(echo "$ARC_CLUSTER_NAME" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')
if [ ${#ARC_CLUSTER_NAME} -gt 63 ]; then
    ARC_CLUSTER_NAME="${ARC_CLUSTER_NAME:0:63}"
    ARC_CLUSTER_NAME=$(echo "$ARC_CLUSTER_NAME" | sed -E 's/-+$//')
fi
log_step 3 $TOTAL_STEPS "Connecting AKS to Azure Arc"

write_key_value "Arc cluster name" "$ARC_CLUSTER_NAME"

# Check if already connected
ARC_EXISTS=$(az connectedk8s show \
    --name "$ARC_CLUSTER_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query "name" -o tsv 2>/dev/null | tr -d '\r' || true)

if [ -n "$ARC_EXISTS" ]; then
    log_success "Arc-connected cluster already exists. Skipping."
else
    log_info "Connecting cluster to Azure Arc..."
    az connectedk8s connect \
        --name "$ARC_CLUSTER_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --location "$AZURE_LOCATION"
    log_success "AKS cluster connected to Azure Arc"
fi

# Save the Arc cluster name to azd env
azd_env_set AZURE_ARC_CLUSTER_NAME "$ARC_CLUSTER_NAME" || true

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
    # Deterministic 5-digit suffix derived from env + location + subscription.
    # Same inputs always produce same DNS label (idempotent) while collision
    # space is 10^5 (vs 900 for the prior RANDOM % 900 + 100).
    DNS_HASH_INPUT="${AZURE_ENV_NAME}|${AZURE_LOCATION}|${AZURE_SUBSCRIPTION_ID:-}"
    if command -v sha256sum >/dev/null 2>&1; then
        DNS_HASH=$(printf '%s' "$DNS_HASH_INPUT" | sha256sum | cut -c1-10)
    else
        DNS_HASH=$(printf '%s' "$DNS_HASH_INPUT" | shasum -a 256 | cut -c1-10)
    fi
    # Convert hex slice to decimal and take 5 digits
    RANDOM_SUFFIX=$(printf '%d' "0x${DNS_HASH}" 2>/dev/null | tr -dc '0-9' | head -c 5)
    RANDOM_SUFFIX=${RANDOM_SUFFIX:-00000}
    DNS_LABEL="${AZURE_ENV_NAME}${RANDOM_SUFFIX}"
    log_info "Generated DNS label: $DNS_LABEL"
fi

PUBLIC_IP_NAME="${AZURE_ENV_NAME}-inbound-ip"

# Check if public IP already exists
PUBLIC_IP_EXISTS=$(az network public-ip show \
    --resource-group "$AKS_MC_RG" \
    --name "$PUBLIC_IP_NAME" \
    --query "name" -o tsv 2>/dev/null | tr -d '\r' || true)

if [ -n "$PUBLIC_IP_EXISTS" ]; then
    log_success "Public IP '$PUBLIC_IP_NAME' already exists. Skipping."
else
    log_info "Creating public IP '$PUBLIC_IP_NAME'..."
    az network public-ip create \
        --resource-group "$AKS_MC_RG" \
        --name "$PUBLIC_IP_NAME" \
        --sku Standard \
        --allocation-method Static \
        --dns-name "$DNS_LABEL" >/dev/null
    log_success "Public IP '$PUBLIC_IP_NAME' created with DNS label '$DNS_LABEL'"
fi

# Get the static IP address
STATIC_IP=$(az network public-ip show \
    --resource-group "$AKS_MC_RG" \
    --name "$PUBLIC_IP_NAME" \
    --query "ipAddress" -o tsv | tr -d '\r')

write_key_value "Static IP" "$STATIC_IP"

VIDEO_INDEXER_ENDPOINT_URI="https://${DNS_LABEL}.${AZURE_LOCATION}.cloudapp.azure.com"
write_key_value "Endpoint URI" "$VIDEO_INDEXER_ENDPOINT_URI"

# Persist to azd env
azd_env_set AZURE_DNS_LABEL "${DNS_LABEL}" || true
azd_env_set AZURE_STATIC_IP "${STATIC_IP}" || true
azd_env_set AZURE_VIDEO_INDEXER_ENDPOINT_URI "${VIDEO_INDEXER_ENDPOINT_URI}" || true

# =====================================================
# Step 5: Enable App Routing (HTTP only)
# =====================================================
log_step 5 $TOTAL_STEPS "Enabling App Routing on AKS Cluster"

APPROUTING_ENABLED=$(az aks show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$AZURE_AKS_CLUSTER_NAME" \
    --query "ingressProfile.webAppRouting.enabled" -o tsv 2>/dev/null | tr -d '\r' || true)

if [ "$APPROUTING_ENABLED" = "true" ]; then
    log_success "App Routing already enabled. Skipping."
else
    log_info "Enabling App Routing..."
    az aks approuting enable \
        -g "$AZURE_RESOURCE_GROUP" \
        -n "$AZURE_AKS_CLUSTER_NAME"
    log_success "App Routing enabled"
fi

# =====================================================
# Step 6: Create Nginx Ingress Controller (HTTP only)
# =====================================================
log_step 6 $TOTAL_STEPS "Creating Nginx Ingress Controller"

log_info "Applying Nginx Ingress Controller..."
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
log_success "Nginx Ingress Controller created"

# =====================================================
# Step 7: Verify Ingress Controller
# =====================================================
log_step 7 $TOTAL_STEPS "Verifying Ingress Controller"

log_info "Waiting for external IP assignment (up to ${TIMEOUT_INGRESS_IP}s)..."
ELAPSED=0
EXTERNAL_IP=""
while [ $ELAPSED -lt $TIMEOUT_INGRESS_IP ]; do
    EXTERNAL_IP=$(kubectl --context "$KUBE_CONTEXT" get svc nginx -n "$NS_APP_ROUTING" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ -n "$EXTERNAL_IP" ]; then
    log_success "Ingress Controller is ready"
    write_key_value "External IP" "$EXTERNAL_IP"
else
    log_warning "External IP not assigned after ${TIMEOUT_INGRESS_IP}s"
    log_info "Check manually: kubectl --context $KUBE_CONTEXT get svc nginx -n $NS_APP_ROUTING -w"
fi

# =====================================================
# Step 8: Deploy Cert Manager via Bicep
# =====================================================
log_step 8 $TOTAL_STEPS "Deploying Cert Manager Extension"

log_info "Deploying Cert Manager..."
az deployment group create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --template-file ./infra/modules/cert-manager.bicep \
    --parameters \
        arcConnectedClusterName="$ARC_CLUSTER_NAME"
log_success "Cert Manager extension deployed"

# =====================================================
# Step 9: Deploy VI Arc Extension via Bicep
# =====================================================
log_step 9 $TOTAL_STEPS "Deploying Video Indexer Arc Extension"

# Normalize to true by default; only explicit "false" disables Foundry.
CREATE_FOUNDRY_PROJECT="${CREATE_FOUNDRY_PROJECT:-true}"
if [ "$CREATE_FOUNDRY_PROJECT" = "false" ]; then
    AGENTS_RUNTIME_AZURE_OPENAI_MODEL=""
else
    AGENTS_RUNTIME_AZURE_OPENAI_MODEL="$AI_MODEL_NAME"
fi

MEDIA_STREAMER_ENABLED="${MEDIA_STREAMER_ENABLED:-true}"

log_info "Deploying VI Arc extension (this may take several minutes)..."
az deployment group create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --template-file ./infra/modules/vi-extension.bicep \
    --parameters \
        arcConnectedClusterName="$ARC_CLUSTER_NAME" \
        accountId="$AZURE_VIDEO_INDEXER_ACCOUNT_ID" \
        accountResourceId="$AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID" \
        videoIndexerEndpointUri="$VIDEO_INDEXER_ENDPOINT_URI" \
        deepstreamNodeSelectorValue="$AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE" \
        inferenceNodeSelectorValue="$AZURE_INFERENCE_NODE_SELECTOR_VALUE" \
        mediaStreamerEnabled="$MEDIA_STREAMER_ENABLED" \
        agentsRuntimeAzureOpenAIBaseUrl="$AI_FOUNDRY_SERVICES_BASE_URL" \
        agentsRuntimeAzureOpenAIModel="$AGENTS_RUNTIME_AZURE_OPENAI_MODEL"
log_success "Video Indexer Arc extension deployed"

log_info "Assigning permissions to Arc extension managed identity..."
PRINCIPAL_ID=$(az k8s-extension show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --cluster-name "$ARC_CLUSTER_NAME" \
    --cluster-type connectedClusters \
    --name videoindexer \
    --query "identity.principalId" -o tsv 2>/dev/null | tr -d '\r' || true)

ACCOUNT_RESOURCE_ID="$AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID"
FOUNDRY_ACCOUNT_RESOURCE_ID="${AI_FOUNDRY_ACCOUNT_RESOURCE_ID:-}"

if [ -z "$FOUNDRY_ACCOUNT_RESOURCE_ID" ] && [ -n "${AI_FOUNDRY_ACCOUNT_NAME:-}" ]; then
    FOUNDRY_ACCOUNT_RESOURCE_ID=$(az cognitiveservices account show \
        --name "$AI_FOUNDRY_ACCOUNT_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --query "id" -o tsv 2>/dev/null || true)
fi

if [ -z "$PRINCIPAL_ID" ]; then
    log_error "Extension managed identity principalId not found. Cannot assign permissions."
elif [ -z "$ACCOUNT_RESOURCE_ID" ]; then
    log_error "Video Indexer account resource ID not found. Cannot assign permissions."
else
    # TODO: Replace 'Contributor' with a purpose-built least-privilege role (e.g. 'Video Indexer Contributor')
    # when one becomes available. Currently scoped to the VI account resource only.
    log_info "Adding Role Assignment for principal '$PRINCIPAL_ID'..."

    # Check if the role assignment already exists before attempting to create
    EXISTING_ASSIGNMENT=$(az role assignment list \
        --assignee "$PRINCIPAL_ID" \
        --role Contributor \
        --scope "$ACCOUNT_RESOURCE_ID" \
        --query "[0].id" -o tsv 2>/dev/null | tr -d '\r' || true)

    if [ -n "$EXISTING_ASSIGNMENT" ]; then
        log_success "Role assignment already exists. Skipping."
    else
        ROLE_ERR=""
        if ROLE_ERR=$(az role assignment create \
            --assignee-object-id "$PRINCIPAL_ID" \
            --assignee-principal-type ServicePrincipal \
            --role Contributor \
            --scope "$ACCOUNT_RESOURCE_ID" 2>&1); then
            log_success "Permissions assigned to Arc extension managed identity"
        else
            log_error "Failed to create role assignment: $ROLE_ERR"
            log_error "The VI extension may not function correctly without this permission."
        fi
    fi

    if [ -z "$FOUNDRY_ACCOUNT_RESOURCE_ID" ]; then
        log_info "AI Foundry account resource ID not found. Skipping 'Cognitive Services OpenAI Contributor' role assignment."
    else
        log_info "Adding 'Cognitive Services OpenAI Contributor' role assignment on AI Foundry account..."

        EXISTING_OPENAI_ASSIGNMENT=$(az role assignment list \
            --assignee "$PRINCIPAL_ID" \
            --role "Cognitive Services OpenAI Contributor" \
            --scope "$FOUNDRY_ACCOUNT_RESOURCE_ID" \
            --query "[0].id" -o tsv 2>/dev/null || true)

        if [ -n "$EXISTING_OPENAI_ASSIGNMENT" ]; then
            log_success "Cognitive Services OpenAI Contributor role assignment already exists. Skipping."
        else
            OPENAI_ROLE_ERR=""
            if OPENAI_ROLE_ERR=$(az role assignment create \
                --assignee-object-id "$PRINCIPAL_ID" \
                --assignee-principal-type ServicePrincipal \
                --role "Cognitive Services OpenAI Contributor" \
                --scope "$FOUNDRY_ACCOUNT_RESOURCE_ID" 2>&1); then
                log_success "Cognitive Services OpenAI Contributor role assigned on AI Foundry account"
            else
                log_error "Failed to create Cognitive Services OpenAI Contributor role assignment: $OPENAI_ROLE_ERR"
                log_error "Agent inference scenarios may not function correctly without this permission."
            fi
        fi
    fi
fi

# =====================================================
# Verify VI Extension reached Succeeded state
# =====================================================
VI_EXT_STATE=$(az k8s-extension show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --cluster-name "$ARC_CLUSTER_NAME" \
    --cluster-type connectedClusters \
    --name videoindexer \
    --query "provisioningState" -o tsv 2>/dev/null | tr -d '\r' || echo "Unknown")

# =====================================================
# Acquire VI Extension Access Token (used by Steps 10-11)
# =====================================================
VI_ACCESS_TOKEN=""
VI_API_BASE=""

if [ "$VI_EXT_STATE" != "Succeeded" ]; then
    log_warning "VI extension provisioningState is '$VI_EXT_STATE' (expected 'Succeeded')."
    log_warning "Skipping camera and agent job setup. Run 'azd hooks run postprovision' to retry after the extension is ready."
elif [ "$MEDIA_STREAMER_ENABLED" = "false" ]; then
    log_info "Media streamer disabled (MEDIA_STREAMER_ENABLED=false). Skipping token acquisition, camera, and agent job setup."
else
    EXTENSION_ID=$(az k8s-extension show \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --cluster-name "$ARC_CLUSTER_NAME" \
        --cluster-type connectedClusters \
        --name videoindexer \
        --query "id" -o tsv 2>/dev/null | tr -d '\r' || true)

    if [ -z "$EXTENSION_ID" ]; then
        log_warning "Failed to retrieve VI extension ID. Skipping camera and agent job setup."
    else
        log_info "Generating VI extension access token..."
        TOKEN_URL="https://management.azure.com${AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID}/generateExtensionAccessToken?api-version=2023-06-02-preview"
        TOKEN_BODY="{\"permissionType\":\"Contributor\",\"scope\":\"Account\",\"extensionId\":\"${EXTENSION_ID}\"}"

        VI_ACCESS_TOKEN=$(az rest --method post --url "$TOKEN_URL" \
            --body "$TOKEN_BODY" \
            --query "accessToken" -o tsv 2>/dev/null | tr -d '\r' || true)

        if [ -z "$VI_ACCESS_TOKEN" ]; then
            log_warning "Failed to generate VI extension access token. Skipping camera and agent job setup."
        else
            log_success "VI extension access token obtained"
            VI_API_BASE="${VIDEO_INDEXER_ENDPOINT_URI}/Accounts/${AZURE_VIDEO_INDEXER_ACCOUNT_ID}"
            # TODO: Remove -k once a valid TLS certificate is configured
            # on the Nginx Ingress Controller (e.g. via cert-manager ClusterIssuer).
            # The endpoint uses HTTPS but the ingress does not yet have a trusted certificate.
            CURL_INSECURE_FLAG="-k"
        fi
    fi

    # =====================================================
    # Step 10: Create Sample Camera
    # =====================================================
    log_step 10 $TOTAL_STEPS "Creating Sample Camera"

    CAMERA_NAME="flags"
    CAMERA_RTSP_URL="rtsp://media-server.video-indexer:8554/${CAMERA_NAME}"
    CAMERA_ID=""

    if [ -z "$VI_ACCESS_TOKEN" ]; then
        log_warning "No VI access token available. Skipping camera creation."
    else
        log_info "Creating camera '$CAMERA_NAME'..."

        CAMERA_BODY="{\"Name\":\"${CAMERA_NAME}\",\"Description\":\"${CAMERA_NAME}\",\"RtspUrl\":\"${CAMERA_RTSP_URL}\",\"LiveStreamingEnabled\":true,\"RecordingEnabled\":true,\"IsPinned\":true,\"RecordingsRetentionInHours\":72,\"UseCameraNtp\":false}"

        CAMERA_RESPONSE=$(curl -s $CURL_INSECURE_FLAG -X POST "${VI_API_BASE}/cameras" \
            -H "Authorization: Bearer $VI_ACCESS_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$CAMERA_BODY" 2>/dev/null || true)

        CAMERA_ID=$(echo "$CAMERA_RESPONSE" | jq -r '.id // empty' 2>/dev/null || true)

        if [ -n "$CAMERA_ID" ]; then
            log_success "Camera '$CAMERA_NAME' created"
            write_key_value "Camera ID" "$CAMERA_ID"
        else
            log_warning "Failed to create camera: $CAMERA_RESPONSE"
        fi
    fi

    # =====================================================
    # Step 11: Create Agent Job
    # =====================================================
    log_step 11 $TOTAL_STEPS "Creating Agent Job"

    if [ -z "$VI_ACCESS_TOKEN" ]; then
        log_warning "No VI access token available. Skipping agent job creation."
    elif [ -z "$CAMERA_ID" ]; then
        log_warning "No camera available. Skipping agent job creation."
    else
        # Get the first available agent
        AGENT_ID=""
        AGENTS_RESPONSE=$(curl -s $CURL_INSECURE_FLAG -X GET "${VI_API_BASE}/agents" \
            -H "Authorization: Bearer $VI_ACCESS_TOKEN" 2>/dev/null || true)

        AGENT_ID=$(echo "$AGENTS_RESPONSE" | jq -r '.results[0].agentId // empty' 2>/dev/null || true)

        if [ -z "$AGENT_ID" ]; then
            log_warning "No agents found. Skipping agent job creation."
        else
            AGENT_NAME=$(echo "$AGENTS_RESPONSE" | jq -r '.results[0].name // empty' 2>/dev/null || true)
            write_key_value "Agent" "$AGENT_NAME"

            log_info "Creating agent job..."
            JOB_PROMPT='In the current frame, is there a flag of a country? Answer shortly in a JSON format: {\"isDetected\": true if a flag was detected or false if not, \"answer\": a full frame and flag textual description}'
            JOB_BODY="{\"agentId\":\"${AGENT_ID}\",\"cameraId\":\"${CAMERA_ID}\",\"name\":\"sample-agent-job\",\"description\":\"Sample agent job created during provisioning\",\"eventName\":\"sample-event\",\"enabled\":true,\"prompt\":\"${JOB_PROMPT}\",\"callbackUrl\":\"\",\"intervalInSeconds\":20,\"retentionInSeconds\":86400}"

            JOB_RESPONSE=$(curl -s $CURL_INSECURE_FLAG -X POST "${VI_API_BASE}/AgentJobs" \
                -H "Authorization: Bearer $VI_ACCESS_TOKEN" \
                -H "Content-Type: application/json" \
                -d "$JOB_BODY" 2>/dev/null || true)

            JOB_ID=$(echo "$JOB_RESPONSE" | jq -r '.id // empty' 2>/dev/null || true)

            if [ -n "$JOB_ID" ]; then
                log_success "Agent job created"
                write_key_value "Job ID" "$JOB_ID"
            else
                log_warning "Failed to create agent job: $JOB_RESPONSE"
            fi
        fi
    fi
fi

# =====================================================
# Step 12: Post-deployment health checks
# =====================================================
log_step 12 $TOTAL_STEPS "Running Post-Deployment Health Checks"

ARC_STATUS=$(az connectedk8s show \
    --name "$ARC_CLUSTER_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query "connectivityStatus" -o tsv 2>/dev/null | tr -d '\r' || echo "unknown")
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
    write_key_value "AI Foundry Endpoint"      "${AI_FOUNDRY_SERVICES_BASE_URL:-n/a}"
    if [ -n "${FOUNDRY_ACCOUNT_RESOURCE_ID:-}" ]; then
        write_key_value "AI Foundry Resource ID" "$FOUNDRY_ACCOUNT_RESOURCE_ID"
    fi
fi
if [ -n "${PRINCIPAL_ID:-}" ] && [ -n "${CAMERA_ID:-}" ]; then
    PORTAL_URL="https://www.videoindexer.ai/accounts/${AZURE_VIDEO_INDEXER_ACCOUNT_ID}/extensions/${PRINCIPAL_ID}/cameras/${CAMERA_ID}/live-stream?feature.VideoAssistant=true&feature.LiveActivity=true"
    write_key_value "VI Portal" "$PORTAL_URL"
    azd env set AZURE_VI_PORTAL_URL "$PORTAL_URL" 2>/dev/null || true
elif [ -n "${AZURE_VIDEO_INDEXER_ACCOUNT_ID:-}" ]; then
    PORTAL_URL="https://www.videoindexer.ai/accounts/${AZURE_VIDEO_INDEXER_ACCOUNT_ID}"
    write_key_value "VI Portal" "$PORTAL_URL"
    azd env set AZURE_VI_PORTAL_URL "$PORTAL_URL" 2>/dev/null || true
fi

echo ""
