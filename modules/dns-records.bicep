// Private DNS A records, deployed at the hub resource group's scope so the zone stays owned by the
// DNS repo. The Terraform counterpart aliases a name to the shared ALB's FQDN; here each record is
// an A to the private frontend IP of that fleet's own load balancer.

@description('Private DNS zone name, e.g. svc.prod.aws.sandals.net')
param zoneName string

@description('Records to write: { name: <label relative to the zone>, ip: <IPv4> }')
param records { name: string, ip: string }[]

param ttl int = 60
param tags object = {}

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: zoneName
}

resource aRecords 'Microsoft.Network/privateDnsZones/A@2024-06-01' = [
  for record in records: {
    parent: zone
    name: record.name
    properties: {
      ttl: ttl
      aRecords: [
        {
          ipv4Address: record.ip
        }
      ]
      metadata: tags
    }
  }
]
