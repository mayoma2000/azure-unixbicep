// One rehosted application: NSG + identity + its own internal Standard Load Balancer + VMSS.
//
// WHY A PER-FLEET LOAD BALANCER AND NOT A SHARED ONE
// The Terraform counterpart attaches every fleet to one shared LB, because azurerm_lb_probe and
// azurerm_lb_rule are provider-side read-modify-write PATCHes against the parent LB — Terraform
// can add a rule to an LB owned by another state. ARM cannot: of the loadBalancers child types
// only backendAddressPools and inboundNatRules are independently deployable, while probes,
// loadBalancingRules and frontendIPConfigurations all report
// `Permitted scopes for deployment: "none"` and must be declared inside the parent resource.
//
// So a shared LB in Bicep would force the probe and rule for every fleet into whichever template
// owns the LB, splitting one fleet's declaration across two repos. Giving each fleet its own LB
// keeps the whole path in one declaration, which is the actual point of the repo. It also drops
// the frontend-IP-slot contract and both of its cross-entry guards, since nothing is shared to
// collide over. The cost is one Standard LB per fleet.

import { fleetType } from '../types.bicep'

param fleet fleetType
param location string
param subnetId string
param sshAdminCidrs string[]
param azureApiEgress 'internet' | 'private-endpoints'
param diskEncryptionSetId string = ''
param artifactStorageAccountName string = ''
param userDataBase64 string = ''
param tags object = {}

// Built-in role definition IDs.
var roles = {
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  storageBlobDataReader: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}

var targetPort = fleet.?targetPort ?? 443
var healthPath = fleet.?healthPath ?? '/'
var healthProtocol = fleet.?healthProtocol ?? 'Https'
var stateful = fleet.?stateful ?? true
var zones = fleet.?zones ?? ['1', '2', '3']
var egressCidrs = fleet.?egressCidrs ?? []
var dataDisks = fleet.?dataDisks ?? []
var keyVaultNames = fleet.?keyVaultNames ?? []
var artifactReadContainers = fleet.?artifacts.?readContainers ?? []
var artifactWrite = fleet.?artifacts.?write ?? false
var useArtifacts = !empty(artifactStorageAccountName)
var lbName = 'lb-fleet-${fleet.name}'

// =================================================================================================
// NSG. Azure allows all outbound by default, the opposite of an AWS security group, so reaching the
// Terraform repo's posture — VNet-only egress unless the fleet declares exceptions — takes explicit
// allows ahead of a deny-all at 4000.
// =================================================================================================

// Data-plane traffic through a Standard LB arrives with the ORIGINAL client IP: it is a
// pass-through, not a proxy like an ALB. Allowing only the AzureLoadBalancer tag would pass the
// health probes and drop every real request, so both rules are needed.
var inboundRules = concat(
  [
    {
      name: 'allow-app-from-lb'
      properties: {
        priority: 100
        direction: 'Inbound'
        access: 'Allow'
        protocol: 'Tcp'
        sourcePortRange: '*'
        destinationPortRange: string(targetPort)
        sourceAddressPrefix: 'AzureLoadBalancer'
        destinationAddressPrefix: '*'
      }
    }
    {
      name: 'allow-app-from-vnet'
      properties: {
        priority: 110
        direction: 'Inbound'
        access: 'Allow'
        protocol: 'Tcp'
        sourcePortRange: '*'
        destinationPortRange: string(targetPort)
        sourceAddressPrefix: 'VirtualNetwork'
        destinationAddressPrefix: '*'
      }
    }
  ],
  // SSH is the exception for guests too old to run the VM agent. This owns the network path, NOT
  // the credential: adminSshKey is a no-op without cloud-init, and an Azure Migrate guest keeps
  // its on-prem users and keys.
  fleet.?ssh != null
    ? [
        {
          name: 'allow-ssh-internal'
          properties: {
            priority: 200
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '22'
            sourceAddressPrefixes: fleet.?ssh.?bastionSubnet != null
              ? [fleet.ssh!.bastionSubnet!]
              : (fleet.?ssh.?sourceCidrs ?? sshAdminCidrs)
            destinationAddressPrefix: '*'
          }
        }
      ]
    : []
)

var outboundRules = concat(
  [
    {
      name: 'allow-egress-vnet'
      properties: {
        priority: 100
        direction: 'Outbound'
        access: 'Allow'
        protocol: '*'
        sourcePortRange: '*'
        destinationPortRange: '*'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: 'VirtualNetwork'
      }
    }
  ],
  // One TCP/443 rule to the AzureCloud service tag when the guest agent egresses over NAT. Under
  // 'private-endpoints' the rule is omitted and the agent must reach Azure in-VNet.
  azureApiEgress == 'internet'
    ? [
        {
          name: 'allow-egress-azure-api'
          properties: {
            priority: 110
            direction: 'Outbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '443'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: 'AzureCloud'
          }
        }
      ]
    : [],
  !empty(egressCidrs)
    ? [
        {
          name: 'allow-egress-declared'
          properties: {
            priority: 120
            direction: 'Outbound'
            access: 'Allow'
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefixes: egressCidrs
          }
        }
      ]
    : [],
  [
    {
      name: 'deny-egress-default'
      properties: {
        priority: 4000
        direction: 'Outbound'
        access: 'Deny'
        protocol: '*'
        sourcePortRange: '*'
        destinationPortRange: '*'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: '*'
      }
    }
  ]
)

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-fleet-${fleet.name}'
  location: location
  tags: tags
  properties: {
    securityRules: concat(inboundRules, outboundRules)
  }
}

// =================================================================================================
// Identity — the instance-profile counterpart. Managed identity + RBAC, no static keys.
// =================================================================================================

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-fleet-${fleet.name}'
  location: location
  tags: tags
}

resource keyVaults 'Microsoft.KeyVault/vaults@2023-07-01' existing = [
  for name in keyVaultNames: {
    name: name
  }
]

resource keyVaultGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (name, i) in keyVaultNames: {
    scope: keyVaults[i]
    name: guid(keyVaults[i].id, identity.id, roles.keyVaultSecretsUser)
    properties: {
      roleDefinitionId: subscriptionResourceId(
        'Microsoft.Authorization/roleDefinitions',
        roles.keyVaultSecretsUser
      )
      principalId: identity.properties.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

// =================================================================================================
// Artifact access. Isolation is CLEANER than the AWS repo's S3 prefixes: a container is a real
// RBAC scope, so the fleet reads its OWN container and nothing else — no ABAC condition and no
// prefix policy to get wrong.
// =================================================================================================

resource ownContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = if (useArtifacts) {
  name: '${artifactStorageAccountName}/default/${fleet.name}'
}

resource artifactReadOwn 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useArtifacts) {
  scope: ownContainer
  name: guid(fleet.name, 'artifact-read-own', identity.id)
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roles.storageBlobDataReader
    )
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// write opens the fleet's OWN container only, never a shared one.
resource artifactWriteOwn 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useArtifacts && artifactWrite) {
  scope: ownContainer
  name: guid(fleet.name, 'artifact-write-own', identity.id)
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roles.storageBlobDataContributor
    )
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource extraContainers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = [
  for name in artifactReadContainers: {
    name: '${artifactStorageAccountName}/default/${name}'
  }
]

resource artifactReadExtra 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (name, i) in artifactReadContainers: {
    scope: extraContainers[i]
    name: guid(fleet.name, 'artifact-read', name, identity.id)
    properties: {
      roleDefinitionId: subscriptionResourceId(
        'Microsoft.Authorization/roleDefinitions',
        roles.storageBlobDataReader
      )
      principalId: identity.properties.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

// =================================================================================================
// The fleet's own internal Standard Load Balancer. Frontend IP is dynamic out of the workload
// subnet; main.bicep reads it back for the Private DNS A record, so no IP bookkeeping lands in the
// params file.
// =================================================================================================

resource lb 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: lbName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'fe-${fleet.name}'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv4'
        }
        zones: zones
      }
    ]
    backendAddressPools: [
      {
        name: 'bep-${fleet.name}'
      }
    ]
    probes: [
      {
        name: 'probe-${fleet.name}'
        properties: {
          protocol: healthProtocol
          port: targetPort
          requestPath: healthProtocol == 'Tcp' ? null : healthPath
          intervalInSeconds: 15
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'rule-${fleet.name}'
        properties: {
          protocol: 'Tcp'
          frontendPort: 443
          backendPort: targetPort
          frontendIPConfiguration: {
            id: resourceId(
              'Microsoft.Network/loadBalancers/frontendIPConfigurations',
              lbName,
              'fe-${fleet.name}'
            )
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, 'bep-${fleet.name}')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, 'probe-${fleet.name}')
          }
          idleTimeoutInMinutes: 30
          enableTcpReset: true
          disableOutboundSnat: true
        }
      }
    ]
  }
}

// =================================================================================================
// Compute. Flexible-orchestration scale set is the ASG counterpart: N instances spread across
// availability zones behind one backend pool.
// =================================================================================================

resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-07-01' = {
  name: 'vmss-${fleet.name}'
  location: location
  tags: union(tags, { fleet: fleet.name, 'lifecycle-stage': 'migration-bridge' })
  zones: zones
  sku: {
    name: fleet.vmSize
    capacity: fleet.instanceCount
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    orchestrationMode: 'Flexible'
    platformFaultDomainCount: 1
    singlePlacementGroup: false
    // A stateful fleet is never silently rebuilt from its image on a failed probe — the Terraform
    // repo suspends the ASG HealthCheck process for the same reason. Consequence, and it has
    // bitten: after a manual delete nothing launches a replacement, so a reprovision has to scale
    // down and back up rather than relying on auto-repair.
    automaticRepairsPolicy: {
      enabled: !stateful
      gracePeriod: fleet.?healthGracePeriod ?? 'PT30M'
    }
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: take(fleet.name, 9)
        adminUsername: fleet.?adminUsername ?? 'azureuser'
        linuxConfiguration: {
          disablePasswordAuthentication: true
          provisionVMAgent: true
          ssh: fleet.?adminSshKey != null
            ? {
                publicKeys: [
                  {
                    path: '/home/${fleet.?adminUsername ?? 'azureuser'}/.ssh/authorized_keys'
                    keyData: fleet.adminSshKey!
                  }
                ]
              }
            : null
        }
      }
      storageProfile: {
        imageReference: {
          id: fleet.sourceImageId
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
            diskEncryptionSet: empty(diskEncryptionSetId) ? null : { id: diskEncryptionSetId }
          }
        }
        dataDisks: [
          for disk in dataDisks: {
            lun: disk.lun
            createOption: 'Empty'
            diskSizeGB: disk.sizeGb
            caching: disk.?caching ?? 'ReadWrite'
            managedDisk: {
              storageAccountType: disk.?storageAccountType ?? 'Premium_LRS'
              diskEncryptionSet: empty(diskEncryptionSetId) ? null : { id: diskEncryptionSetId }
            }
          }
        ]
      }
      networkProfile: {
        // Flexible orchestration requires networkApiVersion alongside
        // networkInterfaceConfigurations; Uniform used networkProfileConfiguration instead.
        networkApiVersion: '2020-11-01'
        networkInterfaceConfigurations: [
          {
            name: 'nic-${fleet.name}'
            properties: {
              primary: true
              networkSecurityGroup: {
                id: nsg.id
              }
              ipConfigurations: [
                {
                  name: 'ipconfig-${fleet.name}'
                  properties: {
                    primary: true
                    privateIPAddressVersion: 'IPv4'
                    subnet: {
                      id: subnetId
                    }
                    loadBalancerBackendAddressPools: [
                      {
                        id: lb.properties.backendAddressPools[0].id
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
      userData: empty(userDataBase64) ? null : userDataBase64
    }
  }
}

output frontendIp string = lb.properties.frontendIPConfigurations[0].properties.privateIPAddress
output identityPrincipalId string = identity.properties.principalId
output identityClientId string = identity.properties.clientId
output vmssName string = vmss.name
output lbName string = lb.name
