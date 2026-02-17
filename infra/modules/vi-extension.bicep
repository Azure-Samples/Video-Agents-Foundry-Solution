@description('Video Indexer account ID (GUID)')
param accountId string = ''

@description('Video Indexer account resource ID')
param accountResourceId string = ''

@description('Video Indexer endpoint URI')
param videoIndexerEndpointUri string = ''

@description('Name of the Azure Arc-connected cluster')
param arcConnectedClusterName string = ''

@description('Name of the VI extension')
param extensionName string = 'videoindexer'

@allowed([
  'preview'
  'stable'
])
@description('Release train for the extension')
param releaseTrain string = 'stable'

@description('Whether to use GPU for summarization')
param useGpuForSummarization bool = false

@description('Tolerations key for GPU scheduling')
param tolerationsKeyForGpu string = 'nvidia.com/gpu'

@description('Enable live video stream')
param liveVideoStreamEnabled bool = true

@description('Enable agents')
param agentsEnabled bool = true

@description('Enable media uploads')
param mediaUploadsEnabled bool = true

@description('Enable live summarization')
param liveSummarizationEnabled bool = true

@description('Enable media server streams')
param mediaServerStreamsEnabled bool = true

@description('APIM internals base URL')
param apimInternalsBaseUrl string = ''

@description('APIM operations base URL')
param apimOperationsBaseUrl string = ''

// Base config properties
@description('Storage class for persistent volumes')
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
    scope: {
      cluster: {}
    }
    configurationSettings: extensionConfigProperties
  }
}

output result string = extension.properties.provisioningState
