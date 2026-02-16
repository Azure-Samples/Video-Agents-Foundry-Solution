@description('Name of the AKS cluster')
param name string

@description('Azure region for the AKS cluster')
param location string

@description('Resource tags')
param tags object = {}

@description('Kubernetes version')
param kubernetesVersion string = '1.29'

@description('VM size for the system node pool')
param systemVmSize string = 'Standard_DS2_v2'

@description('VM size for the GPU node pool')
param gpuVmSize string = 'Standard_NC4as_T4_v3'

@description('Number of GPU nodes')
@minValue(1)
@maxValue(10)
param gpuNodeCount int = 1

@description('DNS prefix for the AKS cluster')
param dnsPrefix string = name

resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-01-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    kubernetesVersion: kubernetesVersion
    enableRBAC: true
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'calico'
      loadBalancerSku: 'standard'
    }
    agentPoolProfiles: [
      {
        name: 'systempool'
        count: 1
        minCount: 1
        maxCount: 3
        vmSize: systemVmSize
        osType: 'Linux'
        mode: 'System'
        enableAutoScaling: true
        type: 'VirtualMachineScaleSets'
      }
      {
        name: 'gpupool'
        count: gpuNodeCount
        vmSize: gpuVmSize
        osType: 'Linux'
        mode: 'User'
        enableAutoScaling: false
        type: 'VirtualMachineScaleSets'
        nodeTaints: [
          'sku=gpu:NoSchedule'
        ]
        nodeLabels: {
          hardware: 'gpu'
        }
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
