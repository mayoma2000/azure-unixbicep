// Artifact store. One Storage Account per environment for getting files onto instances — the
// auditable alternative to scp, which the access model exists to avoid.
//
// One container per fleet. A container is a real RBAC scope, so each fleet's identity is granted
// Blob Data Reader on its own container and nothing else — cleaner than the AWS repo's S3 prefix
// policies, with no ABAC condition to get wrong. The grants themselves live in fleet.bicep, next
// to the identity they apply to.

param storageAccountName string
param location string
param containerNames string[]
param tags object = {}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    // Identity-only. No account keys to leak, and it forces the bootstrap script through the
    // fleet's managed identity.
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [
  for name in containerNames: {
    parent: blobService
    name: name
    properties: {
      publicAccess: 'None'
    }
  }
]

output storageAccountName string = storage.name
