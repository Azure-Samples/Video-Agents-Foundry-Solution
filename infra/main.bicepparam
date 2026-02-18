using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME')
param resourceGroupName = readEnvironmentVariable('AZURE_RESOURCE_GROUP', '')
param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus2')
param principalId = readEnvironmentVariable('AZURE_PRINCIPAL_ID', '')
param createRoleForUser = bool(readEnvironmentVariable('CREATE_ROLE_FOR_USER', 'true'))
param kubernetesVersion = readEnvironmentVariable('KUBERNETES_VERSION', '1.32')
param gpuVmSize = readEnvironmentVariable('GPU_VM_SIZE', 'Standard_NC40ads_H100_v5')
param gpuMaxNodeCount = int(readEnvironmentVariable('GPU_MAX_NODE_COUNT', '1'))
