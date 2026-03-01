using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'azd-foundry-solution')
param resourceGroupName = readEnvironmentVariable('AZURE_RESOURCE_GROUP', '')
param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus2')
param principalId = readEnvironmentVariable('AZURE_PRINCIPAL_ID', '')
param createRoleForUser = bool(readEnvironmentVariable('CREATE_ROLE_FOR_USER', 'true'))
param kubernetesVersion = readEnvironmentVariable('KUBERNETES_VERSION', '1.32')
param deepstreamGpuVmSize = readEnvironmentVariable('DEEPSTREAM_GPU_VM_SIZE', 'Standard_NV36ads_A10_v5')
param inferenceGpuVmSize = readEnvironmentVariable('INFERENCE_GPU_VM_SIZE', 'Standard_NC24ads_A100_v4')
param deepstreamGpuMaxNodeCount = int(readEnvironmentVariable('DEEPSTREAM_GPU_MAX_NODE_COUNT', '1'))
param inferenceGpuMaxNodeCount = int(readEnvironmentVariable('INFERENCE_GPU_MAX_NODE_COUNT', '2'))
