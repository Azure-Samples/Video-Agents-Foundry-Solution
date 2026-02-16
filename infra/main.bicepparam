using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'MY_ENV')
param resourceGroupName = readEnvironmentVariable('AZURE_RESOURCE_GROUP', '')
param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus2')
param principalId = readEnvironmentVariable('AZURE_PRINCIPAL_ID', '')
param createRoleForUser = bool(readEnvironmentVariable('CREATE_ROLE_FOR_USER', 'true'))
param kubernetesVersion = readEnvironmentVariable('KUBERNETES_VERSION', '1.29')
param gpuVmSize = readEnvironmentVariable('GPU_VM_SIZE', 'Standard_NC4as_T4_v3')
param gpuNodeCount = int(readEnvironmentVariable('GPU_NODE_COUNT', '1'))
