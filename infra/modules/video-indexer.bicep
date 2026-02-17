@description('Name of the Video Indexer account')
param name string

@description('Azure region for the Video Indexer account')
param location string

@description('Resource tags')
param tags object = {}

@description('Resource ID of the storage account')
param storageAccountId string

@description('Resource ID of the user-assigned managed identity')
param managedIdentityId string

resource videoIndexerAccount 'Microsoft.VideoIndexer/accounts@2024-01-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    storageServices: {
      resourceId: storageAccountId
      userAssignedIdentity: managedIdentityId
    }
  }
}

@description('Video Indexer account resource ID')
output id string = videoIndexerAccount.id

@description('Video Indexer account name')
output name string = videoIndexerAccount.name

@description('Video Indexer account ID (GUID)')
output accountId string = videoIndexerAccount.properties.accountId
