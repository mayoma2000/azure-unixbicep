// Shared type definitions. Bicep's user-defined types are the counterpart of the Terraform repo's
// `type = map(object({...}))` on var.fleets — and a stricter one: a union like
// 'internal' | 'external' is enforced by the compiler, where Terraform needs a validation block
// and only finds out at plan time.

@export()
@description('One rehosted application. The Terraform repo keys these by fleet name in a map; Bicep loops over arrays, so the key moves into the object as `name` and ARM catches a duplicate by colliding on resource names.')
type fleetType = {
  @description('Fleet name. Used in every resource name, so keep it lowercase/hyphenated.')
  @minLength(1)
  @maxLength(40)
  name: string

  @description('Canonical FQDN; gets the Private DNS A record.')
  hostname: string

  @description('e.g. Standard_D2as_v5')
  vmSize: string

  @description('Instance count. >= 2 spreads across availability zones for HA.')
  @minValue(1)
  @maxValue(50)
  instanceCount: int

  @description('Compute Gallery image version or managed image produced by Azure Migrate.')
  sourceImageId: string

  zones: string[]?

  targetPort: int?
  healthPath: string?
  healthProtocol: ('Http' | 'Https' | 'Tcp')?

  @description('Extra Private DNS A records. Under L4 there is no Host-header match to widen, so unlike the AWS repo there is no matched-only `aliases` list.')
  extraHostnames: string[]?

  @description('Egress exceptions beyond the VNet. Empty means VNet-only.')
  egressCidrs: string[]?

  @description('A stateful fleet is never silently rebuilt from its image on a failed probe.')
  stateful: bool?
  healthGracePeriod: string?

  @description('Bootstrap script under userdata/. Declares INTENT only: Bicep requires loadFileAsBase64() paths to be compile-time literals, so the file is registered in main.bicep\'s userDataByFleet map and an assert checks the two agree. See README.')
  userDataFile: string?

  ssh: sshType?

  adminUsername: string?
  adminSshKey: string?

  dataDisks: dataDiskType[]?

  artifacts: artifactsType?

  @description('Key Vaults in the workload resource group whose secrets this fleet may read.')
  keyVaultNames: string[]?
}

@export()
type sshType = {
  @description('Source CIDRs for TCP/22. Null falls back to the deployment-wide sshAdminCidrs.')
  sourceCidrs: string[]?
  @description('Allow from a Bastion subnet prefix instead of a CIDR list.')
  bastionSubnet: string?
}

@export()
type dataDiskType = {
  @minValue(0)
  lun: int
  @minValue(4)
  sizeGb: int
  storageAccountType: ('Premium_LRS' | 'StandardSSD_LRS' | 'Standard_LRS')?
  caching: ('None' | 'ReadOnly' | 'ReadWrite')?
}

@export()
type artifactsType = {
  @description('Extra containers this fleet may read, beyond its own.')
  readContainers: string[]?
  @description('Opens write on the fleet OWN container only, never on a shared one.')
  write: bool?
}
