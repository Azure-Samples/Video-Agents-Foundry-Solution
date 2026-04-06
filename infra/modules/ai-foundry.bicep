// ============================================================
// AI Foundry — AI Services Account + Project + Model Deployment
// ============================================================
// Creates an Azure AI Services account (hub) with project management,
// an AI project under it, and a model deployment (e.g. gpt-4o-mini).
// Used when createFoundryProject=true.
// ============================================================

@description('Name for the AI Services account')
param name string

@description('Azure region')
param location string

@description('Resource tags')
param tags object = {}

@description('Model name to deploy (e.g. gpt-4o-mini)')
param modelName string

@description('Model version (e.g. 2024-07-18)')
param modelVersion string

@description('Model deployment SKU capacity (tokens-per-minute in thousands)')
param modelCapacity int = 1

@description('Principal ID of the deploying user (for RBAC). Leave empty to skip user role assignment.')
param principalId string = ''

@description('Principal ID of the managed identity (for RBAC). Leave empty to skip.')
param managedIdentityPrincipalId string = ''

var projectName = '${name}-project'
var deploymentName = '${name}-chat'

// Built-in role definition IDs
var cognitiveServicesOpenAIUserId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var cognitiveServicesContributorId = '25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68'

// ─── AI Services Account (Hub) ──────────────────────────────
resource aiAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: name
  location: location
  tags: tags
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
    allowProjectManagement: true
  }
}

// ─── Project (child of hub account) ─────────────────────────
resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: aiAccount
  name: projectName
  location: location
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'S0'
  }
  properties: {}
}

// ─── Model Deployment ───────────────────────────────────────
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: aiAccount
  name: deploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

// ─── Outputs ────────────────────────────────────────────────

// ─── RBAC: Deploying user → Cognitive Services OpenAI User ──
resource userOpenAIRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(aiAccount.id, principalId, cognitiveServicesOpenAIUserId)
  scope: aiAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAIUserId)
    principalId: principalId
    principalType: 'User'
  }
}

// ─── RBAC: Deploying user → Cognitive Services Contributor ──
resource userContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(aiAccount.id, principalId, cognitiveServicesContributorId)
  scope: aiAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesContributorId)
    principalId: principalId
    principalType: 'User'
  }
}

// ─── RBAC: Managed Identity → Cognitive Services OpenAI User ─
resource identityOpenAIRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(managedIdentityPrincipalId)) {
  name: guid(aiAccount.id, managedIdentityPrincipalId, cognitiveServicesOpenAIUserId)
  scope: aiAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAIUserId)
    principalId: managedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ─── Outputs ────────────────────────────────────────────────
@description('AI Services account name')
output accountName string = aiAccount.name

@description('AI project name')
output projectName string = aiProject.name

@description('AI Foundry endpoint (project-scoped)')
output endpoint string = 'https://${name}.cognitiveservices.azure.com/api/projects/${projectName}'

@description('AI Services base endpoint')
output aiServicesEndpoint string = aiAccount.properties.endpoint

@description('Model deployment name')
output modelDeploymentName string = modelDeployment.name

@description('AI Services account resource ID')
output accountId string = aiAccount.id
