param accountId string = ''
param accountResourceId string = ''
param videoIndexerEndpointUri string = ''
param arcConnectedClusterName string = ''
param extensionName string = 'videoindexer'
@allowed([
  'preview'
  'stable'
])
param releaseTrain string = 'stable'
param version string
param useGpuForSummarization bool = false
param tolerationsKeyForGpu string = 'nvidia.com/gpu'
param liveVideoStreamEnabled bool = true
param agentsEnabled bool = true
param mediaUploadsEnabled bool = true
param liveSummarizationEnabled bool = true
param mediaServerStreamsEnabled bool = true
param apimInternalsBaseUrl string = ''
param apimOperationsBaseUrl string = ''

// Base config properties
param storageClass string = 'azurefile-csi-premium'

var baseConfigProperties = {
  'videoIndexer.endpointUri': videoIndexerEndpointUri
  'videoIndexer.accountId': accountId
  'videoIndexer.accountResourceId': accountResourceId
  'videoIndexer.mediaUploadsEnabled': string(mediaUploadsEnabled)
  'videoIndexer.liveVideoStreamEnabled': string(liveVideoStreamEnabled)
  'videoIndexer.agents.enabled': agentsEnabled
  'ViAi.mediaServerStreams.enabled': string(mediaServerStreamsEnabled)
  'storage.storageClass': storageClass
  'storage.accessMode': 'ReadWriteMany'
  'ViAi.gpu.enabled': string(useGpuForSummarization)
  'ViAi.gpu.tolerations.key': tolerationsKeyForGpu
  'ViAi.LiveSummarization.enabled': string(liveSummarizationEnabled)
}

// Add APIM URLs if provided
var apimConfigProperties = !empty(apimInternalsBaseUrl) && !empty(apimOperationsBaseUrl)
  ? {
      'videoIndexer.webApi.config.apimInternalsBaseUrl': apimInternalsBaseUrl
      'videoIndexer.webApi.config.apimOperationsBaseUrl': apimOperationsBaseUrl
    }
  : {}

var extensionConfigProperties = union(baseConfigProperties, apimConfigProperties)

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' existing = {
  name: arcConnectedClusterName
}
resource extension 'Microsoft.KubernetesConfiguration/extensions@2022-11-01' = {
  name: extensionName
  scope: connectedCluster
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    extensionType: 'microsoft.videoindexer'
    autoUpgradeMinorVersion: true
    releaseTrain: releaseTrain
    version: version
    scope: {
      cluster: {}
    }
    configurationSettings: extensionConfigProperties
  }
}

output result string = extension.properties.provisioningState
