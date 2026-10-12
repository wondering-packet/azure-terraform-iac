# Day 3 — Extend the Base Network (adopt & grow the hub)

> **How to use this guide.** Each topic's **theory** gives you the building blocks — mechanics, skeletons, the one or two lines that matter — but *not* the finished answer. Each **exercise** then states a full problem: objective, inputs, constraints. Attempt it from the theory first; predict the `plan` output; only then open the collapsed solution and apply. The base network is already live under `networking/hub-spoke`, so this is an *adopt-and-extend* day — the predict-before-you-apply habit is the safety rail.

## File & marker conventions

- **`d0N…` files are day-scoped** — the digits say which day built them. `d03ex04-vnets.tf` = Day 3, Exercise 4.
- **Shared files are not day-scoped** — `locals.tf`, `variables.tf`, `outputs.tf`, `backend.tf`, `main.tf` live across all days. Day 3 edits inside them are wrapped in markers:

```hcl
###---d03ex02 >>>
# ...day 3, exercise 2 code...
###---d03ex02 <<<
```

## Prerequisites & continuity

Assumes Days 0–2: the Terraform workflow, HCL type system, `for_each`, data sources, `lifecycle`, the remote `azurerm` backend, locking, and workspaces.

The base is live in the `default` workspace under key `networking/hub-spoke`: hub VNet (`prevent_destroy = true`), `web/app/db/mgmt` subnets, `web/app` NSGs, spoke1 VNet. **Auth is now Azure AD** — the Day-2 shared-key fallback is retired: the `Storage Blob Data Contributor` role was granted, `backend.tf` sets `use_azuread_auth`/`use_cli`, shared-key access is disabled, and the backend was re-initialised with `terraform init -reconfigure`.

## Table of contents

1. [Adopting live state safely](#topic-1--adopting-live-state-safely)
2. [Extending a `for_each` subnet set](#topic-2--extending-a-for_each-subnet-set)
3. [Subnet constraints & delegation (and `dynamic` blocks)](#topic-3--subnet-constraints--delegation-and-dynamic-blocks)
4. [Completing the spoke topology](#topic-4--completing-the-spoke-topology)
5. [Base outputs for cross-stack consumption](#topic-5--base-outputs-for-cross-stack-consumption)
6. [Cleaning up throwaway resources](#topic-6--cleaning-up-throwaway-resources)
7. [Design challenge — `cidrsubnet()` vs explicit CIDRs](#design-challenge--cidrsubnet-vs-explicit-cidrs)
8. [Corrections & gotchas](#corrections--gotchas)

---

## Topic 1 — Adopting live state safely

### Theory

Copying the Day 2 folder forward carries the configuration, not the state. What binds this new folder to the existing live state is one unchanged line in the backend:

```hcl
# backend.tf
key = "networking/hub-spoke"   # unchanged from Day 2 -> init attaches to the SAME live state blob
```

So `terraform init` here is an *attach*, not a fresh start. The only thing to establish before mutating anything is that the attach is correct — proven by a `terraform plan` that reports `No changes` (nothing to add, nothing to destroy). If it reports otherwise, don't fix forward — investigate. The usual cause is the wrong workspace (a `dev`/`prod` workspace has its own empty state) or the wrong key.

The auth method changed this day (shared key → Azure AD), and changing *how* the backend authenticates requires re-initialising with `-reconfigure`.

> **`prevent_destroy` is a plan-level tripwire.** The hub VNet has `prevent_destroy = true`. It doesn't stop a plan from *wanting* to replace the hub — it makes Terraform **error the entire plan** the moment a destroy/replace of that resource is proposed, taking every batched change down with it. On a healthy adopt-and-extend plan the hub never appears at all.

### Exercise 1 — attach & verify

**Objective:** stand the Day 3 folder up against the existing live backend and prove you're safely attached before touching anything.

**Steps to work out:** copy the folder forward; initialise the backend given the auth method changed; confirm which workspace you're in and why it matters; run a plan and decide what result means "safely attached."

**Predict before you run:** what exact final line should `terraform plan` print if the attach is correct? What must `terraform workspace show` say?

**Solution** — try the exercise above before reading on.

```powershell
Copy-Item -Recurse day02-remote_state-backend-workspaces day03-extend-base
cd day03-extend-base
terraform init -reconfigure     # -reconfigure: backend auth changed (shared key -> AAD)
terraform workspace show        # must print: default
terraform plan
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
```

That one line proves you're reading the real state (not empty), AAD auth worked (the blob was readable), and the carried-forward code matches live Azure. If instead you see `N to add`, you're almost certainly in the wrong workspace or pointed at the wrong key — check before doing anything else.


### Q&A

**Q1 — A plan shows `Plan: 10 to add`. First hypothesis?**
Not "someone deleted my resources." `+ create` = "in config, absent from *effective* state" — usually the wrong workspace (fresh workspace = empty state) or wrong key. Check `terraform workspace show` and the backend key first.

**Q2 — With `prevent_destroy` on the hub, what could still force a hub replacement, and how do you check?**
A change to a **ForceNew** attribute of `azurerm_virtual_network` — `name`, `location`, or `resource_group_name` (`address_space` is *not* ForceNew, so growing it updates in place). The hub `name` is computed from the naming chain, so editing `var.owner`, `var.location`, or the `-hub` suffix recomputes it → `-/+` → `prevent_destroy` errors the plan rather than executing.
What does *not* force a replace: a **workspace** switch (separate, empty state → it plans a *create* of a differently-named hub, never touching the live one), and an out-of-band **portal delete** (refresh finds it gone → plans a *create*). Check by reading the plan — the hub must never appear as `-/+`.

---

## Topic 2 — Extending a `for_each` subnet set

### Theory

With `for_each`, each instance is tracked in state by its **map key** — `azurerm_subnet.hub["mgmt"]`. Add a key and you get one new state address; every existing key is untouched. That key-stability is what makes growing a live hub safe. (`count` tracks by *index*: inserting shifts every later index and forces destroy/recreate — never use it for a growing set.) And because subnets are **separate resources**, adding them never re-plans the hub VNet.

The reserved subnets — `GatewaySubnet`, `AzureFirewallSubnet` — differ from ordinary subnets in three ways: bare name (no prefix), never an NSG, never a delegation. You *could* encode all three as conditionals in one block; it's cleaner to split into two resources so each difference is **structural** rather than conditional. Skeleton:

```hcl
resource "azurerm_subnet" "hub" {            # regular: computed name, may take NSG/delegation
  for_each = var.subnets_hub
  name     = "${local.snet_name}-${each.key}"   # <- prefixed
  # ...
}

resource "azurerm_subnet" "hub_reserved" {   # reserved: bare name, no NSG/delegation path at all
  for_each = var.subnets_hub_reserved
  name     = each.key                            # <- verbatim, e.g. "GatewaySubnet"
  # ...
}
```

Names resolve off the naming chain in `locals.tf` — these are your building blocks:

```hcl
prefix    = "${var.owner}-${local.environment}-${local.region_code}"  # "vg-lab-wus"
snet_name = "snet-${local.prefix}"                                    # "snet-vg-lab-wus"
nsg_name  = "nsg-${local.prefix}"                                     # "nsg-vg-lab-wus"
```

**Reconciling the four Day-1 names.** They were created bare (`web`, `app`, …). To move them to the schema convention you change *only the name expression* (`each.key` → `"${local.snet_name}-${each.key}"`) while the map key stays `web`. Since subnet `name` is ForceNew (Topic 3), that plans as `-/+` on the same keyed instance — and because the key is unchanged, the NSG names (which also key off `each.key`) don't move. Keep the identity (key) fixed; change the attribute (name).

### Exercise 2 — split the variable, extend, and rename

**Objective:** split the single subnet variable into `subnets_hub` (regular) + `subnets_hub_reserved`, add the seven missing hub subnets, and reconcile the four existing subnet names to the `snet-vg-lab-wus-*` convention.

**Inputs** (authoritative schema):

| Subnet | CIDR | Notes |
|---|---|---|
| `GatewaySubnet` | 172.22.0.0/27 | reserved name |
| `AzureFirewallSubnet` | 172.22.1.0/26 | reserved name |
| `mgmt` | 172.22.7.0/24 | |
| `web` | 172.22.10.0/24 | NSG |
| `app` | 172.22.11.0/24 | NSG |
| `db` | 172.22.12.0/24 | service endpoint `Microsoft.Storage` |
| `shared` | 172.22.2.0/24 | |
| `pe` | 172.22.3.0/24 | |
| `agw` | 172.22.6.0/24 | |
| `dns-inbound` | 172.22.4.0/24 | |
| `dns-outbound` | 172.22.5.0/24 | |

**Constraints:** reserved names exact and case-sensitive; reserved variable needs only `cidr`; keep the four existing keys (`web`/`app`/`db`/`mgmt`) unchanged so their NSGs don't churn; `db` carries `service_endpoints = ["Microsoft.Storage"]`.

**Predict:** the four existing subnets change name (ForceNew) and the new ones are created — what's the `Plan:` line, and should the hub VNet appear anywhere in it?

**Solution** — try the exercise above before reading on.

```hcl
# variables.tf
variable "subnets_hub" {
  type = map(object({
    cidr              = string
    has_nsg           = bool
    service_endpoints = optional(list(string), [])
    delegation = optional(map(object({          # populated in Topic 3
      service_name    = string
      service_actions = list(string)
    })), {})
  }))
}
variable "subnets_hub_reserved" {
  type = map(object({ cidr = string }))
}
```

```hcl
# terraform.tfvars (excerpt; dns-* delegations added in Ex 3)
subnets_hub = {
  "web"  = { cidr = "172.22.10.0/24", has_nsg = true }
  "app"  = { cidr = "172.22.11.0/24", has_nsg = true }
  "db"   = { cidr = "172.22.12.0/24", has_nsg = false, service_endpoints = ["Microsoft.Storage"] }
  "mgmt" = { cidr = "172.22.7.0/24",  has_nsg = false }
  "shared" = { cidr = "172.22.2.0/24", has_nsg = false }
  "pe"     = { cidr = "172.22.3.0/24", has_nsg = false }
  "agw"    = { cidr = "172.22.6.0/24", has_nsg = false }
}
subnets_hub_reserved = {
  "GatewaySubnet"       = { cidr = "172.22.0.0/27" }
  "AzureFirewallSubnet" = { cidr = "172.22.1.0/26" }
}
```

```hcl
# d03ex02ex03ex04-subnets.tf
resource "azurerm_subnet" "hub" {
  for_each             = var.subnets_hub
  name                 = "${local.snet_name}-${each.key}"
  address_prefixes     = [each.value.cidr]
  service_endpoints    = each.value.service_endpoints
  virtual_network_name = azurerm_virtual_network.hub.name
  resource_group_name  = data.azurerm_resource_group.main.name
  # dynamic delegation block added in Ex 3
}

resource "azurerm_subnet" "hub_reserved" {
  for_each             = var.subnets_hub_reserved
  name                 = each.key
  address_prefixes     = [each.value.cidr]
  virtual_network_name = azurerm_virtual_network.hub.name
  resource_group_name  = data.azurerm_resource_group.main.name
}

resource "azurerm_network_security_group" "main" {
  for_each            = { for k, v in var.subnets_hub : k => v if v.has_nsg }
  name                = "${local.nsg_name}-${each.key}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.main.name
}
```

Run `terraform plan`. Expected:

```text
Plan: N to add, 0 to change, 4 to destroy
```

The four Day-1 subnets show as `-/+ ... name = "web" -> "snet-vg-lab-wus-web" # forces replacement` at their original addresses `azurerm_subnet.hub["web"]`. The hub VNet must be **absent** — proof the additions didn't touch it. Pre-flight the four for emptiness (Topic 3), then `terraform apply`.


### Q&A

**Q1 — Adding a map key doesn't disturb existing subnets. Why? What would `count` have done?**
`for_each` keys are stable identities; a new key is a new independent address. `count` indexes by position, so inserting shifts later indices and destroys/recreates the shifted resources.

**Q2 — Why would renaming via the *key* break the NSG names, and how does keeping the key stable avoid it?**
Both names derive from the same `each.key`:

```hcl
name = "${local.snet_name}-${each.key}"   # key "web" -> "snet-vg-lab-wus-web"
name = "${local.nsg_name}-${each.key}"    # key "web" -> "nsg-vg-lab-wus-web"
```

Rename by changing the **key** `web` → `snet-vg-lab-wus-web` and both re-evaluate against the new key:

```hcl
# subnet: "snet-vg-lab-wus-" + "snet-vg-lab-wus-web" = snet-vg-lab-wus-snet-vg-lab-wus-web  ✗
# NSG:    "nsg-vg-lab-wus-"  + "snet-vg-lab-wus-web" = nsg-vg-lab-wus-snet-vg-lab-wus-web    ✗
```

…plus the NSG's `for_each` key changed, so it churns too. Change only the *name expression* while the key stays `web`: subnet name becomes `snet-vg-lab-wus-web`, `each.key` is still `web`, so the NSG stays `nsg-vg-lab-wus-web` and never moves. Key = identity; `name` = a computed attribute.

---

## Topic 3 — Subnet constraints & delegation (and `dynamic` blocks)

### Theory

**Reserved names and sizes** (verified against Microsoft docs). `GatewaySubnet` and `AzureFirewallSubnet` are exact, case-sensitive. `GatewaySubnet` wants `/27` (hard min `/29`, Basic only) and **cannot carry an NSG** — associating one can break the gateway. `AzureFirewallSubnet` needs `/26` minimum and is Azure-managed. The Day-0 schema sized these `/27` and `/26` deliberately.

**Subnet `name` is ForceNew.** Changing it destroys the old subnet and creates a new one — safe only when the subnet is empty. A subnet holding any NIC, private endpoint, or delegation refuses to delete (`InUseSubnetCannotBeDeleted`), and a forced replace severs whatever used it. So before renaming on live infra, pre-flight each subnet:

```powershell
az network vnet subnet show `
  --resource-group rg-vg-lab-wus-01 --vnet-name vnet-vg-lab-wus-hub --name web `
  --query "{ipconfigs: ipConfigurations, pe: privateEndpoints, delegations: delegations}" -o json
# all three empty -> safe to replace
```

> **`-/+` is a potential outage, always.** Not the name change — the destroy-then-create. There's a window where the subnet doesn't exist. Empty → harmless; occupied → outage or a failed apply. And a replaced resource keeps its state *address* but gets a brand-new Azure ID: state continuity is not resource continuity.

**Delegation** grants a named Azure service permission to manage resources in a subnet; the DNS Private Resolver (Day 4) requires subnets delegated to `Microsoft.Network/dnsResolvers`. Unlike a rename it's a **mutable, in-place** change (`~`). Model it as *data* on the subnet, not logic keyed off the subnet name — the variable carries it:

```hcl
delegation = optional(map(object({
  service_name    = string
  service_actions = list(string)
})), {})   # default {} -> most subnets carry none
```

> **Always set `service_actions` explicitly.** Omit it, Azure fills the default and returns it on refresh; your empty config then drifts → a perpetual `~` every plan. And once Day 4 binds the resolver, altering the delegation forces the endpoint to rebuild; a missing one throws `SubnetMissingRequiredDelegation`.

**`dynamic` blocks (new).** A subnet needs a `delegation { }` nested block *only* when it declares one — you can't write a bare `delegation { }` or all nine subnets get it. A `dynamic` block **generates zero-or-more copies of a nested block from a collection**: N elements → N blocks; empty collection → none. Generic anatomy:

```hcl
dynamic "LABEL" {          # LABEL = the nested block you're generating
  for_each = SOME_COLLECTION
  content {                # emitted once per element
    # reference the current element as LABEL.key / LABEL.value  (NOT each.*)
  }
}
```

Two things to internalise: the iterator is named after the block (`LABEL.key`/`LABEL.value`), not `each`; and `for_each` over an empty map emits nothing — which is exactly how the seven non-DNS subnets get no delegation block and no diff.

### Exercise 3 — add delegation

**Objective:** delegate `dns-inbound` and `dns-outbound` to `Microsoft.Network/dnsResolvers`, and *only* those two, driven from data.

**Constraints:** delegation is declared per-subnet in tfvars (not matched on subnet name); the resource renders it with a `dynamic` block; specify `service_actions` explicitly.

**Predict:** the two DNS subnets already exist — is this `~` or `-/+`? What's the `Plan:` line, and should the other seven subnets show any diff?

**Solution** — try the exercise above before reading on.

```hcl
# d03ex02ex03ex04-subnets.tf — inside resource "azurerm_subnet" "hub"
dynamic "delegation" {
  for_each = each.value.delegation      # per-subnet map; empty {} for the seven non-DNS subnets
  content {
    name = delegation.key               # iterator named after the block
    service_delegation {
      name    = delegation.value.service_name
      actions = delegation.value.service_actions
    }
  }
}
```

```hcl
# terraform.tfvars — only the two DNS subnets declare a delegation
"dns-inbound" = {
  cidr = "172.22.4.0/24", has_nsg = false
  delegation = {
    "dnsresolver" = {
      service_name    = "Microsoft.Network/dnsResolvers"
      service_actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}
"dns-outbound" = {
  cidr = "172.22.5.0/24", has_nsg = false
  delegation = {
    "dnsresolver" = {
      service_name    = "Microsoft.Network/dnsResolvers"
      service_actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}
```

Run `terraform plan`. Expected — in-place, not a replace:

```text
Plan: 0 to add, 2 to change, 0 to destroy
```

Each DNS subnet shows `~` with a `+ delegation { + service_delegation {...} }`. If any of the other seven show a diff, the empty-map default isn't defaulting — debug before applying. Then `terraform apply`.


### Q&A

**Q1 — Why can't `GatewaySubnet` take an NSG, and what protects you from adding one by accident?**
NSGs are unsupported on the gateway subnet and can break it. The two-block architecture excludes it structurally — the reserved block has no NSG path.

**Q2 — What does delegation do, and what breaks in Day 4 if it's missing?**
It authorises `Microsoft.Network/dnsResolvers` to manage resources in the subnet. Missing → Day 4's resolver endpoint fails with `SubnetMissingRequiredDelegation`; changing it after binding forces an endpoint rebuild.

**Q3 — Adding a delegation is `~`, but the rename was `-/+`. Same resource — why?**
`name` is ForceNew (destroy/recreate); `delegation` is a mutable property updated in place. The symbol depends on *which attribute* changed.

---

## Topic 4 — Completing the spoke topology

### Theory

The base has spoke1's VNet but no spoke subnets, and no spoke2. Each spoke subnet uses the same `snet-vg-lab-wus-` convention but lives in a *different* VNet — and `azurerm_subnet.hub` is hardwired to the hub VNet:

```hcl
virtual_network_name = azurerm_virtual_network.hub.name   # hub block can't cover spokes
```

So a spoke workload subnet is a separate resource pinned to its spoke VNet (skeleton — one per spoke):

```hcl
resource "azurerm_subnet" "spoke1" {
  virtual_network_name = azurerm_virtual_network.spoke1.name   # <- the only real difference
  # name / address_prefixes / resource_group_name as usual
}
```

Ordering falls out of references, not hand-sequencing: a spoke2 subnet whose `virtual_network_name` points at the spoke2 VNet waits for that VNet; a spoke1 subnet whose VNet already exists runs in parallel.

Type the spoke variables to only what the blocks read — a CIDR. Declaring `has_nsg`/`delegation` here would be config that lies about intent.

> **Recognised duplication, deferred on purpose.** The three subnet blocks (`hub`, `spoke1`, `spoke2`) differ only by VNet reference. For one workload subnet per spoke, three explicit blocks are readable and honest. The clean factoring — subnet→VNet association as data, one block — belongs to Day 8's module work, where the VNet reference becomes a module input.

### Exercise 4 — complete the spokes

**Objective:** relocate the spoke1 VNet block into a dedicated file, add the spoke2 VNet, and add one workload subnet per spoke.

**Inputs:** spoke2 VNet `172.22.32.0/20`; `spoke1-workload` `172.22.16.0/24`; `spoke2-workload` `172.22.32.0/24`.

**Constraints:** when relocating the spoke1 block, keep its resource address and address space identical (so it's a no-op move); slim `subnets_spoke1`/`subnets_spoke2` to `{ cidr = string }`.

**Predict:** what's the `Plan:` line, and — critically — should `azurerm_virtual_network.spoke1` appear in it? What does its absence prove?

**Solution** — try the exercise above before reading on.

```hcl
# d03ex04-vnets.tf  (spoke1 block moved here from the Day 2 file; spoke2 is new)
resource "azurerm_virtual_network" "spoke1" {
  name                = "${local.vnet_name}-spoke1"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  address_space       = var.vnet_address_space["spoke1"].address_space
  lifecycle { prevent_destroy = true, ignore_changes = [tags] }
  depends_on = [data.azurerm_resource_group.main]
}

resource "azurerm_virtual_network" "spoke2" {
  name                = "${local.vnet_name}-spoke2"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  address_space       = var.vnet_address_space["spoke2"].address_space
  lifecycle { prevent_destroy = true, ignore_changes = [tags] }
  depends_on = [data.azurerm_resource_group.main]
}
```

```hcl
# d03ex02ex03ex04-subnets.tf
resource "azurerm_subnet" "spoke1" {
  name                 = "${local.snet_name}-spoke1-workload"
  address_prefixes     = [var.subnets_spoke1["workload"].cidr]
  virtual_network_name = azurerm_virtual_network.spoke1.name
  resource_group_name  = data.azurerm_resource_group.main.name
}
resource "azurerm_subnet" "spoke2" {
  name                 = "${local.snet_name}-spoke2-workload"
  address_prefixes     = [var.subnets_spoke2["workload"].cidr]
  virtual_network_name = azurerm_virtual_network.spoke2.name   # spoke2, not spoke1
  resource_group_name  = data.azurerm_resource_group.main.name
}
```

```hcl
# variables.tf
variable "subnets_spoke1" { type = map(object({ cidr = string })) }
variable "subnets_spoke2" { type = map(object({ cidr = string })) }
```

Run `terraform plan`. Expected:

```text
Plan: 3 to add, 0 to change, 0 to destroy
```

The three adds are spoke2's VNet + the two workload subnets. **`azurerm_virtual_network.spoke1` is absent** — its absence proves the relocation was clean (address and attributes unchanged). During apply, spoke2's subnet waits for spoke2's VNet; spoke1's subnet runs in parallel. Then `terraform apply`.


### Q&A

**Q1 — You moved the spoke1 block to a new file. How do you know it wasn't disturbed?**
The plan — source alone can't tell you, only the diff against live state. Unchanged address + attributes → spoke1 is absent from the plan.

**Q2 — Why leave the three near-identical subnet blocks instead of factoring them now?**
One workload subnet per spoke makes explicit blocks the readable choice; the data-driven single block only pays off at the module layer (Day 8), where the VNet is an input.

---

## Topic 5 — Base outputs for cross-stack consumption

### Theory

Days 6/7/9 run as *separate* configs with their own state and read this base via `terraform_remote_state`. That only works if the base publishes IDs as outputs.

The design axis is **failure timing**, not "how special the subnet is." A **named scalar** output is a contract validated when *you* apply the base — a downstream reference resolves at that stack's plan time or fails legibly. A **map index** (`subnet_ids["GatewaySubnet"]`) defers the check to the consumer's apply, for that one key — failure surfaces two stacks away at the worst moment. The question per subnet: does a later stack **bind to it by identity** (→ named scalar) or **enumerate a group** (→ map)? Building blocks:

```hcl
# named scalar (contract): consumer writes  .outputs.gateway_subnet_id
output "gateway_subnet_id" { value = azurerm_subnet.hub_reserved["GatewaySubnet"].id }

# map (bulk): consumer writes  .outputs.hub_subnet_ids["web"]
output "hub_subnet_ids" { value = { for k, v in azurerm_subnet.hub : k => v.id } }
```

Note the reserved subnets live in `azurerm_subnet.hub_reserved`, a *different* resource, so the `hub_subnet_ids` map (iterating `azurerm_subnet.hub`) can't include them — named scalars are the only way to surface Gateway/Firewall IDs.

> **Two rules for output shape.** (1) The name is the consumer's API: snake_case, no hyphens, no mirroring Azure names — a hyphenated output can't be reached with dot access. (2) An ID isn't a secret; never leave `sensitive = true` on one, or every consumer must treat it as sensitive too.

> **Why outputs, not a consumer-side `data` source?** A `data` lookup couples the consumer to the base's internal names — a base refactor breaks every consumer. An output is a stable contract the base owns. Outputs decouple; data sources re-couple.

### Exercise 5 — build base outputs

**Objective:** publish the base's IDs for `terraform_remote_state` consumers.

**Decide, then build:**
- Which subnets are **named scalars** (a specific later stack binds by identity) vs **map**? Route each: Gateway (Day 6), Firewall (Day 7), pe (Day 5), agw (Day 9), dns-inbound/outbound (Day 4) → scalars; web/app/db/mgmt/shared → the `hub_subnet_ids` map.
- Expose `hub_vnet_id`, `spoke1_vnet_id`, `spoke2_vnet_id`, and both spoke workload subnet IDs as scalars.
- Drop any leftover `sensitive` flag; use snake_case names.

**Predict:** this is outputs-only — what's the `Plan:` line? What appears in the `Changes to Outputs` block?

**Solution** — try the exercise above before reading on.

```hcl
# outputs.tf
output "gateway_subnet_id"      { value = azurerm_subnet.hub_reserved["GatewaySubnet"].id }
output "firewall_subnet_id"     { value = azurerm_subnet.hub_reserved["AzureFirewallSubnet"].id }
output "pe_subnet_id"           { value = azurerm_subnet.hub["pe"].id }
output "agw_subnet_id"          { value = azurerm_subnet.hub["agw"].id }
output "dns_inbound_subnet_id"  { value = azurerm_subnet.hub["dns-inbound"].id }
output "dns_outbound_subnet_id" { value = azurerm_subnet.hub["dns-outbound"].id }

output "hub_subnet_ids" { value = { for k, v in azurerm_subnet.hub : k => v.id } }

output "hub_vnet_id"    { value = azurerm_virtual_network.hub.id }
output "spoke1_vnet_id" { value = azurerm_virtual_network.spoke1.id }
output "spoke2_vnet_id" { value = azurerm_virtual_network.spoke2.id }
output "spoke1_workload_subnet_id" { value = azurerm_subnet.spoke1.id }
output "spoke2_workload_subnet_id" { value = azurerm_subnet.spoke2.id }
```

Run `terraform plan`. Expected — no infrastructure changes:

```text
Plan: 0 to add, 0 to change, 0 to destroy
Changes to Outputs:  (named scalars + hub_subnet_ids added; any old subnet_ids/vnet_id removed)
```

`terraform apply` writes the values into state without touching Azure.


### Q&A

**Q1 — Why publish outputs instead of letting Day 7 read the subnet with its own data source?**
A `data` source couples Day 7 to the base's internal names; a base rename breaks it. An output is a contract the base keeps stable while refactoring internals.

**Q2 — Named scalar for `GatewaySubnet` but the map for `web` — why?**
Day 6 binds the gateway subnet by identity, so its ID is a contract validated at base-apply time (missing → fails immediately). Nothing binds `web` by identity; if read at all it's enumerated, so the map fits.

---

## Topic 6 — Cleaning up throwaway resources

### Theory

Day 2 left `nsg-vg-lab-wus-temp` deliberately. Three tools can remove a resource; only one both deletes it from Azure *and* keeps state honest:

```text
terraform destroy                 -> destroys the ENTIRE state. Wrong tool.
terraform destroy -target=<addr>  -> deletes it, but config still declares it, so the next plan
                                     proposes to RECREATE it. Break-glass only.
remove the config block + apply    -> in state, absent from config -> planned destroy.
                                     Deletes from Azure AND drops from state. CORRECT.
terraform state rm <addr>         -> removes from STATE only; the real NSG keeps running,
                                     now orphaned. For handing off, not deleting.
```

The correct path is the reconciliation table's destroy cell: a resource in state but absent from config is destroyed. So you retire it by deleting its declaration and letting a normal apply converge.

> **A bare `destroy` here errors — and that's the seatbelt.** Run `terraform destroy` and the plan reads `19 to destroy`; it halts only because `prevent_destroy` on the hub errors the whole plan. Lesson: a bare destroy targets the *entire* state, and `prevent_destroy` blocks the *plan*, not just its one resource. Fix the command; never disable the guard to silence the error.

### Exercise 6 — remove the throwaway NSG

**Objective:** permanently remove `nsg-vg-lab-wus-temp` from Azure and from state, cleanly.

**Decide:** of the three tools above, which one deletes it from Azure *and* leaves nothing behind that a later plan would try to recreate? Then apply that method.

**Predict — this is the safety gate:** what exactly should the `Plan:` line say, and which single resource should be in it?

**Solution** — try the exercise above before reading on.

```hcl
# d03ex06-rename.tf — comment out (or delete) the block so Terraform plans its destroy
# resource "azurerm_network_security_group" "d02-temp-nsg2" {
#   resource_group_name = data.azurerm_resource_group.main.name
#   location            = var.location
#   name                = "${local.nsg_name}-temp"
# }
```

Run `terraform plan`. Expected — exactly one destroy:

```text
Plan: 0 to add, 0 to change, 1 to destroy
# azurerm_network_security_group.d02-temp-nsg2 will be destroyed
# (because ... is not in configuration)
```

Anything other than one destroy of `nsg-vg-lab-wus-temp` → stop. Then `terraform apply`, and verify:

```powershell
terraform state list
# 19 addresses: no d02-temp-nsg2; exactly two NSGs (web, app), not three.
```


### Q&A

**Q1 — `-target` vs config-removal vs `state rm` — which deletes from Azure, and which is correct?**
`-target` and config-removal both delete from Azure; `state rm` orphans it. Correct is config-removal + apply — deletes from Azure *and* state, no recreate next plan. `-target` leaves config declaring a now-deleted resource.

**Q2 — A bare `terraform destroy` errored. What stopped it, and what would it have done?**
`prevent_destroy` on the hub errored the plan. Unguarded, it would have destroyed all 19 resources — bare `destroy` targets the whole state.

---

## Design challenge — `cidrsubnet()` vs explicit CIDRs

The hub `/20` is 16 `/24` blocks. After Day 3, occupied blocks are ~0–7 and 10–12; free are 8, 9, 13, 14, 15 — five `/24`s (~1280 addresses). The hub is over half consumed; spoke workload growth doesn't eat hub space (each spoke owns its own `/20`).

**Decision: declare CIDRs explicitly in tfvars.** `cidrsubnet()` wins when a layout is *algorithmic* — "N sequential equal subnets, positions don't matter." This environment is the opposite:

1. **Fixed schema positions.** CIDRs are assigned by an authoritative schema shared with the CLI lab (`db` is specifically `172.22.12.0/24`) and the layout has gaps. Making `cidrsubnet()` reproduce a gapped, non-sequential layout means hand-picking `netnum` per subnet — reintroducing the manual mapping it was meant to remove, less readably.
2. **Mixed-size reserved subnets.** `GatewaySubnet` (`/27`) and `AzureFirewallSubnet` (`/26`) are different prefix lengths from the `/24`s; a uniform `newbits` can't produce them.
3. **Legibility as a contract.** The schema is cross-referenced by the CLI lab, docs, and future engineers. An explicit CIDR *is* that contract, verifiable at a glance.

The `locals.tf` `subnet_map_hub` (`cidrsubnet()`) block is a deliberate teaching artifact — **not consumed**; subnets are driven by the explicit CIDRs in `var.subnets_hub`.

---

## Corrections & gotchas

| # | Gotcha | Correction |
|---|---|---|
| 1 | Reading a `create`-heavy plan as "state was deleted" | `+ create` = "in config, not in effective state" — usually wrong workspace/key. Check `terraform workspace show` first. |
| 2 | Thinking a workspace switch can replace the live hub | Workspaces have separate state; another workspace plans a *create* of a differently-named hub, never a replace of the live one. |
| 3 | Treating `-/+` as harmless because "only the name changed" | `-/+` = destroy + create = potential outage. Safe here only because the subnets were empty (pre-flight checked). |
| 4 | Renaming subnets by changing `for_each` keys | Keys drive both subnet *and* NSG names. Keep keys stable; change only the computed name expression, or you double-prefix names and churn NSGs. |
| 5 | Keying a reserved subnet as `gateway`/`firewall` | `name = each.key` means the key must be `GatewaySubnet`/`AzureFirewallSubnet` verbatim (exact, case-sensitive). |
| 6 | An NSG on `GatewaySubnet` | Unsupported; can break the gateway. Excluded structurally by the two-block split. |
| 7 | Omitting `service_actions` in a delegation | Azure fills the default and returns it on refresh → perpetual `~`. Specify `Microsoft.Network/virtualNetworks/subnets/join/action`. |
| 8 | Changing a DNS subnet's delegation after Day 4 binds the resolver | Forces the resolver endpoint to rebuild; a missing delegation throws `SubnetMissingRequiredDelegation`. |
| 9 | An NSG on the `pe` subnet without enabling network policies | With `private_endpoint_network_policies` Disabled, the NSG is bypassed for the PE — false enforcement. The pe NSG + policies is a Day 5 deliverable. |
| 10 | Hyphenated / resource-name-mirroring output names | Force bracket access, no dot traversal. Output names are the consumer API — snake_case. |
| 11 | `sensitive = true` left on an ID output | Propagates to every consumer. Subnet/VNet IDs aren't secrets — drop it. |
| 12 | Declaring variable attributes the resource never reads | Config that lies about intent (e.g. `has_nsg` on spoke vars that only read `.cidr`). Shape each object to its consumer. |
| 13 | `terraform destroy` to remove one resource | Bare `destroy` targets the whole state (blocked here by `prevent_destroy`). Remove the config block and `apply` instead. |