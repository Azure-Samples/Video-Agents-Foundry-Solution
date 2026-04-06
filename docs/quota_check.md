# Quota Check Instructions

Before deploying the Video-Agents-Foundry-Solution, ensure you have sufficient quota in your Azure subscription for the required resources.

## GPU Quota

This solution requires GPU-enabled VMs for video processing at the edge. The default configuration uses `Standard_NC24ads_A100_v4` VMs for GPU node pools.

### Check GPU Quota

1. Navigate to the [Azure Portal](https://portal.azure.com/)
2. Go to **Subscriptions** > Select your subscription
3. Click **Usage + quotas** in the left menu
4. Filter by:
   - **Provider**: `Microsoft.Compute`
   - **Region**: Your target deployment region
5. Search for the VM family you plan to use (e.g., `NCasv3`, `NCadsA100v4`)
6. Verify that you have sufficient vCPU quota available

### Default VM Sizes

The solution deploys four AKS node pools with these default VM sizes:

| Node Pool | Default VM Size | Purpose |
|-----------|----------------|---------|
| System | `Standard_D4a_v4` | AKS system components |
| Workload | `Standard_D32a_v4` | General workload processing |
| DeepStream GPU | `Standard_NC24ads_A100_v4` | NVIDIA DeepStream video processing |
| Inference GPU | `Standard_NC24ads_A100_v4` | AI model inference |

> **Note:** During deployment, the `preprovision` hook provides an interactive menu to select VM sizes with live quota checking. You can choose alternative VM sizes based on your available quota.

### Request Additional Quota

If you need more quota:

1. Go to **Subscriptions** > **Usage + quotas** in the Azure Portal
2. Click **Request Increase** next to the quota you need
3. Fill in the required details and submit the request
4. Allow up to 24-48 hours for the request to be processed

## Azure OpenAI Model Quota

If you are deploying the optional AI Foundry project (enabled by default), ensure you have quota for the AI model:

- **Default model**: `gpt-5.2`
- Navigate to [Azure AI Foundry Quota Management](https://ai.azure.com/managementCenter/quota) to check and manage your model quota

## Azure Resource Provider Registration

The following resource providers must be registered in your subscription:

- `Microsoft.Kubernetes`
- `Microsoft.KubernetesConfiguration`
- `Microsoft.ExtendedLocation`

The `preprovision` hook validates these automatically. To register manually:

```shell
az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ExtendedLocation
```

## Additional Prerequisites

Ensure the following tools are installed:

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (v2.x+)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm 3](https://helm.sh/docs/intro/install/)
- [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) (v1.18.0+)
