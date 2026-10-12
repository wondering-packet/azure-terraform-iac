# Day 8 — Reusable Modules (in-place refactor + debt sweep)

> **How to use this guide.** Each topic's theory gives you the building blocks — the mechanics and the one or two lines that matter — not the finished answer. Each exercise states a full problem: objective, inputs, constraints, and a *predict* step. Attempt it from the theory, predict the plan, then read the solution and apply. This day is structurally unlike the others: **no CLI lab, no new Azure resources.** You restructure the existing base into modules and prove — after every step — that the infrastructure is byte-for-byte unchanged.
>
> **Assumed knowledge this day:** you have written `moved` blocks (Day 5, three subnets) and used modules conceptually (Day 1). Both are assumed. This day teaches module *authoring* — interface design, boundary granularity, `moved`-at-scale — not "what is a module."
>
> **The one idea that carries the whole day:** a module is a code abstraction over *unchanged* infrastructure. Moving a resource into a module changes its **state address**; a `moved` block tells Terraform the object is the same, just relabeled; and a **zero-change plan** (`0 to add, 0 to change, 0 to destroy`, address moves only) is your proof after every extraction. The instant a `+`, `-`, or `~` appears on anything but a pure move, stop.

## File & marker conventions
- `dNN…` files are day-scoped. This day, resource bodies move *out* of those files and into `modules/<layer>/`.
- Shared root files (`main.tf`, `locals.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars`) carry inline `###---dNNexNN >>>` / `<<<` markers.
- Windows/PowerShell throughout: backtick (`` ` ``) line continuation, never `\`.

## Prerequisites & continuity
- **Prereq:** Days 0–7.
- **Live now (`networking/hub-spoke`, ~40 resources):** the full hub-spoke platform — 3 VNets, hub subnets in *two shapes* (a `for_each` set + 3 standalone), spoke subnets, NSGs, peering, routing, internal DNS, and the storage/PE cluster. azurerm v3.117.1, Azure AD auth, `default` workspace. Test rig live (`enable_test_vms=true`).
- **This day does:** restructure that base into 8 child modules, in place, with zero infra churn, and clear accumulated debt.
- **What Day 9 builds next:** load balancing (ILB + App Gateway) in a new ephemeral stack `networking/lb`, reading the base via `terraform_remote_state`. Day 8's clean module outputs feed it — specifically `hub_subnet_ids["shared"]` and `hub_subnet_ids["agw"]`.

## Standard lab environment
| Setting | Value |
|---|---|
| Subscription (lab) | `<your-subscription-id>` |
| Region / RG | `westus` / `rg-vg-lab-wus-01` |
| Backend | azurerm, state key `networking/hub-spoke`, AAD auth (`use_azuread_auth`/`use_cli`) |
| Provider | azurerm v3.117.1 (pinned) |
| Workspace | `default` |
| Naming | `-wus-` convention; `local.prefix = "vg-lab-wus"` |
| Supernet | `172.22.0.0/16` (hub `172.22.0.0/20`) |
| OS / shell | Windows / PowerShell |

## Table of contents
1. [Naming & module-interface conventions](#naming--module-interface-conventions)
2. [Topic 1 — Modules over unchanged infra & the `moved` block](#topic-1--modules-over-unchanged-infra--the-moved-block)
3. [Topic 2 — Module boundary design & root glue](#topic-2--module-boundary-design--root-glue)
4. [Topic 3 — Module interfaces, outputs & design choices](#topic-3--module-interfaces-outputs--design-choices)
5. [Topic 4 — The coupled cluster & the frozen output contract](#topic-4--the-coupled-cluster--the-frozen-output-contract)
6. [Topic 5 — Debt sweep](#topic-5--debt-sweep)
7. [Design challenge](#design-challenge)
8. [Corrections & gotchas](#corrections--gotchas)

---

## Naming & module-interface conventions

Read this before the exercises — it explains a source of confusion that recurs in every module: **which names are yours to choose, and which are fixed by the provider.**

A resource attribute like `resource_group_name` on `azurerm_virtual_network` is **fixed** — azurerm defines it, you can't rename it. But the *variable that feeds it* is **entirely your choice**:

```hcl
# inside modules/vnet/main.tf
resource "azurerm_virtual_network" "vnet" {
  resource_group_name = var.rg_name   # LEFT side fixed by azurerm; RIGHT side is a var WE named
  # ...
}
```

We named that variable `rg_name`. We could have named it `resource_group_name`, `rg`, `group`, or `banana` — the module would work identically as long as the call passes the matching name. So `rg_name` is a **custom interface name**, not an Azure thing.

**Best practice — mirror the provider's attribute name.** Naming the variable `resource_group_name` (not `rg_name`) makes the interface self-documenting: a reader instantly sees `resource_group_name = var.resource_group_name` and knows exactly what it feeds, with zero mental translation. This lab uses short names (`rg_name`, `snet_name`, `nsg_name`) as a pragmatic choice; the trade is a small amount of indirection. For a shared module library you publish to others (e.g. Wondering-packet's Artifactory modules), prefer the mirrored names.

Three naming layers, all yours, each with a different consequence:

| Layer | Example (this lab) | Consequence of the choice |
|---|---|---|
| **Input variable names** | `rg_name`, `address_space`, `nsg_sec_rules` | Only affects readability + what the call must pass. Free to change any time (change both sides). |
| **Output names** | `vnet_id`, `vnet_name`, `snet_id`, `nsg_id`, `rt_id`, `pe_id`, `psc_private_ip_address`, `private_dns_zone_name` | A **published contract**. Consumers bind to these names; renaming a *root* output breaks every `terraform_remote_state` reader (Day 9 reads these). |
| **Internal resource labels** | `azurerm_virtual_network.vnet`, `azurerm_subnet.snet`, `azurerm_network_security_group.nsg` | Appears inside the module's **state address**, so it shows up in every `moved` block's `to =`. Once chosen and moved-to, changing it means another move. |

**Interface design rules used across all 8 modules:**
- **Identity/placement inputs have no default** (`name`, `address_space`, `location`) — a caller who forgets one should get an error, not a silent wrong value in the wrong place.
- **Optional behaviour knobs default** (`service_endpoints = []`, `service_delegations = {}`, `private_endpoint_network_policies = null`, `nsg_sec_rules = {}`) — so a caller can omit them and get sensible do-nothing behaviour.
- **Validate at the boundary** — the `^172\.` CIDR guard lives in the module, so *any* caller passing a bad CIDR is rejected regardless of who calls it.
- **Keep names uniform across the library** — every module uses `rg_name`, `*_name`, `*_id`. Uniformity is what makes eight modules feel like one coherent toolkit.

Before Topic 1, prove the base is clean.

### Exercise 0 — attach & verify (copy-and-validate gate)

**Objective:** copy the correct folder forward and prove a zero-change attach *before* mutating anything.

**The one non-obvious decision — the seed source.** Every prior day copied "the previous day's folder." Your previous day was Day 7 (`day07-firewall`). Do **not** copy it. Days 6 and 7 were *ephemeral side-stacks* with their own state keys (`networking/vpn`, `networking/firewall`) — they read the base via `terraform_remote_state` but never owned it. The last folder that owns `networking/hub-spoke` is **day05**. Copy that.

```powershell
Copy-Item -Recurse .\day05-private-endpoints\ .\day08-modules\
cd .\day08-modules\
terraform init
terraform workspace show   # must be: default
terraform plan             # must be: No changes
```

**Predict:** `default` and `No changes`. Anything else — especially a `-/+` on the hub VNet — means wrong key or wrong seed; stop and investigate, don't fix forward. The base already contains the permanent Day-7 PE route (`spoke1_to_private_endpoint`), so its clean refresh is expected. Ex 0 produces no `.tf`; build exercises begin at Ex 1.

---

## Topic 1 — Modules over unchanged infra & the `moved` block

### Theory

Terraform tracks every resource by a **state address**. `azurerm_virtual_network.hub` lives at that address. Move its block into `./modules/vnet/` and the address becomes `module.vnets["hub"].azurerm_virtual_network.vnet`. The Azure resource is identical — but to Terraform the old address vanished from config and a new one appeared. Its default reading of "address X gone, address Y new" is **destroy X, create Y**.

**The `moved` block** rewrites the state pointer instead, so the plan is a pure move — zero infra change:

```hcl
moved {
  from = <old address>      # where the resource used to live
  to   = <new address>      # where its block lives now
}
```

**Every build exercise this day follows the same rhythm:** extract the resource into a module → add a `moved` block per relocated resource → `plan`, which prints a `# ... has moved to ...` line for each and reports `0 to add, 0 to change, 0 to destroy` → apply → optionally `state list` to confirm the new addresses. Internalize that rhythm now; the rest of the day is that loop, seven times.

#### The confusing part: an *address* reference is not an *expression* reference

This trips everyone. The same-looking `module.vnets["hub"]...` prefix appears in two completely different contexts that follow **opposite rules.**

**(1) Expression reference — reads a VALUE.** Shape: `module.<call name>.<OUTPUT name>`. It evaluates to whatever a *declared output* produces, and it **cannot** name a resource inside the module — the interface stops you at the outputs. This is what you write everywhere you *consume* a module:

```hcl
vnet_name = module.vnets["hub"].vnet_name   # .vnet_name is an OUTPUT the module declared
```

**(2) Address reference — names a LOCATION in state.** Shape: `module.<call name>[<key>].<resource type>.<resource label>`. It is not a value; it's the *address* where a resource sits in state, and it **does** reach inside the module, naming the internal resource by its `type.label`. This form is legal **only** in `moved` (and `import`) blocks:

```hcl
moved {
  from = azurerm_virtual_network.hub                         # old address, at root
  to   = module.vnets["hub"].azurerm_virtual_network.vnet    # new address, INSIDE the module
}
```

Put them side by side and stare at the tails:

```hcl
module.vnets["hub"].vnet_name                       # ends at an OUTPUT  -> a VALUE  (expression)
module.vnets["hub"].azurerm_virtual_network.vnet    # ends at a RESOURCE -> an ADDRESS (moved/import)
```

Why the asymmetry: an **expression** asks *"what value does this produce?"* — and a module only produces values through outputs, so the language refuses to let you read a resource directly (encapsulation). A **`moved` block** asks *"where does this resource live?"* — and state addresses are global paths, so you spell the whole thing, module prefix and internal label included.

> **The mistake to avoid** (a real one from this build): writing `module.vnets["hub"].azurerm_virtual_network.vnet.outputs.vnet_name` — addressing the internal resource *and* tacking `.outputs.vnet_name` on the end. Neither form allows that: the expression form must stop at `.vnet_name` (an output); the address form must stop at `.azurerm_virtual_network.vnet` (a resource) and only inside a `moved`/`import` block. If you want the *value*, use the output. If you want to relocate the *resource*, use the address in a `moved` block.

**`prevent_destroy` is the seatbelt, not the fix.** Forget a `moved` block on a VNet carrying `prevent_destroy = true` and the plan **errors at plan time** (it can't produce an applyable plan that destroys a protected resource) — a loud, pre-apply stop instead of a silent destroy-and-recreate cascade. But on an *unguarded* spoke, the same omission plans a clean `1 to destroy, 1 to add` and proceeds. So the `moved` block is what makes the refactor correct; the **zero-change gate after every extraction** is the real safety net; `prevent_destroy` only backstops the resources you flagged.

### Exercise 1 — Extract the VNet layer (the fully-worked template)

This is the template for every extraction that follows. Read it end to end — the mechanics here (module ⇄ call ⇄ tfvars ⇄ locals ⇄ outputs ⇄ moved) repeat for subnets, NSGs, peering, routing, DNS, storage, and the PE.

**Objective:** move `hub`, `spoke1`, `spoke2` VNets into `./modules/vnet`, wire the module call, add `moved` blocks, prove zero-change.

**Inputs** (`var.vnets` in tfvars):

| VNet key | address_space | location |
|---|---|---|
| hub | `172.22.0.0/20` | westus |
| spoke1 | `172.22.16.0/20` | westus |
| spoke2 | `172.22.32.0/20` | westus |

**Constraints:**
- All three carry `prevent_destroy = true` and `ignore_changes = [tags]`.
- `prevent_destroy` **must be a literal** — it cannot read a variable. A single 3×-invoked module therefore forces the same value on all three (fine here — all three want `true`).
- The rest of root still references the VNets — the module's **outputs** must feed them.

**Blocks to write:** `modules/vnet` — `azurerm_virtual_network.vnet`, no child blocks; `variables.tf` (name, rg, location, address_space, tags) + `outputs.tf` (`vnet_id`, `vnet_name`, `vnet_address_space`, `vnet_primary_cidr`); root `module "vnets"` with `for_each = var.vnets`; `moved` blocks per VNet.

**Predict:** before the `moved` blocks, the first `plan` errors "Reference to undeclared resource" (downstream files still name `azurerm_virtual_network.hub`). After re-pointing consumers and adding `moved` blocks: three `has moved to` lines, `0/0/0`.

**Solution** — try the exercise above before reading on.

**Step 1 — the module body.** This is the "template" a caller stamps out. Every attribute pulls from a variable so the *same* code can build a hub or a spoke:

```hcl
# modules/vnet/main.tf
resource "azurerm_virtual_network" "vnet" {          # label "vnet" -> appears in moved addresses as ....azurerm_virtual_network.vnet
  # define all these variables in variables file.
  # the root modules will see these as the variables that
  # can be passed in this module.
  # visual code studio e.g. pops up suggestions with these names.
  name                = var.vnet_name        # LEFT = azurerm-fixed; RIGHT = the var WE named (see naming section)
  resource_group_name = var.rg_name
  location            = var.location
  address_space       = var.address_space
  tags                = var.tags
  # explicitely setting lifecycle.
  lifecycle {
    prevent_destroy = true                   # literal only — cannot be var.something; applies to every call of this module
    ignore_changes  = [tags]
  }
}
```

**Step 2 — the interface (`variables.tf`).** Each variable is a "slot" the call fills. There is a one-to-one line between a variable here and an argument in the module call (Step 4):

```hcl
# modules/vnet/variables.tf
variable "vnet_name" { type = string }     # -> feeds resource.name
variable "rg_name"   { type = string }     # -> feeds resource.resource_group_name
variable "location"  { type = string }     # -> feeds resource.location

variable "address_space" {
  type = list(string)
  # validation runs at the MODULE boundary: any caller passing a non-172 CIDR is rejected.
  # can(regex(...)) returns true/false instead of erroring, so alltrue() can test every CIDR.
  validation {
    condition     = alltrue([for cidr in var.address_space : can(regex("^172\\.", cidr))])
    error_message = "All CIDRs must start with 172."
  }
}

variable "tags" {
  type    = map(string)
  default = {}      # optional knob -> a caller may omit it and get {}
}
```

**Step 3 — the outputs (`outputs.tf`).** Outputs are the module's *entire* public surface. Anything a consumer needs (`.name`, `.id`, the address space) must be republished here — a caller cannot reach the resource directly:

```hcl
# modules/vnet/outputs.tf
output "vnet_id"            { value = azurerm_virtual_network.vnet.id }
output "vnet_name"          { value = azurerm_virtual_network.vnet.name }           # subnets/peering/dns consume this
output "vnet_address_space" { value = azurerm_virtual_network.vnet.address_space }
output "vnet_primary_cidr"  { value = azurerm_virtual_network.vnet.address_space[0] }
```

**Step 4 — the call, in root `main.tf`.** `for_each = var.vnets` invokes the module once per entry (`hub`, `spoke1`, `spoke2`), producing `module.vnets["hub"]`, `["spoke1"]`, `["spoke2"]`. Each argument on the left is a **module variable**; each value on the right is resolved *here in root*:

```hcl
# root main.tf
module "vnets" {
  source        = "./modules/vnet"
  for_each      = var.vnets                       # one call per map entry; each.key = "hub"/"spoke1"/"spoke2"
  rg_name       = data.azurerm_resource_group.main.name
  location      = each.value.location             # each.value = the object for this key (from tfvars)
  address_space = each.value.address_space
  vnet_name     = "${local.vnet_name}-${each.key}"  # name assembled from a local + the key -> "vnet-vg-lab-wus-hub"
  tags          = local.lab_tags
  depends_on    = [data.azurerm_resource_group.main] # this goes here cuz vnet module doesn't know our rg.
}
```

> **How the pieces interoperate here:** `var.vnets` (tfvars data) drives `for_each`; `each.value.*` reads that data; `local.vnet_name` (the naming chain) plus `each.key` builds the resource name; `local.lab_tags` supplies tags. The module never sees `var.vnets`, `local.vnet_name`, or the RG — it only sees the five variables root hands it. That's the boundary: **root resolves everything and passes finished values down.**
> Note the `${...}` interpolation: `"${local.vnet_name}-${each.key}"` wraps *each* dynamic piece in its own `${}`. Text outside `${}` is literal — writing `"${local.vnet_name}-each.key"` would put the literal characters `-each.key` on the name, and since `name` is ForceNew, that mismatch would turn the move into a destroy/recreate.

**Step 5 — the tfvars data.** `var.vnets` is a `map(object({...}))`; the map keys become the `for_each` keys. First the **type contract** (root `variables.tf`), then the data that fills it:

```hcl
# variables.tf  (###---d08ex01)  — the schema the tfvars must satisfy
variable "vnets" {
  type = map(object({
    address_space = list(string)
    location      = optional(string)   # optional here; the call passes each.value.location regardless
  }))
}
```

```hcl
# terraform.tfvars  (###---d08ex01)  — data that fills the schema above
vnets = {
  hub    = { address_space = ["172.22.0.0/20"],  location = "westus" }
  spoke1 = { address_space = ["172.22.16.0/20"], location = "westus" }
  spoke2 = { address_space = ["172.22.32.0/20"], location = "westus" }
}
```

**Step 6 — re-point the consumers.** Everything that used to say `azurerm_virtual_network.hub.<attr>` now reads the module *output*. This is the expression form from the theory:

```hcl
# e.g. in root outputs.tf
output "hub_vnet_id" { value = module.vnets["hub"].vnet_id }   # was azurerm_virtual_network.hub.id
# and in the subnet calls: vnet_name = module.vnets["hub"].vnet_name
```

**Step 7 — the `moved` blocks.** One per relocated resource; `to =` is the **address** form (reaches inside the module to the `vnet` label):

```hcl
# moved.tf
moved {
  from = azurerm_virtual_network.hub
  to   = module.vnets["hub"].azurerm_virtual_network.vnet    # ADDRESS, not an output
}
moved {
  from = azurerm_virtual_network.spoke1
  to   = module.vnets["spoke1"].azurerm_virtual_network.vnet
}
moved {
  from = azurerm_virtual_network.spoke2
  to   = module.vnets["spoke2"].azurerm_virtual_network.vnet
}
```

**Run it.** Predict: three `has moved to`, `0/0/0`. Apply, then confirm the relocation persisted:

```powershell
terraform apply
terraform state list | Select-String "virtual_network"
# expect: module.vnets["hub"|"spoke1"|"spoke2"].azurerm_virtual_network.vnet
# the old azurerm_virtual_network.hub addresses should be GONE.
```

**Locals** (relevant): `local.vnet_name` = `vnet-${local.prefix}` (`vnet-vg-lab-wus`) — **reused**; `local.lab_tags` — **reused**.

### Q&A — Topic 1

**Q. You forget the `moved` block for `azurerm_virtual_network.hub`. What does `plan` show, and why is it catastrophic given `prevent_destroy = true`?**
Terraform sees the old address gone (→ destroy) and the module address new (→ create). `prevent_destroy` is evaluated at plan time, so the plan **errors and yields no applyable plan** — you never reach apply. That's the favor: it stops a destroy-and-recreate of the hub (cascading to every subnet/peering/association) before it happens. On an unguarded spoke the same omission plans `1 destroy, 1 add` and proceeds — which is why the zero-change gate, not `prevent_destroy`, is the real safeguard.

**Q. Why can I write `module.vnets["hub"].azurerm_virtual_network.vnet` in a `moved` block but not in a `subnet_id = ...` expression?**
Because they ask different questions. The expression asks for a *value*, and a module exposes values only through outputs — so it must end at an output (`.vnet_id`). The `moved` block names a *state address*, which is a global path that includes the module and the internal resource label. Address form reaches inside; expression form stops at the interface.

---

## Topic 2 — Module boundary design & root glue

### Theory

Before any extraction you decide *what the modules are*. Three candidate boundaries weighed on **reuse**, **blast radius**, **input surface**, and one hard constraint:

- **(a) One big `hub-spoke-network` module** — coarse, low reuse.
- **(b) Per-layer modules** (`vnet`, `subnet`, `nsg`, `peering`, `routing`, `dns`, + a storage/PE pair) — the chosen boundary.
- **(c) One per-VNet module invoked 3×** — maximum DRY *only if the three are homogeneous.*

**Why (c) fails here — and the rule it teaches.** (c) does *not* mean rewriting structure per VNet; it means writing it once and calling it 3×. It fails because hub and spokes are **asymmetric roles**: the hub carries 8 for_each subnets + 3 standalone + 2 NSGs + the storage/PE cluster + DNS; each spoke carries one workload subnet + a peering + a route table. Forcing them through one module means an `is_hub` flag gating every hub-only feature. **"One module, N calls" is right when the N are homogeneous; wrong when they're different roles wearing the same resource type.** (You'll see the *correct* use of "one module, N calls" with the DNS module later — two zones that genuinely *are* homogeneous.)

> **Honest note on "reusable."** A per-layer module invoked once from a single root isn't reuse in the marketplace sense — it's **code organization + a stable interface contract** (blast-radius isolation, a tested boundary, an output surface Day 9 leans on). Legitimate, but be honest about it. The cost of per-layer: IDs must **flow between modules** (subnet outputs feed NSG-association, routing, peering). More plumbing than one fat module; worth it here.

#### Root glue — what it is and why it belongs in root

After you split into per-layer modules, some resources don't fit *any* single layer. A **subnet↔NSG association**, a **route-table↔subnet association**, a **DNS A-record** — each of these needs IDs from **two different modules** to exist. They are not "an NSG thing" or "a subnet thing"; they are the **wire between two layers.** These live in **root**, and that is not a lesser or unfinished state — it is exactly root's job after modularizing: root is the **composition layer** that calls modules and connects their outputs to each other's inputs.

**The litmus:** *is this join intrinsic to one thing (bundle it into that thing's module) or is it incidental wiring between two independently-meaningful things (root glue)?*
- A route table without routes is inert → routes are **intrinsic** to the route table → **bundle** them in the routing module.
- A route table can associate to *many* subnets; the pairing is not part of what a route table *is* → the association is **incidental** → **root glue**.

**The root-glue resources this day (all correctly left in root):**

| Root-glue resource | Consumes (module A) | Consumes (module B) |
|---|---|---|
| `azurerm_subnet_network_security_group_association.hub_pe` | `module.nsg_hub_pe.nsg_id` | `module.snets_hub_special["pe"].snet_id` |
| `azurerm_subnet_route_table_association.spoke1_workload_to_rt_spoke1` | `module.routing["spoke1"].rt_id` | `module.snets_spoke1["workload"].snet_id` |
| `azurerm_subnet_route_table_association.spoke2_workload_to_rt_spoke2` | `module.routing["spoke2"].rt_id` | `module.snets_spoke2["workload"].snet_id` |
| `azurerm_subnet_route_table_association.gateway_to_rt_gateway` | `module.routing["gw"].rt_id` | `module.snets_hub_special["GatewaySubnet"].snet_id` |
| `azurerm_private_dns_a_record.lab_storage_pe` | `module.dns["privatelink…"].private_dns_zone_name` | `module.storage_pe.psc_private_ip_address` |

Notice each row reads from **two** module outputs. That two-module dependency is the signature of root glue. A quick rule you can carry forward: **if a resource needs IDs from two different modules to exist, it's almost always root glue.**

### Exercise 2 — Extract the subnet layer (the two-shape problem)

**Objective:** move all subnets into `./modules/subnet`, `moved`-block them, prove zero-change. Trickiest extraction of the day.

**Inputs** — the complete `var.snets` map (validated against tfvars):

| Group | Key | address_prefixes | Notable attributes |
|---|---|---|---|
| hub | web | `172.22.10.0/24` | `has_nsg = true` |
| hub | app | `172.22.11.0/24` | `has_nsg = true` |
| hub | db | `172.22.12.0/24` | `service_endpoints = ["Microsoft.Storage"]` |
| hub | mgmt | `172.22.7.0/24` | — |
| hub | shared | `172.22.2.0/24` | — |
| hub | dns-inbound | `172.22.4.0/24` | `delegation` → `Microsoft.Network/dnsResolvers` |
| hub | dns-outbound | `172.22.5.0/24` | `delegation` → `Microsoft.Network/dnsResolvers` |
| hub | agw | `172.22.6.0/24` | — |
| hub_special | GatewaySubnet | `172.22.0.0/27` | reserved literal name |
| hub_special | AzureFirewallSubnet | `172.22.1.0/26` | reserved literal name |
| hub_special | pe | `172.22.3.0/24` | `private_endpoint_network_policies = "Enabled"` |
| spoke1 | workload | `172.22.16.0/24` | `service_endpoints = ["Microsoft.Storage"]` |
| spoke2 | workload | `172.22.32.0/24` | — |

**Constraints:**
- Preserve the **two shapes** — don't flatten. The loopables (`snets.hub`) are uniform; the specials (`snets.hub_special`) diverge on name and policy.
- `for_each` index keys survive (`["web"]` maps through).
- The pe subnet's `private_endpoint_network_policies = "Enabled"` must stay **explicit** (an Optional+Computed attribute silently reverts to a provider default on a fresh apply if omitted — see the gotchas table).

**Blocks to write:** `modules/subnet` — `azurerm_subnet.snet` + a `dynamic "delegation"`; interface with `service_endpoints` (default `[]`), `service_delegations` (default `{}`), `private_endpoint_network_policies` (default `null`). Root calls `snets_hub`, `snets_hub_special`, `snets_spoke1`, `snets_spoke2`. `moved` all 13.

**Predict:** 13 `has moved to`, `0/0/0`.

**Solution** — try the exercise above before reading on.

The **type contract** (root `variables.tf`) — one `object` with four keys; `hub` shown in full, `hub_special` shown for its two-layer-default reasoning, `spoke1`/`spoke2` mirror `hub`:

```hcl
# variables.tf  (###---d08ex02)
variable "snets" {
  # you only define type at the root.
  type = object(
    {                    # this object contains 4 keys: hub, hub_special, spoke1, spoke2.
      hub = map(object({ # hub is then further defines a map. inner map.
        # inner map here contains all these variables.
        address_prefixes  = list(string)
        has_nsg           = optional(bool, false)
        service_endpoints = optional(list(string))
        delegations = optional(map(object({
          name    = string
          actions = list(string)
        })), {}) # {} set the default.
      }))

      hub_special = map(object({
        address_prefixes = list(string)
        # notice that i am always trying to pass a default for optionals
        # this ensures that my "snets" module inside the root always
        # have this attribute defined. if a subnet doesn't have this attribute
        # defined in tfvars then "null" is passed to subnet module.
        # subnet module too has a default "null" as a 2nd layer of safety
        # the reason for having default at 2 layers is cuz i can now have
        # multiple "snets" modules at root, some of which can choose to include
        # this attribute (in which both layers work for not assigned variable)
        # while some of the root module can simply choose not to add this attribute
        # in the definition (in which cas my layer 2's default sets the null
        # and this is exactly why i need null at layer 2 as well).
        private_endpoint_network_policies = optional(string, null)
      }))

      # spoke1 = map(object({ ... same shape as hub ... }))
      # spoke2 = map(object({ ... same shape as hub ... }))
    }
  )
}
```

```hcl
# modules/subnet/main.tf
resource "azurerm_subnet" "snet" {
  name                              = var.snet_name
  resource_group_name               = var.rg_name
  virtual_network_name              = var.vnet_name             # fed by module.vnets["hub"].vnet_name from root
  address_prefixes                  = var.address_prefixes
  service_endpoints                 = var.service_endpoints
  private_endpoint_network_policies = var.private_endpoint_network_policies

  # a dynamic block renders ZERO child blocks when its for_each is empty ({}),
  # and one "delegation {}" per map entry otherwise. so subnets with no delegation
  # (the default {}) emit nothing; dns-inbound/outbound emit their resolver delegation.
  dynamic "delegation" {
    for_each = var.service_delegations
    content {
      name = delegation.key                         # delegation.key/.value are the dynamic block's iterator
      service_delegation {
        name    = delegation.value.name
        actions = delegation.value.actions
      }
    }
  }
}
```

```hcl
# modules/subnet/variables.tf  (interoperation notes inline)
variable "vnet_name"        { type = string }
variable "rg_name"          { type = string }
variable "snet_name"        { type = string }
variable "address_prefixes" {
  type = list(string)
  validation {   # same ^172 boundary guard as the vnet module
    condition     = alltrue([for cidr in var.address_prefixes : can(regex("^172\\.", cidr))])
    error_message = "All CIDRs must start with 172."
  }
}
variable "service_endpoints"                 { type = list(string), default = [] }   # optional knob
variable "private_endpoint_network_policies" { type = string,       default = null } # null = "leave to provider" for callers that don't set it
variable "service_delegations" {
  # map can hold multiple delegations. each delegation will have a key.
  # the value inside the key will contain {name = NAME actions = ACTIONS}
  type = map(object({
    name    = string
    actions = list(string)
  }))
  default = {}   # default when nothing is passed -> dynamic block renders nothing
}
```

The two-shape split in root — one module, **four calls**, differing only by inputs:

```hcl
# root main.tf
module "snets_hub" {                                # the 8 uniform loopables
  source              = "./modules/subnet"
  rg_name             = data.azurerm_resource_group.main.name
  for_each            = var.snets.hub
  vnet_name           = module.vnets["hub"].vnet_name # this is you consume outputs from a module.
  address_prefixes    = each.value.address_prefixes
  snet_name           = "${local.snet_name}-${each.key}"
  service_endpoints   = each.value.service_endpoints  # null is the default in variables.tf if the snet variable doesn't have this attribute.
  service_delegations = each.value.delegations        # similarily the default is [] for this attribute.
}

# i had to create another hub module cuz of non standard naming convention
module "snets_hub_special" {                        # gateway/firewall (reserved names) + pe (odd policy)
  source           = "./modules/subnet"
  rg_name          = data.azurerm_resource_group.main.name
  for_each         = var.snets.hub_special
  vnet_name        = module.vnets["hub"].vnet_name
  address_prefixes = each.value.address_prefixes
  # our special pe child still causing problems!
  # ternary: pe gets the standard prefixed name; gateway/firewall keep their exact reserved literal (each.key).
  snet_name                         = each.key == "pe" ? "${local.snet_name}-${each.key}" : each.key
  private_endpoint_network_policies = each.value.private_endpoint_network_policies
}

# i did not want to bundle all subnets into a single snets module
# just to keep some segragation at vnet level.
module "snets_spoke1" {
  source              = "./modules/subnet"
  rg_name             = data.azurerm_resource_group.main.name
  for_each            = var.snets.spoke1
  vnet_name           = module.vnets["spoke1"].vnet_name
  address_prefixes    = each.value.address_prefixes
  snet_name           = "${local.snet_name}-spoke1-${each.key}"
  service_endpoints   = each.value.service_endpoints
  service_delegations = each.value.delegations
}
# snets_spoke2 is identical with spoke2 substituted.
```

> **Design choice — split calls, not a split module.** All four calls use the *same* `./modules/subnet` code; they differ only in which slice of `var.snets` they iterate and how the name is built. Keeping the specials in their own call (`snets_hub_special`) means the odd naming (the `each.key == "pe" ? ...` ternary — *"if pe, prefix it; else use the reserved literal"*) lives in exactly one place instead of polluting the uniform loop. The spokes get their own calls purely for readability/segregation at the VNet level, as the learner's comment notes.

`moved` blocks preserve the index for loopables and add an index for the standalones:

```hcl
moved { from = azurerm_subnet.hub["web"]          to = module.snets_hub["web"].azurerm_subnet.snet }
# … the other 7 loopables …
moved { from = azurerm_subnet.hub_gateway         to = module.snets_hub_special["GatewaySubnet"].azurerm_subnet.snet }
moved { from = azurerm_subnet.hub_azurefirewall   to = module.snets_hub_special["AzureFirewallSubnet"].azurerm_subnet.snet }
moved { from = azurerm_subnet.hub_pe              to = module.snets_hub_special["pe"].azurerm_subnet.snet }
moved { from = azurerm_subnet.spoke1              to = module.snets_spoke1["workload"].azurerm_subnet.snet }
moved { from = azurerm_subnet.spoke2              to = module.snets_spoke2["workload"].azurerm_subnet.snet }
```

**Locals** (relevant): `local.snet_name` = `snet-${local.prefix}` (`snet-vg-lab-wus`) — **reused**.

### Q&A — Topic 2

**Q. Why keep the for_each set and the three standalone subnets in separate calls instead of one uniform module?**
The standalones exist *because* they diverge — Gateway/Firewall need bare reserved names, pe needs a different policy and name. A single uniform loop would need per-key conditionals to reproduce those divergences, and each new special case adds another `each.key == X ?` branch. Splitting the uniform loopables from the specials keeps each call coherent — the "one module, N calls only when homogeneous" rule again.

---

## Topic 3 — Module interfaces, outputs & design choices

### Theory

**Encapsulation is outputs-only — for both boundaries.** A **module** boundary (within one state) and a **remote-state** boundary (across states) follow the same rule with different plumbing: a caller reads only declared outputs (`module.NAME.OUTPUT`, or `data.terraform_remote_state.base.outputs.NAME`). This is why re-plumbing root's `outputs.tf` matters — root outputs are sourced from `module.*.` outputs, and *those* are what Day 9 reads. Two nested outputs-only boundaries, back to back.

**Composition-layer resolution.** Cross-module and cross-stack values are resolved in **root** and passed to modules *pre-resolved* — a module never reaches out for a sibling's or another stack's value. Three design choices this day put that principle to work:

- **Bidirectional peering as one module (two resources, one call per pair).** A VNet peering is inherently two-sided; one direction alone is a broken link. Bundling both directions into one module means you *physically cannot* create a half-peered link — the module **encapsulates the pairing invariant**. Root glue couldn't give you that guarantee.
- **Dump the whole `routes` object into the routing module and let it iterate.** Rather than declaring five route resources, root hands the routing module the entire per-table `routes` map; the module runs a `for_each` internally, creating the table and all its routes **in one pass**. Adding a route later is a tfvars edit, not new HCL.
- **Mutate a variable into a local for DNS.** `var.dns` can't hold `module.vnets[...].vnet_id` (variables can't contain expressions). So root builds `local.dns` — a copy of `var.dns` with `vnet_id` injected per link — and the DNS module iterates *that*. The static topology stays in tfvars; the computed IDs get married in root.

The through-line: **static intent lives in tfvars; computed/cross-boundary values get resolved in root; modules receive finished values.**

### Exercise 3 — Extract NSGs + the association

**Objective:** move the NSG layer into `./modules/nsg`; decide where the association lives; prove zero-change.

**Inputs:** `azurerm_network_security_group.main["web"|"app"]` (a for_each factory over `has_nsg` subnets), `.storage_pe` (one NSG with two inline rules), and `azurerm_subnet_network_security_group_association.hub_pe`. The rule data lives in `var.nsg_sec_rules` keyed `"hub-pe"` (web/app carry no rules).

**Constraints:** one flexible NSG module with a `dynamic "security_rule"` fed from a variable (empty default → no rules); the two `hub-pe` rules must render field-for-field.

**Blocks to write:** `modules/nsg` — `azurerm_network_security_group.nsg` + `dynamic "security_rule"`, output `nsg_id`. Association = **root glue**.

**Predict:** 3 NSG moves; the association is **re-pointed, not moved**; `0/0/0`.

**Solution** — try the exercise above before reading on.

The rule data (`var.nsg_sec_rules`) — only `hub-pe` has rules; web/app are absent (→ `lookup` gives `{}`). First the **type contract** (a map-of-map-of-object; every rule field optional-with-default except the required few), then one rule shown in full:

```hcl
# variables.tf  (###---d08ex03)  — schema
variable "nsg_sec_rules" {
  type = map( # a map of map
    map(object({
      description                  = optional(string, null)
      protocol                     = string
      source_port_range            = optional(string, null)
      source_port_ranges           = optional(list(string), null)
      destination_port_range       = optional(string, null)
      destination_port_ranges      = optional(list(string), null)
      priority                     = number
      source_address_prefix        = optional(string, null)
      source_address_prefixes      = optional(list(string), null)
      destination_address_prefix   = optional(string, null)
      destination_address_prefixes = optional(list(string), null)
      access                       = string
      direction                    = string
    }))
  )
  default = {}   # whole variable optional -> callers with no rules omit it
}
```

```hcl
# terraform.tfvars  (###---d08ex03)  — truncated to the hub-pe entry
nsg_sec_rules = {
  "hub-pe" = {
    "allow-spoke1-workload" = {                 # map key becomes the rule NAME in the module
      description                = "allow spoke1's workload subnet to access PE subnet"
      protocol                   = "Tcp"
      destination_port_range     = "443"
      source_port_range          = "*"
      priority                   = 100
      source_address_prefix      = "172.22.16.0/24"
      destination_address_prefix = "*"
      access                     = "Allow"
      direction                  = "Inbound"
    }
    "deny-all" = { # same shape: protocol "*", priority 4096, access "Deny", all prefixes/ports "*"
      # ...
    }
  }
}
```

```hcl
# modules/nsg/main.tf
resource "azurerm_network_security_group" "nsg" {
  name                = var.nsg_name
  resource_group_name = var.rg_name
  location            = var.nsg_location

  # read up more on dynamic blocks but bascially it's only passed to azure if not empty.
  # for_each over the rules map: 0 rules -> no security_rule blocks; N rules -> N blocks.
  dynamic "security_rule" {
    for_each = var.nsg_sec_rules # our main iterator
    content {
      # notice we are referencing the iterated dynamic block which is "security_rule" above.
      # also note that most of below attributes are optional with defaults. see variables.
      name                         = security_rule.key      # rule name = map key -> unique per NSG for free
      description                  = security_rule.value.description
      protocol                     = security_rule.value.protocol
      destination_port_range       = security_rule.value.destination_port_range
      source_port_range            = security_rule.value.source_port_range
      source_port_ranges           = security_rule.value.source_port_ranges
      destination_port_ranges      = security_rule.value.destination_port_ranges
      priority                     = security_rule.value.priority
      source_address_prefix        = security_rule.value.source_address_prefix
      source_address_prefixes      = security_rule.value.source_address_prefixes
      destination_address_prefix   = security_rule.value.destination_address_prefix
      destination_address_prefixes = security_rule.value.destination_address_prefixes
      access                       = security_rule.value.access
      direction                    = security_rule.value.direction
    }
  }
}
```

```hcl
# root main.tf
module "nsgs" {                                     # factory: one NSG per has_nsg hub subnet (web, app)
  source       = "./modules/nsg"
  rg_name      = data.azurerm_resource_group.main.name
  nsg_location = data.azurerm_resource_group.main.location
  for_each     = { for k, v in var.snets.hub : k => v if v.has_nsg }  # comprehension filters to has_nsg subnets
  nsg_name     = "${local.nsg_name}-${each.key}"
  # lookup is great for this scenario, it returns {} if the key is not found.
  nsg_sec_rules = lookup(var.nsg_sec_rules, each.key, {})   # web/app have no rules entry -> {} -> no rules
}

module "nsg_hub_pe" {                               # the odd-named PE NSG gets its own call
  source       = "./modules/nsg"
  rg_name      = data.azurerm_resource_group.main.name
  nsg_location = data.azurerm_resource_group.main.location
  # pe ofc needed its own module due to stupid non standard naming convention.
  # and also the above "nsgs" iterates over var.snets.hub while our
  # pe is in var.snets.hub_special
  nsg_name      = "${local.nsg_name}-hub-pe"
  nsg_sec_rules = lookup(var.nsg_sec_rules, "hub-pe", {})   # the two hub-pe rules from tfvars
}

# main.tf at root is the perfect plan to tie different modules together.
# nsg association is one such resource.  <-- ROOT GLUE: joins NSG module + subnet module
resource "azurerm_subnet_network_security_group_association" "hub_pe" {
  network_security_group_id = module.nsg_hub_pe.nsg_id
  subnet_id                 = module.snets_hub_special["pe"].snet_id
}
```

> **Design choices here.** (1) The factory's `for_each` is driven by the **subnet** map filtered on `has_nsg` — "which subnets get an NSG" is subnet-truth, kept in one place. (2) `lookup(map, key, {})` returns `{}` when a key is absent, so web/app (no rules entry) get empty rule sets cleanly — no error, no special-casing. (3) The PE NSG got its **own call** (`nsg_hub_pe`) rather than a name ternary in the factory — cleaner, and it also sidesteps that the factory iterates `snets.hub` while pe lives in `snets.hub_special`. (4) The association stays in root because it joins two modules — textbook root glue.

**Locals** (relevant): `local.nsg_name` = `nsg-${local.prefix}` (`nsg-vg-lab-wus`) — **reused**.

### Exercise 4 — Peering + Routing + DNS

**Objective:** move these three layers into modules, `moved` whatever relocates, prove zero-change.

**Inputs:** 4 peerings (`var.peerings` keyed `hub_and_spoke1`, `hub_and_spoke2`); routing (`var.routing_tables` → 3 tables, 5 routes; associations at root); DNS (`var.dns` → `internal.lab.com` zone + 3 links; the privatelink zone joins in Ex 5).

**Constraints & decisions:**
- **Peering** = a bidirectional module (2 resources, one pair per call), independent per-direction flags (hub side sets `allow_gateway_transit = true`; spoke side `use_remote_gateways`/transit differ — asymmetric).
- **Routing** = RT + routes bundled (routes are intrinsic); the 3 associations = **root glue**.
- **DNS** = zone + links bundled (links are intrinsic to a usable zone), fed by `local.dns`.

**Blocks to write:** `modules/peering` (`azurerm_virtual_network_peering.p1_p2_peering` + `.p2_p1_peering`), `modules/routing` (`azurerm_route_table.rt` + `azurerm_route.route` via for_each), `modules/dns` (`azurerm_private_dns_zone.dns` + `azurerm_private_dns_zone_virtual_network_link.dns_vnet_link` via for_each).

**Predict:** 16 moves (4 peerings + 3 RTs + 5 routes + 1 zone + 3 links); associations do **not** appear; `0/0/0`.

**Solution** — try the exercise above before reading on.

The peering data (`var.peerings`) — one entry shown; `hub_and_spoke2` is identical with `spoke2` substituted. Note the **asymmetry**: the hub side (`_on_p1`) enables `allow_gateway_transit`; the spoke side (`_on_p2`) does not. First the **type contract** (every flag optional-with-default, so tfvars only sets what differs):

```hcl
# variables.tf  (###---d08ex04)  — schema
variable "peerings" {
  type = map(object({ # map of object allows holding multiple peerings.
    p1 = string       # peer 1
    p2 = string       # peer 2
    # everything below is optional with default
    allow_virtual_network_access_on_p1 = optional(bool, true)
    allow_forwarded_traffic_on_p1      = optional(bool, false)
    allow_gateway_transit_on_p1        = optional(bool, false)
    use_remote_gateways_on_p1          = optional(bool, false)
    allow_virtual_network_access_on_p2 = optional(bool, true)
    allow_forwarded_traffic_on_p2      = optional(bool, false)
    allow_gateway_transit_on_p2        = optional(bool, false)
    use_remote_gateways_on_p2          = optional(bool, false)
  }))
}
```

```hcl
# terraform.tfvars  (###---d08ex04)  — truncated to one pair
peerings = {
  hub_and_spoke1 = {
    p1 = "hub"                                   # VNet KEY (string) — ID resolved in the call, not here
    p2 = "spoke1"
    allow_virtual_network_access_on_p1 = true
    allow_forwarded_traffic_on_p1      = true
    allow_gateway_transit_on_p1        = true    # hub side: offers transit
    use_remote_gateways_on_p1          = false
    allow_virtual_network_access_on_p2 = true
    allow_forwarded_traffic_on_p2      = true
    allow_gateway_transit_on_p2        = false   # spoke side: asymmetric
    use_remote_gateways_on_p2          = false
  }
  # hub_and_spoke2 = { ... same shape, p2 = "spoke2" ... }
}
```

**Peering** — generic `p1`/`p2`, so the module doesn't hardcode "hub/spoke"; both directions in one module:

```hcl
# modules/peering/main.tf
resource "azurerm_virtual_network_peering" "p1_p2_peering" {   # direction: p1 -> p2
  resource_group_name          = var.rg_name
  name                         = var.p1_p2_peering_name
  virtual_network_name         = var.p1_vnet_name              # local side named by name
  remote_virtual_network_id    = var.p2_vnet_id                # remote side referenced by id
  allow_virtual_network_access = var.allow_virtual_network_access_on_p1
  allow_forwarded_traffic      = var.allow_forwarded_traffic_on_p1
  allow_gateway_transit        = var.allow_gateway_transit_on_p1   # per-DIRECTION flag (hub side)
  use_remote_gateways          = var.use_remote_gateways_on_p1
}

resource "azurerm_virtual_network_peering" "p2_p1_peering" {   # direction: p2 -> p1
  resource_group_name          = var.rg_name
  name                         = var.p2_p1_peering_name
  virtual_network_name         = var.p2_vnet_name
  remote_virtual_network_id    = var.p1_vnet_id
  allow_virtual_network_access = var.allow_virtual_network_access_on_p2
  allow_forwarded_traffic      = var.allow_forwarded_traffic_on_p2
  allow_gateway_transit        = var.allow_gateway_transit_on_p2   # per-DIRECTION flag (spoke side)
  use_remote_gateways          = var.use_remote_gateways_on_p2
}
```

The call — the **seeding pattern** worth banking: `var.peerings` holds VNet **keys** (plain strings `"hub"`, `"spoke1"`); the actual IDs are resolved **in the call** via `module.vnets[each.value.p1]`, sidestepping the "variables can't hold expressions" wall:

```hcl
# root main.tf
module "peerings" {
  source   = "./modules/peering"
  rg_name  = data.azurerm_resource_group.main.name
  for_each = var.peerings                                        # one call per PAIR (hub_and_spoke1, hub_and_spoke2)
  # p1 = peer 1 (in our case hub is always p1); p2 = peer 2 (in our case spokes).
  p1_p2_peering_name = "${local.peering_name}-${each.value.p1}-to-${each.value.p2}"
  p2_p1_peering_name = "${local.peering_name}-${each.value.p2}-to-${each.value.p1}"
  p1_vnet_id         = module.vnets[each.value.p1].vnet_id       # KEY (string) from tfvars -> ID resolved here in root
  p1_vnet_name       = module.vnets[each.value.p1].vnet_name
  # again all these allow & use attributes are optional. look at the variable declared in
  # both the root as well as in the module.
  allow_virtual_network_access_on_p1 = each.value.allow_virtual_network_access_on_p1
  allow_forwarded_traffic_on_p1      = each.value.allow_forwarded_traffic_on_p1
  allow_gateway_transit_on_p1        = each.value.allow_gateway_transit_on_p1
  use_remote_gateways_on_p1          = each.value.use_remote_gateways_on_p1
  p2_vnet_id                         = module.vnets[each.value.p2].vnet_id
  p2_vnet_name                       = module.vnets[each.value.p2].vnet_name
  allow_virtual_network_access_on_p2 = each.value.allow_virtual_network_access_on_p2
  allow_forwarded_traffic_on_p2      = each.value.allow_forwarded_traffic_on_p2
  allow_gateway_transit_on_p2        = each.value.allow_gateway_transit_on_p2
  use_remote_gateways_on_p2          = each.value.use_remote_gateways_on_p2
}
```

> **Design choice — one module per pair, keyed per pair.** Because the module holds both directions, one `for_each` entry (`hub_and_spoke1`) = one call = two resources. That's why there are 2 pairs → 2 calls → 4 `moved` blocks (one per physical resource). The generic `p1`/`p2` naming (rather than `hub`/`spoke`) is deliberate: the module makes no assumption about topology, so it would peer *any* two VNets.

The routing data (`var.routing_tables`) — one table shown; each table nests its own `routes` map (which root dumps into the module wholesale). Routes name their hop *symbolically* via `next_hop_target` (resolved in Ex 7); the full three-table block appears in the Debt sweep. First the **type contract** — note `routes` is `optional(..., {})` so a table can exist with zero routes:

```hcl
# variables.tf  (###---d08ex04)  — schema
variable "routing_tables" {
  type = map(object({ # very similar to peerings
    location                      = string
    bgp_route_propagation_enabled = optional(bool, true)
    owner                         = optional(string, "vg")
    environment                   = optional(string, "lab")
    # here inside each table, we have this routes object which hold
    # a map of object i.e. it can hold multiple routes within.
    # optional makes it so that you can still create a routing table
    # with 0 routes.
    routes = optional(map(object({
      address_prefix  = string
      next_hop_type   = string
      next_hop_target = optional(string, null)   # symbolic hop name; resolved in Ex 7
    })), {})
  }))
}
```

```hcl
# terraform.tfvars  (###---d08ex04)  — truncated to one table
routing_tables = {
  gw = {
    location                      = "westus"
    bgp_route_propagation_enabled = true
    routes = {                                  # this whole object is passed to the module as var.routes
      spoke1 = { address_prefix = "172.22.16.0/20", next_hop_type = "VirtualAppliance", next_hop_target = "hub_fw" }
      spoke2 = { address_prefix = "172.22.32.0/20", next_hop_type = "VirtualAppliance", next_hop_target = "hub_fw" }
    }
  }
  # spoke1 / spoke2 tables follow the same shape (see Debt sweep for all three)
}
```

**Routing** — the module takes the whole `routes` map and iterates it; `next_hop_in_ip_address` uses the Ex 7 `try(...)` lookup (shown here as final code):

```hcl
# modules/routing/main.tf
resource "azurerm_route_table" "rt" {
  name                          = var.rt_name
  resource_group_name           = var.rg_name
  location                      = var.location
  bgp_route_propagation_enabled = var.bgp_route_propagation_enabled
}

resource "azurerm_route" "route" {
  resource_group_name    = var.rg_name
  route_table_name       = azurerm_route_table.rt.name       # internal reference: routes attach to THIS table
  for_each               = var.routes                        # the whole routes map for this table
  name                   = "${var.route_name_prefix}-${each.key}"
  address_prefix         = each.value.address_prefix
  next_hop_type          = each.value.next_hop_type
  next_hop_in_ip_address = try(var.next_hop_ips[each.value.next_hop_target], null)  # see Debt sweep for the full workflow
}
```

The call — **dump the per-table `routes` object into the module**, plus the RT associations as root glue:

```hcl
# root main.tf
module "routing" {
  source  = "./modules/routing"
  rg_name = data.azurerm_resource_group.main.name
  # looping over each routing table.
  # this gives us e.g. "module.routing["gw"].azurerm_route_table.rt"
  for_each                      = var.routing_tables
  rt_name                       = "${local.rt_name}-${each.key}"
  location                      = each.value.location
  bgp_route_propagation_enabled = each.value.bgp_route_propagation_enabled
  route_name_prefix             = "route-${each.value.owner}-${each.value.environment}"
  # dumping the entire routes object to the module.
  # this contains all the routes for this instance of table.
  # look at how the module is handling this: it is iterating over the routes
  # and adding each route from the table.
  # all of this i.e. adding a table & adding the routes for that table
  # happens in one pass of module["routing"].
  routes       = each.value.routes
  next_hop_ips = { hub_fw = local.hub_fw_private_ip }        # symbolic name -> real IP; see Debt sweep
}

# ROOT GLUE x3: each associates a route table (routing module) to a subnet (subnet module)
resource "azurerm_subnet_route_table_association" "gateway_to_rt_gateway" {
  route_table_id = module.routing["gw"].rt_id
  subnet_id      = module.snets_hub_special["GatewaySubnet"].snet_id
}
# spoke1_workload_to_rt_spoke1 / spoke2_workload_to_rt_spoke2 are analogous.
```

> **Design choice — dump the object, iterate inside.** Root passes `each.value.routes` (the entire routes map for that table) as a single argument; the module's `for_each = var.routes` builds the table and every route in **one module pass**. This keeps the root call tiny (one line for all routes) and puts the "how routes attach to a table" logic in one reusable place.

The DNS data (`var.dns`) — one zone shown; the `privatelink.blob.core.windows.net` zone (added in Ex 5) has the same shape. Note the per-link `registration_enabled` (hub registers on the internal zone; spokes only resolve). `vnet_id` is **not** here — it's injected via `local.dns` because a variable can't hold an expression. The **type contract** makes that absence explicit:

```hcl
# variables.tf  (###---d08ex04)  — schema
variable "dns" {
  # very similar to above routing variable.
  # note that this is missing vnet_id attribute inside.
  # vnet_id is built in local.dns
  type = map(object({
    rg_name = optional(string)
    vnet_links = optional(map(object({
      registration_enabled = optional(bool, false)
    })))
  }))
}
```

```hcl
# terraform.tfvars  (###---d08ex04)  — truncated to one zone
dns = {
  "internal.lab.com" = {
    vnet_links = {
      "hub"    = { registration_enabled = true }    # hub registers records
      "spoke1" = { registration_enabled = false }   # spokes resolve only
      "spoke2" = { registration_enabled = false }
    }
  }
  # "privatelink.blob.core.windows.net" = { ... same shape, all registration_enabled = false ... }
}
```

**DNS** — zone + links; `for_each` over the links; a **single module** used for **both zones**:

```hcl
# modules/dns/main.tf
resource "azurerm_private_dns_zone" "dns" {
  resource_group_name = var.rg_name
  name                = var.dns_zone_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_vnet_link" {
  for_each              = var.dns_vnet_links
  name                  = "${var.dns_vnet_link_prefix}-${each.key}"
  resource_group_name   = var.rg_name
  virtual_network_id    = each.value.vnet_id
  registration_enabled  = each.value.registration_enabled   # per-link: hub=true on internal zone, else false
  private_dns_zone_name = azurerm_private_dns_zone.dns.name  # internal reference: links attach to THIS zone
}
```

The call iterates `local.dns` (see the mutate-into-local design choice below):

```hcl
# root main.tf
module "dns" {
  source  = "./modules/dns"
  rg_name = data.azurerm_resource_group.main.name
  # note we are iterating over local.dns cuz var.dns can't hold vnet_id.
  for_each       = local.dns                                # ONE module, iterated over BOTH zones
  dns_zone_name  = each.key                                 # "internal.lab.com" AND "privatelink.blob.core.windows.net"
  dns_vnet_links = each.value.vnet_links
  # link names differ per zone, so pick the prefix per zone with a ternary:
  dns_vnet_link_prefix = each.key == "privatelink.blob.core.windows.net" ? local.vnetlink_name : local.pdnslink_name
}
```

And the `local.dns` that makes it possible — the **mutate-variable-into-local** pattern. `var.dns` holds only the static topology; the local copies it and injects the computed `vnet_id`:

```hcl
# locals.tf  (###---d08ex04)
# the reason for having a local.dns and not using var.dns is
# var.dns doesn't allow expressions i.e. i can't build vnet_id
# using var. that's why here i am essentially copying var.dns
# and adding vnet_id as an additional attribute.
# now my main.tf will loop over local.dns instead of var.dns.
dns = {
  for zone_name, zone in var.dns : zone_name => {           # outer loop: per zone
    vnet_links = {
      for vnet_name, link in zone.vnet_links : vnet_name => {   # inner loop: per link
        registration_enabled = link.registration_enabled    # carried from tfvars
        vnet_id              = module.vnets[vnet_name].vnet_id # INJECTED — the computed value var.dns couldn't hold
      }
    }
  }
}
```

> **Design choice — one DNS module, N zones (the *correct* "one module, N calls").** Unlike the hub-vs-spoke VNets, a private DNS zone + its links genuinely *is* homogeneous across the two zones — same resource shape, same wiring. So a single `for_each` over `local.dns` builds both `internal.lab.com` and `privatelink.blob.core.windows.net`. The only per-zone difference is the **link-name prefix** (`pdnslink-*` vs `vnetlink-*`), handled by the ternary in the call — which is why the two zones don't need separate module calls despite their different link names.

**Locals** (relevant): `local.peering_name` = `peer-vg-lab-wus` — **reused**; `local.rt_name` = `rt-vg-lab-wus` — **reused**; `local.pdnslink_name`, `local.vnetlink_name` — **reused**; `local.dns` — **declared this exercise**.

### Q&A — Topic 3

**Q. Why pass VNet *keys* (not IDs) in `var.peerings`, and resolve the IDs in the module call?**
Because a variable can't hold an expression like `module.vnets["hub"].vnet_id` (that value doesn't exist until the vnet module runs). Strings are fine in tfvars, so the topology stores keys (`p1 = "hub"`) and the call turns each key into an ID via `module.vnets[each.value.p1].vnet_id`. Static intent in data, computed values resolved in root — the same pattern as `local.dns`.

**Q. What does the routing module gain by receiving the whole `routes` map instead of individual route arguments?**
One pass builds the table *and* all its routes, and adding/removing a route is a tfvars change with no new HCL. The module iterates `var.routes` internally, so the root call stays one line regardless of how many routes a table has.

---

## Topic 4 — The coupled cluster & the frozen output contract

### Theory

Some groups are internally coupled — the storage/PE cluster's A-record value *is* the PE's private IP; network rules attach to the storage account; links attach to a zone. Coupling that is **intrinsic** (rules↔account) gets bundled into a module; coupling that is **incidental** (A-record joining zone + PE) stays root glue. And three outputs are a **frozen contract**: `gateway_subnet_id` (Day 6), `firewall_subnet_id` + `storage_pe_private_ip` (Day 7) are read cross-stack and must resolve byte-identical after modularizing.

### Exercise 5 — The storage/PE cluster

**Objective:** extract the cluster — a `storage` module (account + rules), a `private_endpoint` module, **reuse the DNS module** for the privatelink zone, and keep the A-record as root glue; `moved` the 7 relocations.

**Inputs:** `azurerm_storage_account.lab` + `_network_rules.lab_st_rules`; `azurerm_private_endpoint.lab_storage`; `azurerm_private_dns_zone.lab_storage_pe` (`privatelink.blob.core.windows.net`) + 3 links + A record.

**Constraints:** `bypass = ["AzureServices"]` renders verbatim (mg-wondering-packet-all policy); allowed subnet IDs = a `list(string)` input resolved in root; `storage_pe_private_ip` stays `172.22.3.4`.

**Blocks to write:** `modules/storage` (`azurerm_storage_account.st` + `azurerm_storage_account_network_rules.st_rules`), `modules/private_endpoint` (`azurerm_private_endpoint.pe` + `private_service_connection {}`, output `psc_private_ip_address`). Add the privatelink zone as a new entry to `var.dns`/`local.dns` (the existing DNS module picks it up). A-record in root.

**Predict:** 7 moves; A-record + association don't move; `0/0/0`.

**Solution** — try the exercise above before reading on.

Two data notes for this exercise. First, the **storage account has no tfvars** — its config is passed as literals directly in the `module "storage_se"` call (tier/replication/kind/policy), since there's one account. Second, the privatelink zone is added to `var.dns` (same shape as Ex 4's DNS sample), and the PE's allowed traffic + private link ride on data already declared in Ex 2 — the pe subnet and spoke1's service endpoint:

```hcl
# terraform.tfvars  (###---d08ex02)  — the two subnet entries this cluster depends on
snets = {
  hub_special = {
    "pe" = {
      address_prefixes                  = ["172.22.3.0/24"]
      private_endpoint_network_policies = "Enabled"   # PE subnet; NSG applies because policies are Enabled
    }
    # GatewaySubnet / AzureFirewallSubnet omitted here
  }
  spoke1 = {
    "workload" = {
      address_prefixes  = ["172.22.16.0/24"]
      service_endpoints = ["Microsoft.Storage"]       # this subnet is the storage account's allowed VNet subnet
    }
  }
  # ... rest of snets omitted ...
}
```

```hcl
# modules/storage/main.tf   (account + network rules together — intrinsic coupling)
resource "azurerm_storage_account" "st" {
  name                            = var.name
  resource_group_name             = var.rg_name
  location                        = var.location
  account_tier                    = var.account_tier
  account_replication_type        = var.account_replication_type
  account_kind                    = var.account_kind
  allow_nested_items_to_be_public = var.allow_nested_items_to_be_public
  tags                            = var.tags
}

resource "azurerm_storage_account_network_rules" "st_rules" {
  storage_account_id         = azurerm_storage_account.st.id   # internal reference: rules attach to THIS account
  default_action             = var.network_rules_default_action
  bypass                     = var.network_rules_bypass        # ["AzureServices"] — mg-wondering-packet-all policy, kept explicit
  virtual_network_subnet_ids = var.network_rules_allowed_subnet_ids  # a list(string) resolved in root
}
```

```hcl
# modules/private_endpoint/main.tf
resource "azurerm_private_endpoint" "pe" {
  resource_group_name = var.rg_name
  location            = var.location
  subnet_id           = var.subnet_id
  name                = var.name
  private_service_connection {
    name                           = var.psc_name
    private_connection_resource_id = var.psc_private_connection_resource_id
    subresource_names              = var.psc_subresource_names
    is_manual_connection           = var.psc_is_manual_connection
  }
  tags = var.tags
}
```

```hcl
# modules/private_endpoint/outputs.tf
output "psc_private_ip_address" {
  # exact expression from the original working output — relocated verbatim, not re-derived.
  value = azurerm_private_endpoint.pe.private_service_connection[0].private_ip_address
}
```

Root — storage call, PE call, the **reused DNS module call (now iterating both zones)**, and the A-record glue:

```hcl
# root main.tf
module "storage_se" {                                  # "se" = the storage ACCOUNT call
  source                           = "./modules/storage"
  name                             = local.st_lab_name
  rg_name                          = data.azurerm_resource_group.main.name
  location                         = data.azurerm_resource_group.main.location
  account_tier                     = "Standard"
  account_replication_type         = "LRS"
  account_kind                     = "StorageV2"
  allow_nested_items_to_be_public  = false             # explicit security posture (matches original)
  network_rules_default_action     = "Deny"
  network_rules_bypass             = ["AzureServices"]
  network_rules_allowed_subnet_ids = [module.snets_spoke1["workload"].snet_id]  # list resolved in root
  tags                             = local.lab_tags
}

module "storage_pe" {                                  # "pe" = the PRIVATE ENDPOINT call
  source                             = "./modules/private_endpoint"
  name                               = "${local.pe_name}-storage"
  rg_name                            = data.azurerm_resource_group.main.name
  location                           = data.azurerm_resource_group.main.location
  subnet_id                          = module.snets_hub_special["pe"].snet_id
  psc_name                           = "psc-${local.prefix}-storage"
  psc_private_connection_resource_id = module.storage_se.id   # PE connects to the storage account
  psc_subresource_names              = ["blob"]
  psc_is_manual_connection           = false
}

# SAME dns module as Ex 4 — the privatelink zone was added as a second entry in var.dns/local.dns,
# so this one for_each call now builds BOTH internal.lab.com AND privatelink.blob.core.windows.net.
# (No separate "dns2" block exists — reuse via for_each is the whole point.)
module "dns" {
  source               = "./modules/dns"
  rg_name              = data.azurerm_resource_group.main.name
  for_each             = local.dns                     # now has 2 zones
  dns_zone_name        = each.key
  dns_vnet_links       = each.value.vnet_links
  dns_vnet_link_prefix = each.key == "privatelink.blob.core.windows.net" ? local.vnetlink_name : local.pdnslink_name
}

# ROOT GLUE: A-record joins the DNS module (zone name) + the PE module (private IP)
resource "azurerm_private_dns_a_record" "lab_storage_pe" {
  name                = local.st_lab_name
  resource_group_name = data.azurerm_resource_group.main.name
  zone_name           = module.dns["privatelink.blob.core.windows.net"].private_dns_zone_name
  records             = [module.storage_pe.psc_private_ip_address]
  ttl                 = 300
}
```

> **One design note (kept brief).** The two DNS zones give their links different name prefixes (`pdnslink-*` on the internal zone, `vnetlink-*` on the privatelink zone). Since a single module call can only carry one prefix per zone, the prefix is chosen per zone by the `dns_vnet_link_prefix` ternary — that's why one reused module handles both zones without a second call.

**Locals** (relevant): `local.st_lab_name` = `stvglabwus01` — **reused**; `local.pe_name` = `pe-vg-lab-wus` — **reused**; `local.prefix` = `vg-lab-wus` — **reused**.

### Exercise 6 — Re-plumb outputs + verify the frozen contract

**Objective:** confirm the three consumed outputs resolve unchanged; reconcile output redundancy.

**Constraints:** `gateway_subnet_id`, `firewall_subnet_id`, `storage_pe_private_ip` must resolve identically; collapse only outputs you can show are unconsumed *within reach*.

**Predict:** removing outputs shows under "Changes to Outputs", not resource actions — resource plan stays `0/0/0`.

**Solution** — verification, not new code.

```powershell
terraform output -json > outputs-now.json   # confirm the frozen NAMES exist and the IDs are self-consistent
```

Prove the three consumed outputs still resolve by exercising the consumers' source (the destroyed day06/day07 stacks still have their `.tf`): running `terraform plan` in each folder resolves the `terraform_remote_state` reads and prints the values inline (`.../GatewaySubnet`, `.../AzureFirewallSubnet`, `172.22.3.4`). A consumer re-resolving against the present *is* the contract proof — no saved snapshot needed.

**On finding consumers — an honest limitation.** You can grep *your own repos* for who reads the base:

```powershell
Select-String -Path .\day06-vpn-gateway\*.tf, .\day07-firewall\*.tf -Pattern "outputs\."
# -> exactly: gateway_subnet_id, firewall_subnet_id, storage_pe_private_ip
```

But this only covers code **on your machine**. In a real org, multiple teams and separate repos may consume the same base via `terraform_remote_state`, and you cannot see their references from here. So treat a local grep as *evidence for the repos you control*, not proof of global non-consumption. Where the master plan or a known team owns a future read (Day 9 reads `hub_subnet_ids["shared"]`/`["agw"]`), honor that even without a current reference.

**Reconciliation decision (scoped to what's known here).** The redundant scalars `agw_subnet_id`, `dns_inbound_subnet_id`, `dns_outbound_subnet_id` duplicate `hub_subnet_ids` map entries and have no consumer in the repos you control or in the master plan. Rule adopted: **standalone/special subnets get scalar outputs; for_each subnets are exposed only via `hub_subnet_ids`.** Drop the three redundant scalars; keep `gateway`/`firewall`/`pe` (standalone) and the map. Day 9 reads the map.

**Locals** (relevant): none; verification exercise.

### Q&A — Topic 4

**Q. Day 9 reads `shared_subnet_id`/`agw_subnet_id` via remote state. Why does the refactor not change those values, and how do you prove it?**
Subnet IDs are immutable unless the subnet is replaced, which the zero-change gate forbids; modularizing moves only the *state address*, not the resource, so the ID string is untouched. Prove it with `terraform output -json` — the ID contains the subnet name, so it's self-verifying — and confirm the map keys Day 9 will read exist (`hub_subnet_ids["shared"]`, `["agw"]`).

---

## Topic 5 — Debt sweep

### Theory

Cleanup is a first-class deliverable. Three items: promote a hardcoded cross-stack IP to one named local, reconcile redundant outputs (done in Ex 6), and retire the `moved` scaffolding. The interesting one is the firewall IP, because it shows the full **symbolic-target → resolution-map** workflow that keeps a cross-stack fact in exactly one place.

### Exercise 7 — Debt sweep (firewall IP + scaffolding)

**Objective:** promote `172.22.1.4` to `local.hub_fw_private_ip`; delete stale/commented blocks; retire `moved.tf`. Each verified `0/0/0`.

**The full firewall-IP workflow — where every piece comes from.** Three files cooperate:

**(1) tfvars — each route names its next hop *symbolically*.** The routes don't hardcode `172.22.1.4`; they carry a **target name** (`next_hop_target = "hub_fw"`). This is the origin of `each.value.next_hop_target` you see in the module:

```hcl
# terraform.tfvars  (###---d08ex04)  — routing_tables -> per table -> routes
routing_tables = {
  gw = {
    location                      = "westus"
    bgp_route_propagation_enabled = true
    routes = {
      spoke1 = { address_prefix = "172.22.16.0/20", next_hop_type = "VirtualAppliance", next_hop_target = "hub_fw" }
      spoke2 = { address_prefix = "172.22.32.0/20", next_hop_type = "VirtualAppliance", next_hop_target = "hub_fw" }
    }
  }
  spoke1 = {
    location = "westus", bgp_route_propagation_enabled = false
    routes = {
      default = { address_prefix = "0.0.0.0/0",     next_hop_type = "VirtualAppliance", next_hop_target = "hub_fw" }
      pe      = { address_prefix = "172.22.3.0/24",  next_hop_type = "VirtualAppliance", next_hop_target = "hub_fw" }
    }
  }
  spoke2 = {
    location = "westus", bgp_route_propagation_enabled = false
    routes = {
      default = { address_prefix = "0.0.0.0/0",     next_hop_type = "VirtualAppliance", next_hop_target = "hub_fw" }
    }
  }
}
```

**(2) locals + call — the one true IP, and the name→IP map.** The IP lives once; the call hands the module a lookup table mapping the symbolic name to it:

```hcl
# locals.tf  (###---d08ex07)
hub_fw_private_ip = "172.22.1.4"   # single source of truth for the firewall's private IP (a cross-stack fact)
```
```hcl
# root main.tf — inside module "routing"
next_hop_ips = { hub_fw = local.hub_fw_private_ip }   # maps the symbolic target "hub_fw" -> the real IP
```

**(3) module — resolve the symbol to an IP, null-safe.** The module looks up the route's target in the map:

```hcl
# modules/routing/main.tf — inside azurerm_route.route
# try() returns the first expression that doesn't error, else the fallback.
# non-firewall routes have no next_hop_target (it's null) -> indexing with a null/absent key would THROW,
# so try(...) collapses "no target", "null target", and "missing key" all to null cleanly.
next_hop_in_ip_address = try(var.next_hop_ips[each.value.next_hop_target], null)
```

**Flow, end to end:** tfvars route says `next_hop_target = "hub_fw"` → module reads `each.value.next_hop_target` (`"hub_fw"`) → looks it up in `var.next_hop_ips` (which root built as `{ hub_fw = local.hub_fw_private_ip }`) → resolves to `172.22.1.4`. Change the firewall's IP once in the local and all five routes follow.

**Predict / verify:** steady state `0/0/0`. To prove the local actually feeds the routes, flip `local.hub_fw_private_ip` to a bogus value and plan — the firewall routes should show `~ next_hop_in_ip_address`. (On `azurerm_route` a broken/absent resolution shows as `... -> null` in the plan, i.e. it is *visible*, not silently absorbed by state — so the restored `0/0/0` genuinely confirms all five resolve.) Restore after.

**Retire scaffolding:** delete the three redundant scalar outputs (Ex 6), remove any commented ternary in the routing module, and retire the 42 `moved` blocks as one batch (every extraction applied and confirmed, so they're inert). Final full `terraform plan` = **No changes**.

> **`moved.tf` in this lab** was kept (fully commented) as a study reference rather than deleted. Note the risk for a fresh clone/capstone: uncommenting re-arms 42 stale moves. Prefer archiving out of `.tf` (rename `moved.tf.reference`) so it can't be re-armed.

**Locals** (relevant): `local.hub_fw_private_ip` = `172.22.1.4` — **declared this exercise**.

### Q&A — Topic 5

**Q. Why keep `172.22.1.4` as one local and resolve it in root, instead of teaching the routing module the firewall's address?**
Because the IP is a fact owned by the *firewall* stack — one local means a firewall move is a one-line change, not five tfvars edits. Resolution stays in root so the module stays generic: it receives a `{name → ip}` map and does a `try` lookup, never learning what a firewall is. Teaching the module a specific cross-stack address would couple it to your topology — the opposite of what modules are for.

---

## Design challenge

### The challenge

1. You move `azurerm_subnet.hub["web"]` into a subnet module. What's its new address, what must the `moved` block say, and what happens to the `["web"]` index? Harder: `hub_gateway`/`hub_azurefirewall`/`hub_pe` are standalone (not in the for_each) — do they move into the same module, and how do their `moved` blocks differ?
2. Days 6 and 7 read `gateway_subnet_id`, `firewall_subnet_id`, `storage_pe_private_ip` via `terraform_remote_state`. After modularizing, those are sourced from `module.*.`. How do you guarantee the contract is unchanged, and what would the Day-7 firewall stack see on its next plan if you accidentally renamed `firewall_subnet_id`?
3. You use local-path modules (`source = "./modules/..."`). In a real multi-repo org that breaks — why? What do git-ref or private-registry sources with pinned versions buy you, and how does that interact with the "one evolving module set vs frozen-per-environment" decision?

### The resolution

1. New address: `module.snets_hub["web"].azurerm_subnet.snet`. The block: `from = azurerm_subnet.hub["web"]`, `to = module.snets_hub["web"].azurerm_subnet.snet` — the `["web"]` appears on **both** sides and maps through unchanged. The standalones move into the *same* `modules/subnet` code but a **different call** (`snets_hub_special`, keyed by their own names), because they diverge on naming/policy. Their `moved` blocks differ in having no index on the `from` side: `from = azurerm_subnet.hub_gateway`, `to = module.snets_hub_special["GatewaySubnet"].azurerm_subnet.snet` — a plain source address mapping to an *indexed* module destination.
2. Guarantee it by re-sourcing each root output from `module.*.` while keeping the **name and value** identical, then verifying: `terraform output -json` (names present, IDs self-consistent) and running `plan` in the consumer folders (the read resolves or errors). If you renamed `firewall_subnet_id`, the firewall stack's `data.terraform_remote_state.base.outputs.firewall_subnet_id` would resolve to **null**, and its next plan would fail (null `subnet_id` on the firewall's `ip_configuration`) — a break with no signal on *your* side until the consumer runs. **Names are the contract.**
3. Local paths assume every consumer sits in the same working tree — false across repos. A git-ref or private-registry source with a **pinned version** (`?ref=v1.2.0`) lets independent repos consume a module reproducibly and lets you evolve it without breaking pinned callers. That's the "frozen-per-environment" side: prod pins `v1.2.0` while dev tracks `v1.3.0`, so a module change rolls out deliberately. **What this reveals:** the module interface is a *stability contract*. Refactoring live infra safely (zero-change gate + `moved`) and versioning modules across environments (pinned sources) are the same discipline at two scales — freeze the surface others depend on, change the inside behind it.

---

## Corrections & gotchas

Troubleshooting encountered this day — the failing form, the fix, and whether it's a universal rule or a lab-specific observation. These are the expressions/blocks that actually had to change.

| # | Symptom | Failing form → fix | Scope |
|---|---|---|---|
| 1 | Green plan hides a dropped attribute | Omitting `private_endpoint_network_policies` gave `0/0/0` because it's Optional+Computed and state held `"Enabled"`; a fresh apply would revert to the default. **Fix:** expose it as an input and set `"Enabled"` explicitly for pe. **Prove flow-through with a flip-test.** | Universal |
| 2 | Reaching into a module from an expression | `module.vnets["hub"].azurerm_virtual_network.vnet.name` (illegal) → declare an `output "vnet_name"` and read `module.vnets["hub"].vnet_name`. Resource addresses are legal only in `moved`/`import`. | Universal |
| 3 | `contains` throws | `contains(["Deny","Allow"])` (missing the value arg — hard error) → `contains(["Deny","Allow"], var.network_rules_default_action)`. | Universal |
| 4 | "Reference to undeclared resource" after extraction | `outputs.tf` still points at `azurerm_*.lab*` after the resources moved into modules → re-point every output to `module.*.` (e.g. `module.storage_pe.pe_id`). | Universal |
| 5 | Extraction plans destroy-and-recreate | Missing `moved` blocks (would recreate the storage account — data loss) → one `moved` per relocated physical resource before `apply`. | Universal |
| 6 | `lookup` errors on a null key | `lookup(var.next_hop_ips, each.value.next_hop_target, null)` throws when `next_hop_target` is null (non-firewall routes) → `try(var.next_hop_ips[each.value.next_hop_target], null)`. `try` because the data is non-uniform. | Universal |
| 7 | Reused DNS module renamed live links | One prefix for two zones renamed the privatelink links (`vnetlink-* -> pdnslink-*`, ForceNew) → pass the prefix per zone: `each.key == "privatelink..." ? local.vnetlink_name : local.pdnslink_name`. | Observed (this base) → universal principle: per-caller-varying values must be inputs |
| 8 | Plan on a `moved`/shared-state change | Bare `plan`/`apply` has a drift window → `terraform plan -out=tfplan` then `terraform apply tfplan` so the applied move is the reviewed move. Matters most on shared state (Day 10 pipeline). | Universal |
| 9 | `moved.tf` kept commented in live `.tf` | Study-reference choice; risk that uncommenting re-arms 42 stale moves at capstone → rename to `moved.tf.reference`/non-`.tf`. | Lab decision (flagged) |

> **Through-line:** several times a green plan hid a regression that only a deliberate check surfaced (the dropped pe policy, a `tags` no-op on subnets, the link rename). A zero-change plan proves identical infra against *current state*; the **capstone rebuild from zero** is the real test — audit every Optional+Computed attribute before that apply.