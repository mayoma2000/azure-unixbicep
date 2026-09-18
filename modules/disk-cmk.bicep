// Optional customer-managed key for managed disks: Key Vault + key + disk encryption set.
// Counterpart of the Terraform repo's ebs.tf.

param location string
param keyVaultName string
param diskEncryptionSetName string
param tags object = {}

var cryptoServiceEncryptionUserRoleId = 'e147488a-f6f5-4113-8e2d-b22465e65bf1'

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    // Required before a key is allowed to back a disk encryption set.
    enablePurgeProtection: true
    softDeleteRetentionInDays: 90
    enabledForDiskEncryption: true
  }
}

resource key 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: vault
  name: 'fleet-disks'
  properties: {
    kty: 'RSA'
    keySize: 2048
    keyOps: ['decrypt', 'encrypt', 'wrapKey', 'unwrapKey']
  }
}

resource des 'Microsoft.Compute/diskEncryptionSets@2023-10-02' = {
  name: diskEncryptionSetName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    encryptionType: 'EncryptionAtRestWithCustomerKey'
    activeKey: {
      keyUrl: key.properties.keyUriWithVersion
    }
    rotationToLatestKeyVersionEnabled: true
  }
}

resource desKeyAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, des.id, cryptoServiceEncryptionUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      cryptoServiceEncryptionUserRoleId
    )
    principalId: des.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output diskEncryptionSetId string = des.id
