@description('Name of the AKS cluster')
param name string

@description('Azure region for the AKS cluster')
param location string

@description('Resource tags')
param tags object = {}

@description('Kubernetes version')
param kubernetesVersion string

@description('VM size for the system node pool')
param systemVmSize string = 'Standard_D4a_v4'

@description('VM size for the workload node pool')
param workloadVmSize string = 'Standard_D32a_v4'

@description('VM size for the GPU deepstream workload node pool')
param deepstreamGpuVmSize string = 'Standard_NV36ads_A10_v5'

@description('VM size for the GPU inference workload node pool')
param inferenceGpuVmSize string = 'Standard_NC24ads_A100_v4'

@description('Maximum number of system nodes')
@minValue(1)
@maxValue(10)
param systemMaxNodeCount int = 2

@description('Maximum number of workload nodes')
@minValue(1)
@maxValue(10)
param workloadMaxNodeCount int = 10

@description('Maximum number of deepstream GPU nodes')
@minValue(1)
@maxValue(10)
param deepstreamGpuMaxNodeCount int = 1

@description('Maximum number of inference GPU nodes')
@minValue(1)
@maxValue(10)
param inferenceGpuMaxNodeCount int = 2

@description('DNS prefix for the AKS cluster')
param dnsPrefix string = name

@description('Node resource group name')
param nodeResourceGroup string

@description('Node label value used to target deepstream workloads')
var deepstreamWorkloadLabel = 'deepstream'

@description('Node label value used to target inference workloads')
var inferenceWorkloadLabel = 'inference'

resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    kubernetesVersion: kubernetesVersion
    enableRBAC: true
    nodeResourceGroup: nodeResourceGroup

    // Security: enable OIDC issuer and workload identity
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
      imageCleaner: {
        enabled: true
        intervalHours: 24
      }
    }

    // Network: kubenet as per README
    networkProfile: {
      networkPlugin: 'kubenet'
      loadBalancerSku: 'standard'
    }

    // Addons: Azure Key Vault secrets provider
    addonProfiles: {
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: {
          enableSecretRotation: 'true'
        }
      }
    }

    // Auto-upgrade: node-image channel
    autoUpgradeProfile: {
      upgradeChannel: 'node-image'
      nodeOSUpgradeChannel: 'NodeImage'
    }

    // Agent pool profiles
    agentPoolProfiles: [
      {
        name: 'system'
        count: systemMaxNodeCount
        vmSize: systemVmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        mode: 'System'
        enableAutoScaling: false
        type: 'VirtualMachineScaleSets'
      }
      {
        name: 'workload'
        count: 0
        minCount: 0
        maxCount: workloadMaxNodeCount
        vmSize: workloadVmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        osDiskSizeGB: 100
        mode: 'User'
        enableAutoScaling: true
        type: 'VirtualMachineScaleSets'
        maxPods: 110
      }
      {
        name: 'deepstreamWorkload'
        count: 0
        minCount: 0
        maxCount: deepstreamGpuMaxNodeCount
        vmSize: deepstreamGpuVmSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        osDiskSizeGB: 200
        mode: 'User'
        enableAutoScaling: true
        type: 'VirtualMachineScaleSets'
        nodeTaints: [
          'nvidia.com/gpu=true:NoSchedule'
        ]
        nodeLabels: {
          workload: deepstreamWorkloadLabel
        }
        maxPods: 110
      }
      {
        name: 'inferenceWorkload'
        count: inferenceGpuMaxNodeCount
        vmSize: inferenceGpuVmSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        osDiskSizeGB: 200
        mode: 'User'
        enableAutoScaling: false
        type: 'VirtualMachineScaleSets'
        nodeTaints: [
          'nvidia.com/gpu=true:NoSchedule'
        ]
        nodeLabels: {
          workload: inferenceWorkloadLabel
        }
        maxPods: 110
      }
    ]
  }
}

@description('AKS cluster resource ID')
output id string = aksCluster.id

@description('AKS cluster name')
output name string = aksCluster.name

@description('AKS cluster system-assigned identity principal ID')
output principalId string = aksCluster.identity.principalId

@description('AKS OIDC issuer URL')
output oidcIssuerUrl string = aksCluster.properties.oidcIssuerProfile.issuerURL

@description('Deepstream workload label value used for node selection')
output deepstreamWorkloadLabelValue string = deepstreamWorkloadLabel

@description('Inference workload label value used for node selection')
output inferenceWorkloadLabelValue string = inferenceWorkloadLabel
