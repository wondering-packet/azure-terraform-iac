# Week 1 Study Notes — Azure Networking + Terraform IaC
**12-Week Terraform + Azure Networking Program**  

> **Learner profile:** Network engineer with AWS VPC depth. These notes assume you know routing, BGP, ACLs, firewalls, and AWS networking cold. Azure-specific deltas are highlighted throughout.

---

## Table of Contents
- [T1 — Azure Networking Model](#t1--azure-networking-model)
- [T2 — NSGs: Rules, Priority, Stateful Behavior](#t2--nsgs-rules-priority-stateful-behavior)
- [T3 — Azure DNS: Private vs Public Zones](#t3--azure-dns-private-vs-public-zones)
- [T4 — Terraform: Providers, Resources, Lifecycle](#t4--terraform-providers-resources-lifecycle)
- [T5 — Terraform State](#t5--terraform-state)
- [T6 — HCL Syntax: Blocks, Arguments, Meta-arguments, References](#t6--hcl-syntax-blocks-arguments-meta-arguments-references)
- [Quick Reference — Cheat Sheet](#quick-reference--cheat-sheet)

---

## T1 — Azure Networking Model

### VNet vs VPC — concept map

| Concept | AWS | Azure |
|---|---|---|
| Isolated network | VPC | VNet |
| Scoped to | Region | Region |
| IP range | CIDR block | Address space (multiple CIDRs allowed) |
| Availability Zone | Subnet scoped to 1 AZ | Subnet spans ALL AZs in region |
| Route table | Route table per subnet | UDR (User Defined Route) per subnet |
| Security – stateful | Security Group | NSG (Network Security Group) |
| Security – stateless | NACL | No equivalent — NSG handles both |
| Internet gateway | IGW (explicit attach) | Default outbound + NAT Gateway |
| Flow logs | VPC Flow Logs | NSG Flow Logs |
| Cross-account connect | VPC Peering | VNet Peering |

> ⚠️ **Biggest gotcha:** Azure subnets span all AZs in the region. In AWS you create `subnet-public-1a`, `subnet-public-1b` for HA. In Azure you create `subnet-public` once. AZ placement is a property of the **resource** (VM, LB), not the subnet.

### Azure-specific constructs (no AWS equivalent)

**Resource Group** — logical container for lifecycle management. Delete the resource group, you delete everything in it. Primary unit of deployment and RBAC scope. Everything in Azure lives in one.

**Subscription** — sits above resource groups. Own billing, quotas, RBAC scope. VNets live in subscriptions. Multiple subscriptions connect via VNet peering (like cross-account VPC peering).

**Azure Network Watcher** — equivalent of VPC Reachability Analyzer + Flow Logs + Traffic Mirroring, bundled into one place.

---

## T2 — NSGs: Rules, Priority, Stateful Behavior

### What is an NSG

An NSG (Network Security Group) is a stateful packet filter. It does the job of both AWS Security Groups (stateful) and NACLs (stateless) in a single resource. Azure dropped the stateless layer — NSGs handle everything.

### Where NSGs attach

| Attachment point | Scope | AWS equivalent |
|---|---|---|
| Subnet | All resources in the subnet | NACL (but stateful) |
| NIC (Network Interface Card) | Single VM only | Security Group |

> ⚠️ **Both levels are evaluated independently — not a hierarchy.** Inbound traffic hits subnet NSG first, then NIC NSG. Both must allow the traffic. If either denies, packet is dropped. There is no override or precedence.

```
Internet → [Subnet NSG] → [NIC NSG] → VM
```

### Rule structure

| Field | Description | Example |
|---|---|---|
| Priority | 100–4096. Lower = evaluated first. | 100 |
| Name | Descriptive label | allow-https |
| Protocol | TCP, UDP, ICMP, * | Tcp |
| Source | IP, CIDR, Service Tag, ASG | Internet |
| Destination | IP, CIDR, Service Tag, ASG | * |
| Port range | Single, range, or * | 443 |
| Direction | Inbound or Outbound | Inbound |
| Access | Allow or Deny | Allow |

### Default rules (always present, cannot delete)

| Priority | Name | Direction | Action | Notes |
|---|---|---|---|---|
| 65000 | AllowVnetInBound | Inbound | Allow | All VNet-to-VNet traffic |
| 65001 | AllowAzureLoadBalancerInBound | Inbound | Allow | Azure LB health probes |
| 65500 | DenyAllInBound | Inbound | Deny | Catch-all deny |
| 65000 | AllowVnetOutBound | Outbound | Allow | All VNet egress |
| 65001 | AllowInternetOutBound | Outbound | Allow | Internet egress |
| 65500 | DenyAllOutBound | Outbound | Deny | Catch-all deny |

> You override defaults by adding rules with lower priority numbers (e.g. priority 100 beats 65500). To block all internet egress, add an Outbound Deny rule at priority below 65001.

### NSG vs AWS comparison

| | AWS Security Group | AWS NACL | Azure NSG |
|---|---|---|---|
| Stateful | Yes | No | Yes |
| Attachment | Instance / ENI | Subnet | Subnet or NIC |
| Rule evaluation | All rules evaluated | Ordered by rule number | Ordered by priority |
| Default inbound | Deny all | Allow all | Deny all (via 65500) |
| Stateless layer | No | Yes | No equivalent |

> **Minor tradeoff worth knowing:** The lack of a stateless layer means you can't block traffic before connection tracking. AWS NACLs sit at a lower layer — useful for DDoS mitigation and asymmetric routing scenarios at scale. Azure compensates with Azure DDoS Protection and Azure Firewall.

---

## T3 — Azure DNS: Private vs Public Zones

### Two DNS planes

| Type | Resolvable from | AWS equivalent | Use case |
|---|---|---|---|
| Public DNS zone | Internet | Route 53 public hosted zone | Public-facing domains |
| Private DNS zone | Linked VNets only | Route 53 private hosted zone | Internal name resolution |

### Azure's magic resolver IP

Azure hardwires `168.63.129.16` into every VNet's SDN fabric. This IP answers DNS queries for all private zones linked to the VNet, and for Azure-internal names (e.g. `.internal.cloudapp.net`). It's always reachable from inside a VNet — you never configure it explicitly.

VMs get it automatically via DHCP — `/etc/resolv.conf` on Linux will show:
```
nameserver 168.63.129.16
search internal.cloudapp.net
```

> Unlike AWS where you configure a DHCP option set to point at Route 53 Resolver, Azure just pushes `168.63.129.16` to every VM automatically. No DHCP option set equivalent needed.

### Private DNS zone — key behaviors

- Private zones are **global resources** — not scoped to a region or VNet
- You **link** a zone to a VNet to make it resolvable from that VNet
- One zone can link to multiple VNets across regions
- **Auto-registration:** when enabled, VMs get an A record automatically on boot
- **Split-horizon:** same name can exist in both public and private zones — private zone wins for VNet-linked resources

### Enterprise DNS architecture

Cloud-only environments use `168.63.129.16` directly. Enterprises with on-prem DNS or AD deploy custom DNS forwarder VMs (BIND or Windows DNS) with conditional forwarding:

| Query pattern | Forwarded to | Resolves |
|---|---|---|
| `*.intra.corp.com` | `168.63.129.16` | Azure private zone |
| `*.privatelink.blob.core.windows.net` | `168.63.129.16` | Private endpoints |
| `*.corp.onprem.com` | `192.168.1.10` (on-prem DNS) | AD / on-prem records |
| everything else | `8.8.8.8` | Public internet |

All VMs in the VNet point to the forwarder VM IPs (e.g. `10.10.0.4`, `10.10.0.5`) — set at VNet level, pushed via DHCP.

**Azure DNS Private Resolver** is the managed replacement for forwarder VMs — same logic, no VMs to patch. Preferred for greenfield deployments.

> ⚠️ **Critical dependency:** Private Endpoints (Week 2) depend entirely on private DNS zones. When you create a Private Endpoint for Azure Storage, you need a private zone for `privatelink.blob.core.windows.net` linked to your VNet so the storage FQDN resolves to the private IP instead of the public one. Misconfiguring this is the most common Azure networking mistake.

---

## T4 — Terraform: Providers, Resources, Lifecycle

### What is HCL

HCL (HashiCorp Configuration Language) is the declarative language you write Terraform in. You describe *what* you want to exist, not *how* to create it. Similar intent to AWS CloudFormation YAML but more readable and supports native cross-resource references.

### Providers

A provider is a plugin that translates your HCL into API calls for a specific platform. For Azure: `hashicorp/azurerm`. Downloaded by `terraform init` from the Terraform registry into `.terraform/`.

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

provider "azurerm" {
  features {}
}
```

> `features {}` is required by azurerm even if empty. `~> 3.100` means any 3.x version >= 3.100 — patch updates allowed, major version locked.

### The lifecycle

| Command | What it does | Writes to state? |
|---|---|---|
| `terraform init` | Downloads providers, sets up backend. Run once per project. | No |
| `terraform plan` | Diffs HCL vs state vs Azure. Shows what WOULD happen. Dry run. | No |
| `terraform apply` | Executes the plan. Prompts for confirmation. | Yes |
| `terraform destroy` | Deletes all resources Terraform manages. Shows plan first. | Yes (empties it) |

```
Write HCL → init → plan → apply → (change HCL) → plan → apply → destroy
                              ↑                        ↑
                         state written            state updated
```

### Plan output symbols

| Symbol | Meaning | Risk level |
|---|---|---|
| `+ create` | New resource will be created | Low — expected on first apply |
| `~ update in-place` | Attribute change, resource stays | Low — review details |
| `- destroy` | Resource will be deleted | High — verify intentional |
| `-/+ destroy+recreate` | Immutable attribute changed | Critical — check all dependencies |

> ⚠️ **`-/+` on a foundational network resource (VNet, subnet) = treat like a BGP session drop on a core router.** Everything inside it may be affected. VNet destroy cascade: all subnets → all NICs disconnected → VMs lose network → NSG associations gone → peering gone.

### Authentication for labs

- **Local dev:** `az login` then `terraform plan/apply` — azurerm picks up CLI credentials automatically
- **CI/CD:** Service Principal
- **Azure-hosted runners:** Managed Identity

---

## T5 — Terraform State

### What state is

A JSON file (`terraform.tfstate`) that maps your HCL resource definitions to real Azure resource IDs. It's Terraform's memory — the source of truth for what Terraform thinks it owns.

### How plan uses state

```
HCL (desired state)
      ↓  diff
State file (last known state)  →  scopes which Azure resources to query
      ↓  reconcile with live Azure config
Plan output (delta)
```

Terraform **does** query Azure on every plan/apply — but only for resources it knows about via state. State scopes the query; it doesn't replace it.

### State file anatomy

```json
{
  "version": 4,
  "terraform_version": "1.7.0",
  "resources": [
    {
      "mode": "managed",
      "type": "azurerm_resource_group",   
      "name": "main",                     
      "instances": [{
        "attributes": {
          "id": "/subscriptions/abc/resourceGroups/rg-prod",
          "location": "eastus",
          "name": "rg-prod"
        }
      }]
    }
  ]
}
```

The binding: `type` + `name` in state matches `resource "azurerm_resource_group" "main"` in HCL. The ARM `id` is what Terraform uses to query Azure for live config.

### What happens if state is lost

Terraform has no memory. Running `terraform apply` tries to create everything again — Azure errors with "resource already exists" or creates duplicates. Your infrastructure is *orphaned* — still running, still billing, unmanaged by Terraform.

**Recovery:** `terraform import` — pulls existing Azure resources into state.
```bash
# Workflow:
# 1. Write HCL describing the existing resource
# 2. Import it
terraform import azurerm_resource_group.main /subscriptions/abc/resourceGroups/rg-prod
# 3. Plan should show zero changes if HCL matches reality
terraform plan
```

### Drift detection

If someone edits a resource in the portal after Terraform created it, `terraform plan` will show the delta:
```
~ resource "azurerm_virtual_network" "main" {
    ~ address_space = ["10.1.0.0/16"] -> ["10.0.0.0/16"]
  }
```
Terraform has no "rollback" — you fix-forward by updating HCL and re-applying, or by running plan to force Azure back to desired state.

### Remote state — production requirement

Local state is fine for solo learning. Teams use remote state in Azure Storage:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "tfstatecompany"
    container_name       = "tfstate"
    key                  = "prod/networking.tfstate"
  }
}
```

Enables state locking via blob lease — prevents concurrent apply conflicts.

### .gitignore — non-negotiable

```
.terraform/
terraform.tfstate
terraform.tfstate.backup
*.tfvars
*.tfvars.json
crash.log
```

> ⚠️ State files contain resource IDs, IPs, and sometimes plaintext secrets. Never commit to Git. `.terraform.lock.hcl` is the one exception — it **does** go in Git (locks provider versions for the team).

---

## T6 — HCL Syntax: Blocks, Arguments, Meta-arguments, References

### Block types

| Block type | Labels | Purpose |
|---|---|---|
| `terraform` | none | Settings, required_providers, backend config |
| `provider` | provider name | Provider-specific configuration |
| `resource` | resource type + local name | A managed infrastructure object |
| `variable` | variable name | Input parameter |
| `output` | output name | Expose value after apply |
| `locals` | none | Local computed values (define here) |
| `data` | data source type + local name | Read existing infra — never modified by Terraform |

### Resource block anatomy

```hcl
resource "<provider_type>" "<local_name>" {
  argument = "value"          # string
  argument = ["a", "b"]      # list
  argument = { key = "val" } # map
  argument = var.myvar        # reference to variable

  nested_block {
    argument = value
  }
}
```

> Resource type names like `azurerm_virtual_network` are **fixed** — defined by the provider. The local name is yours. Find all valid resource types at: `registry.terraform.io/providers/hashicorp/azurerm/latest/docs`

### References between resources

Reference syntax: `<resource_type>.<local_name>.<attribute>`

```hcl
resource "azurerm_resource_group" "main" {
  name     = "rg-prod"
  location = "eastus"
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-prod"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location  # reference
  resource_group_name = azurerm_resource_group.main.name      # reference
}
```

> References create **implicit dependencies** — Terraform creates the resource group before the VNet automatically. No explicit `depends_on` needed when references exist. Always prefer references over hardcoded values or `var.x` on both resources.

### Variables, locals, outputs

| Construct | Define with | Reference with | Use case |
|---|---|---|---|
| Variable | `variable "x" {}` | `var.x` | External inputs, reusable configs |
| Local | `locals { x = ... }` | `local.x` | Computed values, naming conventions |
| Output | `output "x" {}` | `module.name.x` | Expose values after apply |

```hcl
# variables.tf
variable "location" {
  type    = string
  default = "eastus"
}

# locals.tf
locals {
  env          = "prod"
  region_short = "eus"
  prefix       = "${local.env}-${local.region_short}"  # "prod-eus"
  vnet_name    = "${local.prefix}-vnet"                # "prod-eus-vnet"
}

# outputs.tf
output "vnet_id" {
  value = azurerm_virtual_network.main.id
}
```

> `locals` (plural) = block type where you define them. `local` (singular) = reference keyword. Same pattern as `variable` / `var`.

### Data sources vs resources

| | `resource` block | `data` block |
|---|---|---|
| Terraform manages it? | Yes — creates, updates, destroys | No — read only |
| In state file? | Yes | Yes (cached read) |
| Reference syntax | `azurerm_X.name.attr` | `data.azurerm_X.name.attr` |

```hcl
# Read an existing resource group you didn't create with Terraform
data "azurerm_resource_group" "existing" {
  name = "rg-shared-services"
}

resource "azurerm_virtual_network" "main" {
  resource_group_name = data.azurerm_resource_group.existing.name
  location            = data.azurerm_resource_group.existing.location
  ...
}
```

### Meta-arguments

These work on **any** resource block regardless of provider:

```hcl
# depends_on — explicit dependency when TF can't infer from references
resource "azurerm_subnet" "main" {
  depends_on = [azurerm_virtual_network.main]
  ...
}

# count — create N copies
resource "azurerm_subnet" "main" {
  count            = 3
  name             = "subnet-${count.index}"
  address_prefixes = [var.subnet_cidrs[count.index]]
  ...
}

# for_each — create one resource per map item (preferred over count)
variable "subnets" {
  default = {
    web = "10.0.1.0/24"
    app = "10.0.2.0/24"
    db  = "10.0.3.0/24"
  }
}

resource "azurerm_subnet" "main" {
  for_each         = var.subnets
  name             = each.key    # "web", "app", "db"
  address_prefixes = [each.value]
  ...
}

# lifecycle — control create/update/destroy behavior
resource "azurerm_virtual_network" "main" {
  ...
  lifecycle {
    prevent_destroy = true   # terraform destroy errors on this resource
    ignore_changes  = [tags] # ignore tag drift in plan
  }
}
```

> ⚠️ **Use `prevent_destroy` on all production VNets, subnets, and databases.** Note: only prevents Terraform from destroying — does not stop portal/CLI deletion. For full protection, also add an **Azure Resource Lock** (`CanNotDelete`) at the Azure level.

---

## Quick Reference — Cheat Sheet

### Key Azure resource types (azurerm provider)

| Azure resource | Terraform resource type |
|---|---|
| Resource Group | `azurerm_resource_group` |
| Virtual Network | `azurerm_virtual_network` |
| Subnet | `azurerm_subnet` |
| Network Security Group | `azurerm_network_security_group` |
| NSG association (subnet) | `azurerm_subnet_network_security_group_association` |
| NSG association (NIC) | `azurerm_network_interface_security_group_association` |
| Public IP | `azurerm_public_ip` |
| NAT Gateway | `azurerm_nat_gateway` |
| Private DNS Zone | `azurerm_private_dns_zone` |
| Private DNS VNet Link | `azurerm_private_dns_zone_virtual_network_link` |

### Terraform commands

| Command | When to use |
|---|---|
| `terraform init` | First time, or after adding/changing providers |
| `terraform fmt` | Format all .tf files to HCL standard style |
| `terraform validate` | Check HCL syntax without connecting to Azure |
| `terraform plan` | Preview changes — always run before apply |
| `terraform apply` | Deploy changes |
| `terraform apply -target=<resource>` | Apply only one specific resource |
| `terraform destroy` | Tear down all managed resources |
| `terraform import <addr> <azure_id>` | Bring existing Azure resource under TF management |
| `terraform state list` | List all resources in state |
| `terraform state show <resource>` | Show state details for one resource |

### Project file structure

```
azure-terraform-labs/        ← Git repo root
├── .gitignore               ← covers entire repo
├── week1/
│   ├── main.tf              ← resources
│   ├── variables.tf         ← input variables
│   ├── outputs.tf           ← output values
│   └── locals.tf            ← local computed values
├── week2/
└── week3/
```

### Reference docs

- Terraform azurerm provider: `registry.terraform.io/providers/hashicorp/azurerm/latest/docs`
- Azure CLI reference: `learn.microsoft.com/en-us/cli/azure`
- Azure networking overview: `learn.microsoft.com/en-us/azure/virtual-network`

---

### Week 1 milestone
> By April 17: Deploy a working VNet + subnet + NSG stack entirely via Terraform with zero portal clicks.

---
*Generated from live teaching sessions*