# Deployment Guide

## Prerequisites

If you do not have an Azure Subscription, you can sign up for a [free Azure account](https://azure.microsoft.com/free/) and create an Azure Subscription.

To deploy this solution successfully, your Azure account must have the following permissions on the targeted Azure Subscription:

- **Microsoft.Authorization/roleAssignments/write** permissions at the subscription scope.
  _(typically included if you have [Role Based Access Control Administrator](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#role-based-access-control-administrator-preview), [User Access Administrator](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#user-access-administrator), or [Owner](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#owner) role)_
- **Microsoft.Resources/deployments/write** permissions at the subscription scope.

For more details on Azure account setup, see the [Azure account setup guide](azure_account_setup.md).

### Additional Requirements

- **VI Arc Extension Approval** - Submit your subscription for approval via [this form](https://aka.ms/vi-register) before deploying
- **GPU Quota** - Sufficient GPU quota for your chosen VM sizes in your target region. See the [quota check guide](quota_check.md) for details
- **Required CLI Tools**:
  - [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (v2.x+)
  - [kubectl](https://kubernetes.io/docs/tasks/tools/)
  - [Helm 3](https://helm.sh/docs/intro/install/)
  - [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) (v1.18.0+)

### Region Availability

Check the [Azure Products by Region](https://azure.microsoft.com/explore/global-infrastructure/products-by-region/?products=all&regions=all) page and select a **region** where the following services are available:

- [Azure Kubernetes Service (AKS)](https://learn.microsoft.com/azure/aks/)
- [Azure Arc](https://learn.microsoft.com/azure/azure-arc/)
- [Azure Video Indexer](https://learn.microsoft.com/azure/azure-video-indexer/)
- [Azure AI Foundry](https://learn.microsoft.com/azure/ai-foundry/) (if deploying AI agents)
- GPU-enabled VM SKUs (e.g., NCasv3, NCadsA100v4 families)

### Important Note for PowerShell Users

If you encounter issues running PowerShell scripts due to execution policy, you can temporarily adjust it:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Deployment Options & Steps

Pick from the options below to see step-by-step instructions for GitHub Codespaces, VS Code Dev Containers, or local environments.

| [![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/microsoft/Video-Agents-Foundry-Solution) | [![Open in Dev Containers](https://img.shields.io/static/v1?style=for-the-badge&label=Dev%20Containers&message=Open&color=blue&logo=visualstudiocode)](https://vscode.dev/redirect?url=vscode://ms-vscode-remote.remote-containers/cloneInVolume?url=https://github.com/Azure-Samples/Video-Agents-Foundry-Solution) |
|---|---|

<details>
  <summary><b>Deploy in GitHub Codespaces</b></summary>

### GitHub Codespaces

You can run this template virtually by using GitHub Codespaces. The button will open a web-based VS Code instance in your browser:

1. Open the template (this may take several minutes):

    [![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/microsoft/Video-Agents-Foundry-Solution)

2. Open a terminal window
3. Continue with the [deploying steps](#deploying-with-azd)

</details>

<details>
  <summary><b>Deploy in VS Code Dev Containers</b></summary>

### VS Code Dev Containers

A related option is VS Code Dev Containers, which will open the project in your local VS Code using the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers):

1. Start Docker Desktop (install it if not already installed: [Docker Desktop](https://www.docker.com/products/docker-desktop/))
2. Open the project:

    [![Open in Dev Containers](https://img.shields.io/static/v1?style=for-the-badge&label=Dev%20Containers&message=Open&color=blue&logo=visualstudiocode)](https://vscode.dev/redirect?url=vscode://ms-vscode-remote.remote-containers/cloneInVolume?url=https://github.com/Azure-Samples/Video-Agents-Foundry-Solution)

3. In the VS Code window that opens, once the project files show up (this may take several minutes), open a terminal window
4. Continue with the [deploying steps](#deploying-with-azd)

</details>

<details>
  <summary><b>Deploy in your local environment</b></summary>

### Local Environment

If you're not using one of the above options, then you'll need to:

1. Make sure the following tools are installed:
   - [Azure Developer CLI (azd)](https://aka.ms/install-azd) (v1.18.0+)
   - [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (v2.x+)
   - [kubectl](https://kubernetes.io/docs/tasks/tools/)
   - [Helm 3](https://helm.sh/docs/intro/install/)
   - [Git](https://git-scm.com/downloads)
   - \[Windows Only\] [PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) - Make sure `pwsh.exe` is added to `PATH`

2. Clone the repository:

   ```shell
   azd init -t Video-Agents-Foundry-Solution
   ```

3. Open the project folder in your terminal or editor
4. Continue with the [deploying steps](#deploying-with-azd)

</details>

<br/>

<details>
  <summary><b>Configurable Deployment Settings</b></summary>

When you start a deployment, most parameters will have default values. You can change the following settings:

| **Setting** | **Description** | **Default** |
|------------|----------------|-------------|
| **Azure Region** | Select a region with GPU quota | `eastus2` |
| **Kubernetes Version** | AKS cluster Kubernetes version | `1.32` |
| **System VM Size** | System node pool VM size | `Standard_D4a_v4` |
| **Workload VM Size** | Workload node pool VM size | `Standard_D32a_v4` |
| **DeepStream GPU VM Size** | DeepStream GPU node pool | `Standard_NC24ads_A100_v4` |
| **Inference GPU VM Size** | Inference GPU node pool | `Standard_NC24ads_A100_v4` |
| **Create Foundry Project** | Deploy AI Foundry project | `true` |
| **AI Model Name** | OpenAI model for agents | `gpt-5.2` |
| **AI Model Version** | Model version | `2025-12-11` |

For a detailed description of customizable fields, view the [deployment customization guide](deploy_customization.md).

</details>

## Deploying with AZD

Once you've opened the project in [Codespaces](#github-codespaces), [Dev Containers](#vs-code-dev-containers), or [locally](#local-environment), deploy to Azure:

1. (Optional) Customize your deployment settings. See the [deployment customization guide](deploy_customization.md) for details.

2. Run the deployment:

    ```shell
    azd up
    ```

3. You will be prompted to:
   - Provide an `azd` environment name (e.g., "vi-agents-solution")
   - Select a subscription from your Azure account
   - Select a location with sufficient GPU quota
   - Choose VM sizes for each AKS node pool (interactive menu with live quota checking)

   > **Note:** The `preprovision` hook validates prerequisites including Azure CLI authentication, required CLI tools, Azure resource provider registration, and GPU quota availability.

4. The deployment process will:
   - **Provision** Azure resources via Bicep (AKS cluster, Video Indexer account, storage, managed identity, and optionally AI Foundry)
   - **Connect** AKS to Azure Arc
   - **Install** NVIDIA GPU Operator via Helm
   - **Deploy** Video Indexer Arc Extension
   - **Run** a health check dashboard showing pod status across namespaces

   This process typically takes 15-25 minutes. After `azd up` completes, allow an additional 20-35 minutes for GPU drivers and VI extension pods to fully initialize (45-60 minutes total).

5. After deployment completes, the health dashboard will show the status of all components:
   - `gpu-operator` namespace (NVIDIA GPU Operator)
   - `video-indexer` namespace (VI Arc Extension)
   - `app-routing-system` namespace
   - `azure-arc` namespace
   - `cert-manager` namespace

6. View information about your deployment:

    ```shell
    azd show
    ```

## Resource Cleanup

When you no longer need the deployed resources, clean up by running:

```shell
azd down
```

This will delete the resource group and all associated Azure resources.

## GitHub Actions CI/CD

This repo includes a GitHub Actions workflow (`.github/workflows/azure-dev.yml`) for automated deployments. To set it up:

1. Configure OpenID Connect (OIDC) federated credentials for your Azure service principal
2. Set the required GitHub repository variables (see the workflow file for the full list)
3. Set the `AZD_INITIAL_ENVIRONMENT_CONFIG` secret

The workflow triggers on push to `main` or manual dispatch, and runs `azd provision` followed by `azd deploy`.

## Next Steps

- Review the [troubleshooting guide](troubleshooting.md) if you encounter issues
- Check [deployment customization](deploy_customization.md) for advanced configuration
- Explore [observability features](observability.md) for monitoring and tracing
