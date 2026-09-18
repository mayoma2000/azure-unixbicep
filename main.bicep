// azure-unixbicep — Bicep translation of sanservices/terraform-ec2-fleets.
//
// Rehosts on-prem VMs as Azure VM fleets. Each application is one entry in `fleets`; the module
// produces an NSG + a managed identity + its own internal Standard Load Balancer + a Flexible VMSS
// + a Private DNS A record + a per-fleet artifact container.
//
// Lifecycle: TEMPORARY bridge — retired as applications move to containers on AKS. Build
// everything to delete as cleanly as it was created.
//
// Read README.md first: three properties of the Terraform original do NOT survive the translation
// (the shared load balancer, the self-contained params file, and state-based drift detection), and
// one gets strictly better (a missing bootstrap script now fails at compile time).

targetScope = 'subscription'

import { fleetType } from './types.bicep'

@description('Selects naming and the params file. No propci — PCI fleets get their own repo.')
param environment 'nonprod' | 'prod'

@description('Canada Central is the ca-central-1 counterpart.')
param location string = 'canadacentral'

@description('Resource group that owns the fleets. Created by the foundation repo.')
param workloadResourceGroup string

@description('Workload subnet. Bicep has no data sources, so contract values arrive as parameters — the params file resolves them from App Configuration via readEnvironmentVariable(). See README.')
param subnetId string

param dnsSubscriptionId string
param dnsResourceGroup string
param dnsZoneName string

@description('Default source CIDRs for fleets that declare ssh. Internal ranges only.')
param sshAdminCidrs string[] = []

@description('"internet" = one outbound TCP/443 rule to the AzureCloud tag via NAT. "private-endpoints" = in-VNet only, required for the no-egress CDE.')
param azureApiEgress 'internet' | 'private-endpoints' = 'internet'

param enableArtifactStore bool = false
param enableDiskCmk bool = false

@description('One entry per rehosted application.')
param fleets fleetType[]

param tags object = {}

// =================================================================================================
// Bootstrap registry.
//
// loadFileAsBase64() takes a COMPILE-TIME LITERAL path, so unlike Terraform's
// file(var.user_data_dir/...) the script cannot be selected from a loop variable. Every fleet's
// script is registered here by name, and the assert below checks that no fleet declares a
// userDataFile without a matching entry — otherwise it would deploy silently unbootstrapped.
//
// The upside over Terraform: a path that does not exist fails at COMPILE time with the file name,
// where the Terraform repo needed a hand-written terraform_data precondition to report the same
// thing. loadFileAsBase64 also sidesteps escaping entirely — raw shell reaches the guest untouched.
// =================================================================================================

var userDataByFleet = {
  gcv: loadFileAsBase64('userdata/gcv.sh')
}

// =================================================================================================
// Guards live in scripts/preflight.sh, not in this template.
//
// Bicep's only precondition primitive is `assert`, and it is EXPERIMENTAL: enabling it stamps the
// compiled ARM template with languageVersion "2.1-experimental", putting every deployment of this
// repo on a language version Azure may change. For a bridge whose whole job is to vacate a
// datacenter inside a window, a stable template is worth more than three in-template checks — all
// of which are expressible as a shell check against the params file instead.
//
// What Bicep does enforce natively, and better than the Terraform original: a bootstrap script
// that does not exist fails at COMPILE time inside loadFileAsBase64(), naming the file. The
// Terraform repo needed a hand-written terraform_data precondition to report the same thing.
// =================================================================================================

var fleetNames = map(fleets, f => f.name)

// =================================================================================================
// Shared, optional infrastructure
// =================================================================================================

module diskCmk 'modules/disk-cmk.bicep' = if (enableDiskCmk) {
  scope: resourceGroup(workloadResourceGroup)
  name: 'fleet-disk-cmk'
  params: {
    location: location
    keyVaultName: 'kv-fleet-disks-${environment}'
    diskEncryptionSetName: 'des-fleets-${environment}'
    tags: tags
  }
}

module artifacts 'modules/artifacts.bicep' = if (enableArtifactStore) {
  scope: resourceGroup(workloadResourceGroup)
  name: 'fleet-artifacts'
  params: {
    storageAccountName: 'uvifleetartifacts${environment}'
    location: location
    // A container per fleet, plus any shared container a fleet asked to read.
    containerNames: union(
      fleetNames,
      flatten(map(fleets, f => f.?artifacts.?readContainers ?? []))
    )
    tags: tags
  }
}

// =================================================================================================
// The fleets
// =================================================================================================

module fleet 'modules/fleet.bicep' = [
  for f in fleets: {
    scope: resourceGroup(workloadResourceGroup)
    name: 'fleet-${f.name}'
    params: {
      fleet: f
      location: location
      subnetId: subnetId
      sshAdminCidrs: sshAdminCidrs
      azureApiEgress: azureApiEgress
      diskEncryptionSetId: diskCmk.?outputs.diskEncryptionSetId ?? ''
      artifactStorageAccountName: artifacts.?outputs.storageAccountName ?? ''
      userDataBase64: userDataByFleet[?f.name] ?? ''
      tags: tags
    }
  }
]

// =================================================================================================
// Private DNS, in the hub subscription. One module per fleet rather than one flattened list,
// because a lambda cannot reference a module output — so the records for a fleet are built in a
// context where that fleet's frontend IP is addressable.
// =================================================================================================

module dns 'modules/dns-records.bicep' = [
  for (f, i) in fleets: {
    scope: resourceGroup(dnsSubscriptionId, dnsResourceGroup)
    name: 'fleet-dns-${f.name}'
    params: {
      zoneName: dnsZoneName
      records: [
        for hostname in concat([f.hostname], f.?extraHostnames ?? []): {
          name: replace(hostname, '.${dnsZoneName}', '')
          ip: fleet[i].outputs.frontendIp
        }
      ]
    }
  }
]

// =================================================================================================
// Outputs — the per-fleet facts a cutover runbook needs.
// =================================================================================================

output fleetSummary array = [
  for (f, i) in fleets: {
    name: f.name
    hostname: f.hostname
    frontendIp: fleet[i].outputs.frontendIp
    loadBalancer: fleet[i].outputs.lbName
    vmss: fleet[i].outputs.vmssName
    identityClientId: fleet[i].outputs.identityClientId
    artifactContainer: enableArtifactStore ? f.name : ''
  }
]
