@description('Name of the Azure Arc-connected cluster')
param arcClusterName string

@description('Name of the VI extension')
param extensionName string = 'video-indexer'

@description('Video Indexer account resource ID')
param viAccountId string

@description('Storage account resource ID')
param storageAccountId string

@description('User-assigned managed identity client ID')
param managedIdentityClientId string

@description('User-assigned managed identity resource ID')
param managedIdentityId string

resource arcCluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' existing = {
  name: arcClusterName
}

resource viExtension 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' = {
  name: extensionName
  scope: arcCluster
  properties: {
    extensionType: 'Microsoft.VideoIndexer'
    autoUpgradeMinorVersion: true
    releaseTrain: 'stable'
    configurationSettings: {
      'VideoIndexerAccountId': viAccountId
      'VideoIndexerStorageAccountId': storageAccountId
      'VideoIndexerManagedIdentityClientId': managedIdentityClientId
      'VideoIndexerManagedIdentityResourceId': managedIdentityId
    }
  }
}

@description('Extension resource ID')
output id string = viExtension.id

@description('Extension name')
output name string = viExtension.name
