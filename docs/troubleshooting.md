# Troubleshooting Guide

This guide provides solutions to common issues you may encounter when deploying and running the Video-Agents-Foundry-Solution.

## Pre-Provisioning Failures

### Azure CLI Not Authenticated

**Problem**: `preprovision` hook fails with authentication error
**Solution**:
- Run `az login` and authenticate with your Azure account
- If using a specific subscription, run `az account set --subscription <subscription-id>`

### Missing CLI Tools

**Problem**: `preprovision` hook reports missing tools
**Solution**: Install the required tools:
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (v2.x+)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm 3](https://helm.sh/docs/intro/install/)
- [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) (v1.18.0+)

### Resource Provider Not Registered

**Problem**: `preprovision` hook reports unregistered resource providers
**Solution**: Register the required providers:

```shell
az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ExtendedLocation
```

> **Note:** Registration can take several minutes. Check status with `az provider show --namespace <namespace> --query "registrationState"`.

### Insufficient GPU Quota

**Problem**: No available VM sizes shown in the interactive menu
**Solution**:
- Request additional GPU quota in the [Azure Portal](https://portal.azure.com/) under **Subscriptions** > **Usage + quotas**
- Try a different region with available GPU quota
- Select alternative VM sizes that are available in your subscription
- See the [quota check guide](quota_check.md) for detailed instructions

## Provisioning and Deployment Failures

### Resource Provisioning Timeout

**Problem**: `azd up` times out during provisioning
**Solution**:
1. Change the deployment location, as there may be availability constraints
2. Run `azd down` to clean up partial resources
3. Delete the `.azure` folder from your workspace
4. Run `azd up` again and select a different region

### Permission Errors

**Problem**: Authorization failed during deployment
**Solution**:
- Verify your account has `Microsoft.Authorization/roleAssignments/write` permissions
- Verify your account has `Microsoft.Resources/deployments/write` permissions
- If permissions were recently granted, wait a few minutes for propagation
- See the [Azure account setup guide](azure_account_setup.md) for details

### Debugging Deployment Issues

**Debug Commands**:
- Use `azd show` to display information about your app and resources
- Use `azd provision --debug` to enable detailed debugging output
- Check Azure Portal for deployment logs in the resource group

## AKS and Kubernetes Issues

### AKS Cluster Not Ready

**Problem**: AKS cluster fails to provision or connect
**Solution**:
- Check that you have sufficient quota for the selected VM sizes
- Verify the Kubernetes version is supported in your region
- Check AKS cluster events: `kubectl get events --all-namespaces --sort-by='.lastTimestamp'`

### GPU Operator Issues

**Problem**: NVIDIA GPU Operator pods not running
**Solution**:
- Verify GPU nodes are in `Ready` state: `kubectl get nodes`
- Check GPU Operator namespace: `kubectl get pods -n gpu-operator`
- Review GPU Operator logs: `kubectl logs -n gpu-operator <pod-name>`
- Ensure the selected VM size has NVIDIA GPUs (NCas, NCads, or similar families)

### Video Indexer Extension Issues

**Problem**: VI Arc Extension pods not starting
**Solution**:
- Check the `video-indexer` namespace: `kubectl get pods -n video-indexer`
- Verify Azure Arc connection: `kubectl get pods -n azure-arc`
- Check cert-manager is running: `kubectl get pods -n cert-manager`
- Review extension logs: `kubectl logs -n video-indexer <pod-name>`

### Post-Up Health Check Failures

**Problem**: `postup` health dashboard shows failed checks
**Solution**:
- Wait a few minutes for all pods to initialize
- Check specific namespace for failing pods: `kubectl describe pod <pod-name> -n <namespace>`
- Re-run the health check by running `azd up` again (it will skip already-provisioned resources)

## Azure Arc Issues

### Arc Connection Failed

**Problem**: AKS cluster cannot connect to Azure Arc
**Solution**:
- Ensure `Microsoft.Kubernetes` and `Microsoft.KubernetesConfiguration` providers are registered
- Check that the cluster has outbound internet connectivity
- Verify the managed identity has appropriate permissions

## AI Foundry Issues

### Model Deployment Failed

**Problem**: AI Foundry model deployment fails during provisioning
**Solution**:
- Verify model quota availability in your region at [AI Foundry Quota Management](https://ai.azure.com/managementCenter/quota)
- Try a different model or region
- Set `CREATE_FOUNDRY_PROJECT=false` if you don't need the AI Foundry component

## Getting Help

If you continue to experience issues after trying these solutions:

1. Check the [Azure Video Indexer documentation](https://learn.microsoft.com/azure/azure-video-indexer/)
2. Review the [AKS troubleshooting guide](https://learn.microsoft.com/azure/aks/troubleshooting)
3. Consult the [Azure Arc documentation](https://learn.microsoft.com/azure/azure-arc/)
4. Review the [Azure Developer CLI reference](https://learn.microsoft.com/azure/developer/azure-developer-cli/reference)
5. [Submit an issue](https://github.com/Azure-Samples/Video-Agents-Foundry-Solution/issues/new) on this repository

## Comprehensive Guides

For a detailed, step-by-step guide on creating an AKS cluster with GPU support and deploying the Video Indexer Arc extension, see:
- **[AKS-CLUSTER-SETUP.md](https://github.com/Azure-Samples/azure-video-indexer-samples/blob/master/VideoIndexerEnabledByArc/aks/AKS-CLUSTER-SETUP.md)** - Complete setup guide with output examples
- **[create-aks-cluster.sh](https://github.com/Azure-Samples/azure-video-indexer-samples/blob/master/VideoIndexerEnabledByArc/aks/create-aks-cluster.sh)** - Automated deployment script
> The guide includes GPU quota checking, troubleshooting tips, and support for live video processing.