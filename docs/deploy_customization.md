# Deployment Customization

This document describes how to customize the deployment of the Video-Agents-Foundry-Solution. Set these values before running `azd up`.

* [Customizing AKS Node Pools](#customizing-aks-node-pools)
* [Customizing AI Foundry](#customizing-ai-foundry)
* [Customizing Resource Names](#customizing-resource-names)
* [Enabling and Disabling Resources](#enabling-and-disabling-resources)

## Customizing AKS Node Pools

The solution deploys an AKS cluster with four node pools. You can customize the VM sizes for each pool:

### VM Size Selection

During deployment, the `preprovision` hook provides an interactive menu to select VM sizes with live quota checking. Alternatively, set environment variables before running `azd up`:

```shell
azd env set SYSTEM_VM_SIZE Standard_D4a_v4
azd env set WORKLOAD_VM_SIZE Standard_D32a_v4
azd env set DEEPSTREAM_GPU_VM_SIZE Standard_NC24ads_A100_v4
azd env set INFERENCE_GPU_VM_SIZE Standard_NC24ads_A100_v4
```

### Other AKS Settings

Set the Kubernetes version:

```shell
azd env set KUBERNETES_VERSION 1.32
```

Set the maximum node count for the DeepStream GPU node pool:

```shell
azd env set DEEPSTREAM_GPU_MAX_NODE_COUNT 1
```

## Customizing AI Foundry

By default, the solution provisions an Azure AI Foundry project with a model deployment. You can customize or disable this.

### Disable AI Foundry

If you don't need the AI Foundry component:

```shell
azd env set CREATE_FOUNDRY_PROJECT false
```

### Change the AI Model

Change the model name (default: `gpt-5.2`):

```shell
azd env set AI_MODEL_NAME gpt-5.2
```

Change the model version (default: `2025-12-11`):

```shell
azd env set AI_MODEL_VERSION 2025-12-11
```

Change the model deployment capacity:

```shell
azd env set AI_MODEL_CAPACITY 1
```

## Customizing Resource Names

By default, this template uses a naming convention with unique strings to prevent naming collisions. The following environment variables control resource naming via the `main.bicepparam` file:

| Variable | Description |
|----------|-------------|
| `AZURE_ENV_NAME` | Environment name prefix (default: `azd-foundry-solution`) |
| `AZURE_RESOURCE_GROUP` | Resource group name |
| `AZURE_LOCATION` | Azure region (default: `eastus2`) |

To override, run `azd env set <key> <value>` before running `azd up`.

## Enabling and Disabling Resources

### User Role Assignment

By default, the deployment creates role assignments for the current user. To disable:

```shell
azd env set CREATE_ROLE_FOR_USER false
```

### AI Foundry Project

To skip provisioning the AI Foundry project, hub, and model deployment:

```shell
azd env set CREATE_FOUNDRY_PROJECT false
```

## Environment Variable Reference

All configurable parameters with their defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `AZURE_ENV_NAME` | `azd-foundry-solution` | Environment name |
| `AZURE_RESOURCE_GROUP` | _(empty - auto-generated)_ | Resource group name |
| `AZURE_LOCATION` | `eastus2` | Azure region |
| `KUBERNETES_VERSION` | `1.32` | AKS Kubernetes version |
| `SYSTEM_VM_SIZE` | _(selected interactively)_ | System node pool VM |
| `WORKLOAD_VM_SIZE` | _(selected interactively)_ | Workload node pool VM |
| `DEEPSTREAM_GPU_VM_SIZE` | _(selected interactively)_ | DeepStream GPU node pool VM |
| `INFERENCE_GPU_VM_SIZE` | _(selected interactively)_ | Inference GPU node pool VM |
| `DEEPSTREAM_GPU_MAX_NODE_COUNT` | `1` | Max nodes in DeepStream pool |
| `CREATE_FOUNDRY_PROJECT` | `true` | Deploy AI Foundry |
| `AI_MODEL_NAME` | `gpt-5.2` | AI model name |
| `AI_MODEL_VERSION` | `2025-12-11` | AI model version |
| `AI_MODEL_CAPACITY` | `1` | Model deployment capacity |
| `CREATE_ROLE_FOR_USER` | `true` | Create RBAC role assignments |
| `MEDIA_STREAMER_ENABLED` | `true` | Enable media streamer (RTSP camera + sample agent job in post-provision) |
| `STORAGE_SKU_NAME` | `Standard_LRS` | Storage account SKU (`Standard_LRS`, `Standard_ZRS`, `Standard_GRS`). ZRS availability is checked during preprovision. |
