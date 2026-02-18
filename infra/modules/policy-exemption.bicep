targetScope = 'resourceGroup'

@description('Name of the policy exemption')
param name string = 'AllowSharedKeyForCsiStorageAccounts'

@description('The full resource ID of the policy assignment to exempt')
param policyAssignmentId string

@description('Display name for the exemption')
param displayName string = 'Allow AKS CSI driver to create storage accounts with shared key access'

@description('Description explaining the exemption')
param exemptionDescription string = 'The AKS Azure File CSI driver requires shared key access to create and mount storage accounts for PersistentVolumeClaims. This exemption is scoped to the AKS node resource group only.'

resource policyExemption 'Microsoft.Authorization/policyExemptions@2022-07-01-preview' = {
  name: name
  properties: {
    policyAssignmentId: policyAssignmentId
    exemptionCategory: 'Waiver'
    displayName: displayName
    description: exemptionDescription
  }
}

@description('The resource ID of the policy exemption')
output id string = policyExemption.id

@description('The name of the policy exemption')
output exemptionName string = policyExemption.name
