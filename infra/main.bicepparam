using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'azd-foundry-solution')
param resourceGroupName = readEnvironmentVariable('AZURE_RESOURCE_GROUP', '')
param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus2')
param principalId = readEnvironmentVariable('AZURE_PRINCIPAL_ID', '')
param createRoleForUser = bool(readEnvironmentVariable('CREATE_ROLE_FOR_USER', 'true'))
param kubernetesVersion = readEnvironmentVariable('KUBERNETES_VERSION', '1.32')

// VM_SIZES
param systemVmSize = readEnvironmentVariable('SYSTEM_VM_SIZE', '')
param workloadVmSize = readEnvironmentVariable('WORKLOAD_VM_SIZE', '')
param deepstreamGpuVmSize = readEnvironmentVariable('DEEPSTREAM_GPU_VM_SIZE', '')
param inferenceGpuVmSize = readEnvironmentVariable('INFERENCE_GPU_VM_SIZE', '')

param deepstreamGpuMaxNodeCount = int(readEnvironmentVariable('DEEPSTREAM_GPU_MAX_NODE_COUNT', '1'))
param createFoundryProject = bool(readEnvironmentVariable('CREATE_FOUNDRY_PROJECT', 'true'))
param aiModelName = readEnvironmentVariable('AI_MODEL_NAME', 'gpt-5.2')
param aiModelVersion = readEnvironmentVariable('AI_MODEL_VERSION', '2025-12-11')
param aiModelCapacity = int(readEnvironmentVariable('AI_MODEL_CAPACITY', '1'))
