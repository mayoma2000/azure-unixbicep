using '../main.bicep'

param environment = 'nonprod'
param location = 'canadacentral'

param workloadResourceGroup = readEnvironmentVariable('PLATFORM_WORKLOAD_RG')
param subnetId = readEnvironmentVariable('PLATFORM_PRIVATE_SUBNET_ID')
param dnsSubscriptionId = readEnvironmentVariable('PLATFORM_DNS_SUBSCRIPTION_ID')
param dnsResourceGroup = readEnvironmentVariable('PLATFORM_DNS_RG')
param dnsZoneName = readEnvironmentVariable('PLATFORM_DNS_ZONE')

param azureApiEgress = 'internet'
param enableArtifactStore = false
param enableDiskCmk = false

param tags = {
  environment: 'nonprod'
  managedBy: 'azure-unixbicep'
  lifecycle: 'migration-bridge'
}

// A single small instance is enough to prove the whole chain: VMSS -> backend pool -> probe ->
// rule -> frontend IP -> Private DNS. Bump instanceCount to >= 2 to also prove zone redundancy.
param fleets = [
  {
    name: 'demo'
    hostname: 'demo.svc.nonprod.aws.sandals.net'
    vmSize: 'Standard_B2s'
    instanceCount: 1
    sourceImageId: '/subscriptions/REPLACE/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/uviImages/images/al2023-base/versions/1.0.0'
    targetPort: 443
    healthPath: '/'
    healthProtocol: 'Tcp'
    stateful: false
    zones: ['1']
  }
]
