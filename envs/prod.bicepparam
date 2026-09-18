using '../main.bicep'

// Contract values. Bicep has NO data sources — there is no `data "azurerm_app_configuration_key"`
// counterpart — so the platform contract cannot be read from inside the template. It arrives as
// parameters instead, and CI resolves them from App Configuration before deploying:
//
//   export PLATFORM_WORKLOAD_RG=$(az appconfig kv show -n uvi-platform-config \
//     --key platform/net/workload-resource-group --label prod --query value -o tsv)
//
// This is the one structural loss versus Terraform: the params file is no longer self-contained,
// and a deployment is only as correct as the pipeline that populated its environment.
param environment = 'prod'
param location = 'canadacentral'

param workloadResourceGroup = readEnvironmentVariable('PLATFORM_WORKLOAD_RG')
param subnetId = readEnvironmentVariable('PLATFORM_PRIVATE_SUBNET_ID')

param dnsSubscriptionId = readEnvironmentVariable('PLATFORM_DNS_SUBSCRIPTION_ID')
param dnsResourceGroup = readEnvironmentVariable('PLATFORM_DNS_RG')
param dnsZoneName = readEnvironmentVariable('PLATFORM_DNS_ZONE')

param azureApiEgress = 'internet'
param enableArtifactStore = true
param enableDiskCmk = false

param sshAdminCidrs = []

param tags = {
  environment: 'prod'
  managedBy: 'azure-unixbicep'
  lifecycle: 'migration-bridge'
}

param fleets = [
  // gcv — Guest Contact Validation API, rehosted from torpgcvws1. Lucee 5.4.7.3 on Tomcat behind
  // nginx; ~700 MB of app data across two filesystems, so this is a REBUILD on a current image
  // with a path-level restore from the artifact container, not an Azure Migrate block replication
  // of an EOL guest.
  //
  // SCOPE: serve the app at gcv.svc.prod.aws.sandals.net over TLS, running the source's own nginx
  // config. Unlike the AWS rehost, TLS terminates ON THE VM — a Standard LB is layer 4 — so the
  // guest's certificates are kept, not stripped.
  {
    name: 'gcv'
    hostname: 'gcv.svc.prod.aws.sandals.net'
    vmSize: 'Standard_D2as_v5' // source 2 vCPU / 8 GiB (java -Xmx512m, light)
    instanceCount: 1
    sourceImageId: '/subscriptions/REPLACE/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/uviImages/images/al2023-lucee/versions/1.0.0'
    targetPort: 443
    healthPath: '/'
    healthProtocol: 'Https'
    userDataFile: 'gcv.sh'
    stateful: true
    zones: ['1']
    artifacts: {
      write: false
    }
  }

  // obeadmin — arrives from Azure Migrate already configured, so it registers no bootstrap script.
  {
    name: 'obeadmin'
    hostname: 'obeadmin.svc.prod.aws.sandals.net'
    vmSize: 'Standard_D2as_v5' // source 2 vCPU / 7.8 GiB — parity sizing
    instanceCount: 1
    sourceImageId: '/subscriptions/REPLACE/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/uviImages/images/obeadmin-migrated/versions/1.0.0'
    targetPort: 443
    healthPath: '/'
    healthProtocol: 'Https'
    stateful: true
    zones: ['1']
  }
]
