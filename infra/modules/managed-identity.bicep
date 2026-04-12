@description('Name of the user-assigned managed identity')
param name string

@description('Azure region for the managed identity')
param location string

@description('Resource tags')
param tags object = {}

@description('Resource ID of the storage account to grant access to')
param storageAccountId string

// Built-in role definition IDs
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

// Grant Storage Blob Data Contributor role on the storage account
resource storageBlobDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountId, managedIdentity.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      storageBlobDataContributorRoleId
    )
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Reference the existing storage account for scoping the role assignment
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: last(split(storageAccountId, '/'))
}

@description('Managed identity resource ID')
output id string = managedIdentity.id

@description('Managed identity principal ID')
output principalId string = managedIdentity.properties.principalId

@description('Managed identity client ID')
output clientId string = managedIdentity.properties.clientId

@description('Managed identity name')
output name string = managedIdentity.name
