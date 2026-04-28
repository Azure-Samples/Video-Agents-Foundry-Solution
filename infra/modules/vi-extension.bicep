@description('Video Indexer account ID (GUID)')
param accountId string

@description('Video Indexer account resource ID')
param accountResourceId string

@description('Video Indexer endpoint URI')
param videoIndexerEndpointUri string

@description('Name of the Azure Arc-connected cluster')
param arcConnectedClusterName string

@description('Name of the VI extension')
param extensionName string = 'videoindexer'

@allowed([
  'dev'
  'preview'
  'stable'
])
@description('Release train for the extension')
param releaseTrain string = 'stable'

@description('Whether to use GPU for summarization')
param useGpuForSummarization bool = false

@description('Tolerations key for GPU scheduling')
param tolerationsKeyForGpu string = 'nvidia.com/gpu'

@description('Node selector value for deepstream workloads')
param deepstreamNodeSelectorValue string

@description('Node selector value for inference workloads')
param inferenceNodeSelectorValue string

@description('Enable live video stream')
param liveVideoStreamEnabled bool = true

@description('Enable media streamer')
param mediaStreamerEnabled bool = true

@description('Media streamer image')
param mediaStreamerImage string = 'mcr.microsoft.com/vi-arc/media-streamer'

@description('Media streamer image tag')
param mediaStreamerTag string = '1.17.0-2026.04.09.3'

@description('Enable agents')
param agentsEnabled bool = true

@description('Enable media uploads')
param mediaUploadsEnabled bool = true

@description('Enable live summarization')
param liveSummarizationEnabled bool = false

@description('Enable the inference agent (should be disabled when a Foundry project handles model serving)')
param inferenceAgentEnabled bool = false

@description('Azure OpenAI base URL for agents runtime')
param agentsRuntimeAzureOpenAIBaseUrl string = ''

@description('Azure OpenAI model for agents runtime')
param agentsRuntimeAzureOpenAIModel string = ''

// Base config properties
@description('Storage class for persistent volumes')
param storageClass string = 'azurefile-csi-premium'

var azureOpenAIBaseUrl = replace(agentsRuntimeAzureOpenAIBaseUrl, ' ', '')
var azureOpenAIModel = replace(agentsRuntimeAzureOpenAIModel, ' ', '')
var useAzureOpenAIForAgentsRuntime = !empty(azureOpenAIBaseUrl) && !empty(azureOpenAIModel)
var effectiveInferenceAgentEnabled = useAzureOpenAIForAgentsRuntime ? false : inferenceAgentEnabled

var baseConfigProperties = {
  'videoIndexer.endpointUri': videoIndexerEndpointUri
  'videoIndexer.accountId': accountId
  'videoIndexer.accountResourceId': accountResourceId
  'videoIndexer.mediaUploadsEnabled': string(mediaUploadsEnabled)
  'videoIndexer.liveVideoStreamEnabled': string(liveVideoStreamEnabled)
  'videoIndexer.agents.enabled': string(agentsEnabled)
  'storage.storageClass': storageClass
  'storage.accessMode': 'ReadWriteMany'
  'agents.agentsRuntime.modelProviders.azureOpenAI.enabled': string(useAzureOpenAIForAgentsRuntime)
  'agents.agentsRuntime.modelProviders.selfHosted.enabled': string(!useAzureOpenAIForAgentsRuntime)
  'ViAi.inferenceAgent.enabled': string(effectiveInferenceAgentEnabled)
  'ViAi.gpu.enabled': string(useGpuForSummarization)
  'ViAi.gpu.tolerations.key': tolerationsKeyForGpu
  'ViAi.mediaServerStreams.enabled': string(mediaStreamerEnabled)
  'ViAi.mediaServerStreams.image.repository': string(mediaStreamerImage)
  'ViAi.mediaServerStreams.image.tag': string(mediaStreamerTag)
  'ViAi.deepstream.nodeSelector.workload': deepstreamNodeSelectorValue
  'ViAi.inference.nodeSelector.workload': inferenceNodeSelectorValue
  'ViAi.LiveSummarization.enabled': string(liveSummarizationEnabled)
}

var agentsRuntimeAzureOpenAIProps = useAzureOpenAIForAgentsRuntime ? {
  'agents.agentsRuntime.modelProviders.azureOpenAI.overrideBaseUrl': azureOpenAIBaseUrl
} : {}

var agentsRuntimeSelfHostedModelProps = !useAzureOpenAIForAgentsRuntime ? {
  'agents.agentsRuntime.modelProviders.selfHosted.availableModels[0]': 'gpt-oss:20b'
} : {}

var agentsRuntimeAzureOpenAIModelProps = !empty(azureOpenAIModel) ? {
  'agents.agentsRuntime.modelProviders.azureOpenAI.availableModels[0]': azureOpenAIModel
} : {}

var extensionConfigProperties = union(
  baseConfigProperties,
  agentsRuntimeAzureOpenAIProps,
  agentsRuntimeSelfHostedModelProps,
  agentsRuntimeAzureOpenAIModelProps
)

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
    autoUpgradeMinorVersion: false
    version: '1.6.121-morelisrael-pr'
    releaseTrain: 'dev'
    scope: {
      cluster: {
        releaseNamespace: 'video-indexer'
      }
    }
    configurationSettings: extensionConfigProperties
  }
}

output result string = extension.properties.provisioningState
