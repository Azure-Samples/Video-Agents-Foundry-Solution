# Local Development

This guide describes how to work with the Video-Agents-Foundry-Solution locally for development and testing.

## Prerequisites

- [Azure Developer CLI (azd)](https://aka.ms/install-azd) (v1.18.0+)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (v2.x+)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm 3](https://helm.sh/docs/intro/install/)
- [Git](https://git-scm.com/downloads)
- \[Windows Only\] [PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) - Make sure `pwsh.exe` is in `PATH`

## Dev Container Setup

The fastest way to get a consistent development environment is using the included Dev Container configuration.

### GitHub Codespaces

1. Click the button below to open in GitHub Codespaces:

    [![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/Azure-Samples/Video-Agents-Foundry-Solution)

2. Wait for the container to build (this may take several minutes)
3. A terminal will be available with all tools pre-installed

### VS Code Dev Containers

1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
2. Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) in VS Code
3. Open the project in VS Code
4. When prompted, click **Reopen in Container**, or run the command **Dev Containers: Reopen in Container**
5. Wait for the container to build

The Dev Container includes:
- Python 3.11
- Azure Developer CLI (azd)
- Azure CLI
- VS Code extensions for Azure, Bicep, GitHub Actions, and Docker

> **Note:** The Dev Container requires at least 8 GB of RAM.

## Local Environment Setup

If you prefer to work outside of a Dev Container:

1. Install all [prerequisites](#prerequisites)
2. Clone the repository:

    ```shell
    git clone https://github.com/Azure-Samples/Video-Agents-Foundry-Solution.git
    cd Video-Agents-Foundry-Solution
    ```

3. Log in to Azure:

    ```shell
    az login
    azd auth login
    ```

## Understanding the Project Structure

This is an infrastructure-only accelerator. There is no application source code (`src/` folder). The solution consists of:

| Folder | Purpose |
|--------|---------|
| `infra/` | Bicep templates for Azure resource provisioning |
| `infra/modules/` | Modular Bicep files (AKS, AI Foundry, VI Account, etc.) |
| `hooks/` | PowerShell/bash scripts for deployment orchestration |
| `docs/` | Documentation |
| `.devcontainer/` | Dev Container configuration |
| `.github/workflows/` | CI/CD workflows |

## Working with Bicep Templates

The infrastructure is defined in Bicep files under `infra/`:

- `main.bicep` - Subscription-scoped entry point
- `main.bicepparam` - Parameter bindings from environment variables
- `modules/aks.bicep` - AKS cluster with 4 node pools (system, workload, DeepStream GPU, inference GPU)
- `modules/ai-foundry.bicep` - AI Hub, Project, and model deployment
- `modules/vi-account.bicep` - Azure Video Indexer account
- `modules/vi-extension.bicep` - VI Arc extension
- `modules/storage.bicep` - Blob storage
- `modules/managed-identity.bicep` - User-assigned managed identity
- `modules/cert-manager.bicep` - TLS certificate management

### Modifying Infrastructure

1. Edit the Bicep files as needed
2. Test your changes:

    ```shell
    az bicep build --file infra/main.bicep
    ```

3. Deploy with:

    ```shell
    azd up
    ```

## Working with Hooks

The deployment hooks in `hooks/` automate pre- and post-deployment steps:

| Hook | Purpose |
|------|---------|
| `preprovision.ps1/.sh` | Validates prerequisites, interactive VM size selection |
| `postprovision.ps1/.sh` | Connects AKS to Arc, installs GPU Operator, deploys VI Extension |
| `postup.ps1/.sh` | Runs health check dashboard showing pod status |

### Testing Hooks Locally

You can run hook scripts independently for testing:

```shell
# PowerShell
pwsh ./hooks/preprovision.ps1

# Bash
bash ./hooks/preprovision.sh
```

> **Note:** Some hooks require environment variables that are set during `azd provision`. Load them from `.azure/<env>/.env` if testing independently.

## Environment Variables

After running `azd up`, environment variables are stored in `.azure/<env-name>/.env`. Key variables include:

| Variable | Description |
|----------|-------------|
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |
| `AZURE_RESOURCE_GROUP` | Resource group name |
| `AZURE_LOCATION` | Azure region |
| `AZURE_AKS_CLUSTER_NAME` | AKS cluster name |
| `AZURE_VIDEO_INDEXER_ACCOUNT_ID` | VI account ID |
| `AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID` | VI account resource ID |
| `AI_FOUNDRY_SERVICES_BASE_URL` | AI Services base endpoint used for agents runtime |
| `AI_FOUNDRY_PROJECT_NAME` | AI Foundry project name |

## Redeployment

To redeploy after making changes:

```shell
# Re-provision infrastructure only
azd provision

# Full deployment (provision + post-hooks)
azd up
```

## VS Code Debug Configurations

See the [deployment customization guide](deploy_customization.md) for available VS Code debug configurations.
