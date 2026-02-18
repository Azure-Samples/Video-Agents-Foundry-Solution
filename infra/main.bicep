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
param createRoleForUser bool = true

@description('Kubernetes version for the AKS cluster')
param kubernetesVersion string = '1.32'

@description('VM size for the GPU Deepstream node pool')
param gpuVmSize string = 'Standard_NC40ads_H100_v5'

@description('Maximum number of GPU Deepstream nodes')
@minValue(1)
@maxValue(10)
param gpuMaxNodeCount int = 1

// =====================================================
// Variables
// =====================================================

var abbrs = loadJsonContent('abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var _resourceGroupName = !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourceGroup}${environmentName}'
var tags = {
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
    name: '${abbrs.storageAccount}${resourceToken}'
    location: location
    tags: tags
    containerName: 'vi-arc-container'
  }
}

// =====================================================
// Module: User-Assigned Managed Identity
// =====================================================

module managedIdentity 'modules/managed-identity.bicep' = {
  name: 'managed-identity-deployment'
  scope: rg
  params: {
    name: '${abbrs.managedIdentity}${resourceToken}'
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
    name: '${abbrs.aksCluster}${resourceToken}'
    location: location
    tags: tags
    kubernetesVersion: kubernetesVersion
    gpuVmSize: gpuVmSize
    gpuMaxNodeCount: gpuMaxNodeCount
  }
}

// =====================================================
// Module: Video Indexer Account
// =====================================================

module videoIndexer 'modules/vi-account.bicep' = {
  name: 'video-indexer-deployment'
  scope: rg
  params: {
    name: '${abbrs.videoIndexer}${resourceToken}'
    location: location
    tags: tags
    storageAccountId: storage.outputs.id
    managedIdentityId: managedIdentity.outputs.id
  }
}

// =====================================================
// Outputs - used by azd and post-provision scripts
// =====================================================

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output AZURE_AKS_CLUSTER_NAME string = aks.outputs.name
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
