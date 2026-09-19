# azure-unixbicep

Bicep translation of — common IaC to rehost on-prem VMs as Azure VM fleets.

Each application is one entry in `fleets`; the module produces an NSG + a managed identity + an internal Standard Load Balancer + a Flexible VMSS + a Private DNS A record + a per-fleet artifact container.

**Lifecycle:** TEMPORARY bridge — retired as applications move to containers on AKS. Build everything to delete as cleanly as it was created.

```bash
export PLATFORM_WORKLOAD_RG=... PLATFORM_PRIVATE_SUBNET_ID=... \
       PLATFORM_DNS_SUBSCRIPTION_ID=... PLATFORM_DNS_RG=... PLATFORM_DNS_ZONE=...

./scripts/preflight.sh envs/prod.bicepparam
az deployment sub what-if --location canadacentral \
  --template-file main.bicep --parameters envs/prod.bicepparam
```

## Layout

| Path | What |
|---|---|
| `main.bicep` | Subscription-scoped orchestrator; loops over `fleets` |
| `types.bicep` | User-defined types — the `fleetType` schema |
| `modules/fleet.bicep` | One fleet: NSG, identity, LB, VMSS, RBAC |
| `modules/artifacts.bicep` | Storage account + a container per fleet |
| `modules/disk-cmk.bicep` | Optional Key Vault + key + disk encryption set |
| `modules/dns-records.bicep` | A records, deployed at the hub RG's scope |
| `envs/*.bicepparam` | Per-environment fleet declarations |
| `userdata/*.sh` | Bootstrap scripts |
| `scripts/preflight.sh` | Cross-entry guards Bicep cannot express |

## Resource mapping

| terraform-ec2-fleets (AWS) | This repo (Azure) |
|---|---|
| ASG | `Microsoft.Compute/virtualMachineScaleSets`, Flexible orchestration |
| Security group | NSG with explicit allows + a deny-all outbound at 4000 |
| Target group + listener rule | The fleet's own Standard LB: frontend + pool + probe + rule |
| Route53 PHZ record | `Microsoft.Network/privateDnsZones/A` |
| SSM Parameter Store `/platform/*` | App Configuration `platform/*`, **read by CI, not the template** |
| Instance profile → Secrets Manager | User-assigned identity → Key Vault via RBAC |
| S3 bucket + per-fleet prefix | Storage account + **a container per fleet** |
| AMI from MGN | Compute Gallery image from Azure Migrate |
| `terraform plan` | `az deployment sub what-if` |
| S3 state + `use_lockfile` | No state — ARM is the state |

## What does not survive the translation

Three properties of the Terraform original are genuinely lost. None is a shortcut taken here; each is a constraint of ARM or of Bicep.

### 1. The shared load balancer

The Terraform repo attaches all ten fleets to one shared ALB-equivalent, because `azurerm_lb_probe` and `azurerm_lb_rule` are provider-side read-modify-write PATCHes against the parent LB — Terraform can add a rule to a load balancer owned by a different state. **ARM cannot.** Of the `Microsoft.Network/loadBalancers` child types:

| Child type | Independently deployable |
|---|---|
| `backendAddressPools` | yes |
| `inboundNatRules` | yes |
| `probes` | **no** — `Permitted scopes for deployment: "none"` |
| `loadBalancingRules` | **no** |
| `frontendIPConfigurations` | **no** |

A shared LB in Bicep would force every fleet's probe and rule into whichever template owns the LB, splitting one fleet's declaration across two repos. So **each fleet gets its own internal Standard LB**, which keeps the whole path in one declaration — the actual point of the repo. It also deletes the frontend-IP-slot contract and both of its cross-entry guards, since nothing is shared to collide over. The cost is one Standard LB per fleet.

Note this is an Azure **resource-model** constraint, not a Terraform-versus-Bicep one. Application Gateway is worse still: its backend pools and routing rules are *properties* of the parent resource, not child types at all, which is why the Terraform version also had to drop to layer 4.

Consequence carried over from that layer-4 choice: **TLS terminates on the VM**, on the guest's own nginx. The AWS rehost stripped the guest's certificates because the ALB terminated. Here you keep them.

### 2. The self-contained params file

Bicep has **no data sources** — there is no counterpart to `data "azurerm_app_configuration_key"`. The platform contract cannot be read from inside the template, so it arrives as parameters, and `.bicepparam` pulls them from the environment with `readEnvironmentVariable()`. CI resolves them from App Configuration first (see `.github/workflows/bicep.yml`).

A deployment is therefore only as correct as the pipeline that populated its environment. In the Terraform repo the contract was resolved by the configuration itself.

The same limitation applies to bootstrap scripts: `loadFileAsBase64()` takes a **compile-time literal** path, so the script cannot be selected from a loop variable the way `file("${var.user_data_dir}/${each.value.user_data_file}")` can. Each script is registered in `main.bicep`'s `userDataByFleet` map, and `preflight.sh` check 2 fails the build if a fleet declares `userDataFile` without a matching entry. Adding a fleet with a bootstrap therefore touches `main.bicep`, not only the params file.

### 3. Drift detection

There is no state, so there is nothing to diff. `what-if` re-reads live resources every run and is noisier and less exact than a Terraform plan; ARM's deployment history is all that remains of the audit trail. The nightly job still runs, but treat its output as advisory.

## What gets better

- **A missing bootstrap script fails at compile time.** `loadFileAsBase64()` reports `BCP091 ... Could not find file '.../userdata/x.sh'`. The Terraform repo needed a hand-written `terraform_data` precondition to report the same thing at plan time.
- **No escaping hazard at all.** `loadFileAsBase64()` cannot interpolate, so raw shell reaches the guest untouched. Terraform needed `templatefile()` to be opt-in specifically to avoid `${` being eaten.
- **Stronger typing.** A union like `healthProtocol: ('Http' | 'Https' | 'Tcp')?` is enforced by the compiler, and `@minValue(1)` on `instanceCount` with it; Terraform needs a `validation` block and only finds out at plan time.
- **Cleaner artifact isolation.** A container is a real RBAC scope, so a fleet reads its own container and nothing else — no S3 prefix policy or ABAC condition to get wrong.
- **No state to operate.** No storage account for state, no lease, no `terraform import`, no corrupted state.

## Guards

`assert` is Bicep's only precondition primitive and it is **experimental** — enabling it stamps the compiled template with `languageVersion: "2.1-experimental"`, putting every deployment on a language version Azure may change. For a bridge whose job is to vacate a datacenter inside a window that is a bad trade, so the guards live in `scripts/preflight.sh` and the template stays on `languageVersion: "2.0"`.

| Check | Where | Verified against |
|---|---|---|
| Fleet names unique | `preflight.sh` | two fleets named `dup` |
| Declared bootstrap is registered | `preflight.sh` | a fleet with `userDataFile` and no map entry |
| Bootstrap ≤ 64 KB (Azure's limit) | `preflight.sh` | a 70,000-byte script |
| Bootstrap file exists | Bicep compiler | a non-existent path → `BCP091` |

## Schema differences from the Terraform version

- `fleets` is an **array**, not a map — Bicep loops over arrays, so the map key moved into the object as `name`.
- `aliases` is gone. It existed to widen a Host-header match without creating a record; with no L7 matching, a name either gets an A record (`extraHostnames`) or it does not exist.
- `lbScope` and `frontendIpConfig` are gone. Per-fleet load balancers leave no slot to claim, and every real fleet in the AWS repo is `internal`; add a public-frontend path when something actually needs one.
- `priority` is gone for the same reason.

## Verified

Every file compiles with `bicep build` at **zero diagnostics** (Bicep CLI 0.47.16), both params files resolve with `bicep build-params`, and all four guards were exercised against deliberately broken input. Nothing here has been deployed — `what-if` against a real subscription is the next step, and it needs the `platform/*` App Configuration keys to exist first.
