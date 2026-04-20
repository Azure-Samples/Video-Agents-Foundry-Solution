targetScope = 'subscription'

// =====================================================
// Parameters
// =====================================================

@minLength(1)
@maxLength(64)
@description('Name of the environment used to generate a short unique hash for resources')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

@description('Name of the resource group')
param resourceGroupName string = ''

@description('ID of the principal (user) running the deployment')
param principalId string = ''

@description('Whether to create role assignments for the deploying user')
param createRoleForUser bool

@description('Whether to create a Foundry project and link it to the VI extension')
param createFoundryProject bool = true

@description('Model name to deploy in AI Foundry')
param aiModelName string

@description('Model version to deploy (e.g. 2024-07-18)')
param aiModelVersion string

@description('Model deployment capacity in TPM thousands')
param aiModelCapacity int

@description('Kubernetes version for the AKS cluster')
param kubernetesVersion string

@description('VM size for system node pool')
param systemVmSize string

@description('VM size for workload node pool')
param workloadVmSize string

@description('VM size for the GPU deepstream workload node pool')
param deepstreamGpuVmSize string

@description('VM size for the GPU inference workload node pool')
param inferenceGpuVmSize string

@description('Maximum number of deepstream GPU nodes')
param deepstreamGpuMaxNodeCount int

@description('Whether to enable the media streamer (RTSP camera + agent jobs in post-provision)')
param mediaStreamerEnabled bool

@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
])
@description('Storage account SKU. Use Standard_ZRS for zone redundancy where supported.')
param storageSkuName string

// =====================================================
// Variables
// =====================================================

// Inference GPU node count: 1 node when Foundry handles model serving, 2 otherwise
var inferenceGpuMaxNodeCount = createFoundryProject ? 1 : 2

var abbrs = loadJsonContent('abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var _resourceGroupName = !empty(resourceGroupName) ? resourceGroupName : '${environmentName}${abbrs.resourceGroup}'
var aksNodeResourceGroup = '${_resourceGroupName}-nodes'

var tags = {
  'provisioned-by': 'azd'
  'azd-env-name': environmentName
}

// =====================================================
// Resource Group
// =====================================================

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: _resourceGroupName
  location: location
  tags: tags
}

// =====================================================
// Module: Storage Account
// =====================================================

module storage 'modules/storage.bicep' = {
  name: 'storage-deployment'
  scope: rg
  params: {
    name: '${resourceToken}${abbrs.storageAccount}'
    location: location
    tags: tags
    skuName: storageSkuName
  }
}

// =====================================================
// Module: User-Assigned Managed Identity
// =====================================================

module managedIdentity 'modules/managed-identity.bicep' = {
  name: 'managed-identity-deployment'
  scope: rg
  params: {
    name: '${resourceToken}${abbrs.managedIdentity}'
    location: location
    tags: tags
    storageAccountId: storage.outputs.id
  }
}

// =====================================================
// Module: AKS Cluster
// =====================================================

module aks 'modules/aks.bicep' = {
  name: 'aks-deployment'
  scope: rg
  params: {
    name: '${resourceToken}${abbrs.aksCluster}'
    nodeResourceGroup: aksNodeResourceGroup
    location: location
    tags: tags
    kubernetesVersion: kubernetesVersion
    systemVmSize: systemVmSize
    workloadVmSize: workloadVmSize
    deepstreamGpuVmSize: deepstreamGpuVmSize
    inferenceGpuVmSize: inferenceGpuVmSize
    deepstreamGpuMaxNodeCount: deepstreamGpuMaxNodeCount
    inferenceGpuMaxNodeCount: inferenceGpuMaxNodeCount
  }
}

// =====================================================
// Module: Video Indexer Account
// =====================================================

module videoIndexer 'modules/vi-account.bicep' = {
  name: 'video-indexer-deployment'
  scope: rg
  params: {
    name: '${resourceToken}${abbrs.videoIndexer}'
    location: location
    tags: tags
    storageAccountId: storage.outputs.id
    managedIdentityId: managedIdentity.outputs.id
  }
}

// =====================================================
// Module: AI Foundry (Hub + Project + Model Deployment)
// =====================================================

module aiFoundry 'modules/ai-foundry.bicep' = if (createFoundryProject) {
  name: 'ai-foundry-deployment'
  scope: rg
  params: {
    name: '${resourceToken}${abbrs.aiServices}'
    location: location
    tags: tags
    modelName: aiModelName
    modelVersion: aiModelVersion
    modelCapacity: aiModelCapacity
    principalId: createRoleForUser ? principalId : ''
    managedIdentityPrincipalId: managedIdentity.outputs.principalId
  }
}

// =====================================================
// Outputs - used by azd and post-provision scripts
// =====================================================

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output AZURE_AKS_CLUSTER_NAME string = aks.outputs.name
output AZURE_AKS_NODE_RESOURCE_GROUP string = aksNodeResourceGroup
output AZURE_STORAGE_ACCOUNT_NAME string = storage.outputs.name
output AZURE_MANAGED_IDENTITY_ID string = managedIdentity.outputs.id
output AZURE_MANAGED_IDENTITY_CLIENT_ID string = managedIdentity.outputs.clientId
output AZURE_VIDEO_INDEXER_ACCOUNT_RESOURCE_ID string = videoIndexer.outputs.id
output AZURE_VIDEO_INDEXER_ACCOUNT_ID string = videoIndexer.outputs.accountId
output AZURE_VIDEO_INDEXER_ACCOUNT_NAME string = videoIndexer.outputs.name
output AZURE_STORAGE_ACCOUNT_ID string = storage.outputs.id
output AZURE_PRINCIPAL_ID string = principalId
output CREATE_ROLE_FOR_USER bool = createRoleForUser
output AZURE_DEEPSTREAM_NODE_SELECTOR_VALUE string = aks.outputs.deepstreamWorkloadLabelValue
output AZURE_INFERENCE_NODE_SELECTOR_VALUE string = aks.outputs.inferenceWorkloadLabelValue
output AI_FOUNDRY_ENDPOINT string = createFoundryProject ? aiFoundry.outputs.endpoint : ''
output AI_FOUNDRY_AI_SERVICES_ENDPOINT string = createFoundryProject ? aiFoundry.outputs.aiServicesEndpoint : ''
output AI_FOUNDRY_MODEL_DEPLOYMENT string = createFoundryProject ? aiFoundry.outputs.modelDeploymentName : ''
output AI_FOUNDRY_ACCOUNT_NAME string = createFoundryProject ? aiFoundry.outputs.accountName : ''
output AI_FOUNDRY_PROJECT_NAME string = createFoundryProject ? aiFoundry.outputs.projectName : ''
output MEDIA_STREAMER_ENABLED bool = mediaStreamerEnabled
