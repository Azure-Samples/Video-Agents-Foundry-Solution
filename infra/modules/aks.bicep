@description('Name of the AKS cluster')
param name string

@description('Azure region for the AKS cluster')
param location string

@description('Resource tags')
param tags object = {}

@description('Kubernetes version')
param kubernetesVersion string = '1.32'

@description('VM size for the system node pool')
param systemVmSize string = 'Standard_D4a_v4'

@description('VM size for the GPU Deepstream node pool')
param gpuVmSize string = 'Standard_NC40ads_H100_v5'

@description('Maximum number of GPU Deepstream nodes')
@minValue(1)
@maxValue(10)
param gpuMaxNodeCount int = 1

@description('DNS prefix for the AKS cluster')
param dnsPrefix string = name

@description('Node resource group name')
param nodeResourceGroup string = '${name}-nodes'

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
        count: 2
        vmSize: systemVmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        mode: 'System'
        enableAutoScaling: false
        type: 'VirtualMachineScaleSets'
      }
      {
        name: 'gpudeepstrm'
        count: 0
        minCount: 0
        maxCount: gpuMaxNodeCount
        vmSize: gpuVmSize
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
          workload: 'deepstream'
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
