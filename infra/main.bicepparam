using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'azd-foundry-solution')
param resourceGroupName = readEnvironmentVariable('AZURE_RESOURCE_GROUP', '')
param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus2')
param principalId = readEnvironmentVariable('AZURE_PRINCIPAL_ID', '')
param createRoleForUser = bool(readEnvironmentVariable('CREATE_ROLE_FOR_USER', 'true'))
param kubernetesVersion = readEnvironmentVariable('KUBERNETES_VERSION', '1.32')
param deepstreamGpuVmSize = readEnvironmentVariable('DEEPSTREAM_GPU_VM_SIZE', 'Standard_NC16as_T4_v3')
param inferenceGpuVmSize = readEnvironmentVariable('INFERENCE_GPU_VM_SIZE', 'Standard_NC16as_T4_v3')
param deepstreamGpuMaxNodeCount = int(readEnvironmentVariable('DEEPSTREAM_GPU_MAX_NODE_COUNT', '1'))
param inferenceGpuMaxNodeCount = int(readEnvironmentVariable('INFERENCE_GPU_MAX_NODE_COUNT', '2')) // TODO: make this dynamic based on foundry or not
param createFoundryProject = bool(readEnvironmentVariable('CREATE_FOUNDRY_PROJECT', 'false'))
param aiModelName = readEnvironmentVariable('AI_MODEL_NAME', 'gpt-4o-mini')
param aiModelVersion = readEnvironmentVariable('AI_MODEL_VERSION', '2024-07-18')
param aiModelCapacity = int(readEnvironmentVariable('AI_MODEL_CAPACITY', '1'))
