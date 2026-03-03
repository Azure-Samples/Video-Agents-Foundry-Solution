@description('Name of the Azure Arc-connected cluster')
param arcConnectedClusterName string

@description('Name of the cert-manager extension')
param extensionName string = 'azure-cert-manager'

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' existing = {
  name: arcConnectedClusterName
}

resource certManagerExtension 'Microsoft.KubernetesConfiguration/extensions@2022-11-01' = {
  name: extensionName
  scope: connectedCluster
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    extensionType: 'Microsoft.CertManagement'
    autoUpgradeMinorVersion: false
    scope: {
      cluster: {
        releaseNamespace: 'cert-manager'
      }
    }
  }
}

@description('Cert-manager extension provisioning state')
output provisioningState string = certManagerExtension.properties.provisioningState
