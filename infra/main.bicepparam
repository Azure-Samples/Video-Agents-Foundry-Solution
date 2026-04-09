using './main.bicep'

// =====================================================
// azd-managed parameters (auto-populated by azd)
// =====================================================
param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'azd-foundry-solution')
param resourceGroupName = readEnvironmentVariable('AZURE_RESOURCE_GROUP', '')
param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus2')
param principalId = readEnvironmentVariable('AZURE_PRINCIPAL_ID', '')

// =====================================================
// Custom parameters — handled by azd native prompting
// =====================================================
// The following parameters are NOT set here via readEnvironmentVariable().
// Instead, azd will prompt the user interactively using @allowed / @description
// decorators defined in main.bicep.
//
// To pre-set values and skip prompts, use:
//   azd env config set infra.parameters.<paramName> <value>
//
// Examples:
//   azd env config set infra.parameters.systemVmSize Standard_D4a_v4
//   azd env config set infra.parameters.kubernetesVersion 1.32
//   azd env config set infra.parameters.createFoundryProject true
