# Day 1 — Terraform HCL Deep Dive

> **Prerequisite:** Day 0 intro (concepts, workflow, state, HCL syntax, type system basics, the variables.tf ↔ terraform.tfvars matching contract). This doc assumes all of that and drills the applied depth with exercises, Q&A, and corrections.
>
> **What Day 1 covers:** input variables, outputs, locals, `for_each` vs `count`, data sources, and meta-arguments/lifecycle — the six building blocks of every real Terraform config.
>
> **What Day 2 builds on this:** Day 2 takes the parameterized config built here and moves its state to a remote Azure Storage backend with locking and workspaces. The variables, locals, and resource patterns from Day 1 stay; only where state lives changes.

**Standard lab environment** (identical across all days — mirrors the Azure CLI labs):

| Setting | Value |
|---|---|
| Subscription | `<your-subscription-id>` |
| Region | `westus` · RG `rg-vg-lab-wus-01` |
| Naming | `<resource-type>-vg-lab-wus-<purpose>` |
| Supernet | `172.22.0.0/16` · Hub `172.22.0.0/20` · Spoke1 `172.22.16.0/20` · Spoke2 `172.22.32.0/20` |

---

## Table of Contents

1. [What is a Terraform Module?](#what-is-a-terraform-module)
2. [Topic 1 — Input Variables](#topic-1--input-variables)
3. [Topic 2 — Outputs](#topic-2--outputs)
4. [Topic 3 — Locals](#topic-3--locals)
5. [Topic 4 — for_each vs count](#topic-4--for_each-vs-count)
6. [Topic 5 — Data Sources](#topic-5--data-sources)
7. [Topic 6 — Meta-arguments & lifecycle](#topic-6--meta-arguments--lifecycle)
8. [Design Challenge — Hub-Spoke Module Interface](#design-challenge--hub-spoke-module-interface)
9. [Corrections & Gotchas](#corrections--gotchas)
10. [Quick Reference](#quick-reference)
11. [Running the Lab — init, plan & apply](#running-the-lab--init-plan--apply)

> Type system basics, the variables/tfvars matching contract, remote state, and the full command/IP reference live in the Day 0 intro. This doc doesn't repeat them.

---

## What is a Terraform Module?

A module is just a folder of `.tf` files with a defined input/output interface. Any directory with Terraform files is technically a module. The distinction:

- **Root module** — the directory you run `terraform apply` from directly.
- **Child module** — a reusable folder called by another config using a `module` block.

`variables.tf` defines the inputs, `outputs.tf` defines the return values, and the resource blocks inside are the body. The caller doesn't care how it works internally — only what it accepts and returns. Every exercise in Day 1 is building toward that contract; Day 8 turns it into actual reusable modules.

### Example — calling a child module

```
azure-terraform-labs/
├── main.tf              ← root module (calls the child)
├── terraform.tfvars
└── modules/
    └── vnet/
        ├── variables.tf ← child module inputs
        ├── outputs.tf   ← child module outputs
        ├── main.tf      ← resource blocks
        └── locals.tf
```

Root `main.tf` calling the child:

```hcl
module "hub_vnet" {
  source = "./modules/vnet"          # path to the child module folder

  vnet_name     = "vnet-vg-lab-wus-hub"
  address_space = ["172.22.0.0/20"]
  location      = "westus"

  subnets = {
    web = { cidr = "172.22.10.0/24", has_nsg = true,  service_endpoints = [] }
    app = { cidr = "172.22.11.0/24", has_nsg = true,  service_endpoints = [] }
    db  = { cidr = "172.22.12.0/24", has_nsg = false, service_endpoints = [] }
  }
}

output "hub_vnet_id" {
  value = module.hub_vnet.vnet_id    # references output defined in child's outputs.tf
}
```

The child has no idea it's being called — it just sees its variables populated.

---

## Topic 1 — Input Variables

### Theory

Variables are the external interface of a module. Callers set them — the module can't control what's passed in. Use them for anything that changes between environments or callers. (Type system basics and the variables.tf ↔ terraform.tfvars matching contract are in Day 0 — this topic focuses on validation and `optional()`.)

**Validation block**

```hcl
variable "address_space" {
  type = list(string)
  validation {
    # alltrue() — passes only if every element evaluates to true
    # can()     — returns true/false instead of throwing an error
    # regex()   — throws on no match, so must be wrapped in can()
    # "^172\\." — ^ anchors to start, \\. escapes the dot (HCL needs \\ to produce \)
    condition     = alltrue([for cidr in var.address_space : can(regex("^172\\.", cidr))])
    error_message = "All CIDRs must start with 172."
  }
}
```

**optional() inside object types**

```hcl
type = map(object({
  cidr              = string
  has_nsg           = bool
  service_endpoints = optional(list(string), [])  # omitting this field → [] not null
}))
```

`optional(type)` with no default → `null`. Always specify a default for list/map optionals to avoid `null` propagation errors downstream.

---

### Exercise 1 — variables.tf

**Context:** Before writing any resources, define what inputs the module accepts — its contract with the caller. This file alone defines every value the module depends on from outside. The `subnets` variable defined here feeds directly into Exercise 4a's `for_each` resource blocks.

**What this exercise covers:**
- Declaring variables of different types: `string`, `list(string)`, `map(object(...))`, `map(string)`
- Setting a default on `location` so callers can omit it
- Writing a validation block to reject invalid CIDRs at plan time rather than at the Azure API
- Using `optional()` inside an object type so `service_endpoints` needn't be specified for every subnet

**What to write:** A `variables.tf` declaring:
- `vnet_name` — string, no default (required)
- `address_space` — list of strings with a validation block rejecting anything not starting with `"172."`
- `location` — string, default `"westus"`
- `subnets` — map of objects, each with `cidr` (string), `has_nsg` (bool), `service_endpoints` (optional list of strings, default `[]`)
- `tags` — map of strings, default empty map
- `owner` and `environment` — strings, no default (required; feed the naming chain in Exercise 3)
- `vnet_address_space` — `map(object({ address_space = list(string) }))` — holds hub/spoke CIDRs consumed by the resource blocks in Exercises 5 and 6

> **Lab note:** `vnet_name` and `address_space` are module-interface variables included to practice the type system and validation syntax. They are not consumed by any resource block in this lab — `local.vnet_name` (derived from the naming chain in `locals.tf`) is used for resource naming instead. Both are populated in `terraform.tfvars` to satisfy the required-variable contract and prevent Terraform from prompting interactively at plan time.

**Final solution — `variables.tf`:**

```hcl
###---exercise 1---###
variable "vnet_name" {
  type = string
}

variable "address_space" {
  type = list(string)
  validation {
    # can(regex(...)) returns false on no match instead of throwing an error
    # "^172\\." = starts with "172." — \\. escapes the dot for the regex engine
    condition     = alltrue([for cidr in var.address_space : can(regex("^172\\.", cidr))])
    error_message = "All CIDRs must start with 172."
  }
}

variable "location" {
  type    = string
  default = "westus"
}

variable "subnets" { ## used in ex 4a
  # map(object) — each key is a subnet name, value is a structured object
  # service_endpoints is optional — caller can omit it; Terraform fills in [] automatically
  type = map(object({
    cidr              = string
    has_nsg           = bool
    service_endpoints = optional(list(string), [])
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}

##---end - ex1###
## additional variables to build naming chain (used in locals.tf ex3):

variable "owner" {
  type = string
}

variable "environment" {
  type = string
}

## vnet_address_space drives address_space for hub/spoke VNet resources in ex5 and ex6:
variable "vnet_address_space" {
  type = map(object({
    address_space = list(string)
  }))
}
```

---

### Q&A — Topic 1

**Q: Variable defined in `variables.tf` with a default, also set in `terraform.tfvars`, also passed with `-var`. Which wins?**

`-var` wins. Precedence: default → tfvars → auto.tfvars → TF_VAR_ → `-var`. The CLI flag always wins.

**Q: When would you use `type = any` and when is it a bad idea?**

Use `any` in wrapper modules that pass values straight through to child modules without inspecting them. Bad idea in any shared module — it removes the type contract, so callers can pass anything and errors surface late (at apply or provider validation) rather than at plan time.

---

## Topic 2 — Outputs

### Theory

Outputs surface values from a config — either for humans in the terminal or for other modules to consume programmatically.

**Block structure**

```hcl
output "vnet_id" {
  value       = azurerm_virtual_network.hub.id  # what to expose
  description = "Resource ID of the hub VNet"   # always include — documents the output
  sensitive   = true                            # suppresses terminal display
}
```

**Timing**

- Outputs resolve at **apply time**, not plan time.
- During `terraform plan`, outputs depending on not-yet-created resources show `(known after apply)`.

**sensitive = true on outputs**

- Hides value in terminal — `terraform output` shows `<sensitive>`.
- To read the actual value: `terraform output -raw <name>` or `terraform output -json`.
- Does **not** hide the value in `terraform.tfstate` — it's plaintext there. State-level protection is RBAC on the backend, not this flag.

**for expressions in outputs**

When a resource uses `for_each`, Terraform creates a map of instances keyed by `each.key`. Use a for expression to transform it:

```hcl
output "subnet_ids" {
  # k = subnet name, v = full resource object — v.id drills into the ID attribute
  value = { for k, v in azurerm_subnet.hub : k => v.id }
}
```

---

### Exercise 2 — outputs.tf

**Context:** Surface the IDs and CIDRs of the hub VNet and its subnets — for operators to verify the deployment and for future modules to consume. The resources referenced here (`azurerm_virtual_network.hub`, `azurerm_subnet.hub`) are declared in Exercises 6 and 4a respectively; outputs simply reference them by name.

**What this exercise covers:**
- Basic output syntax with `value`, `description`, `sensitive`
- A for expression to build a map from `for_each` resource instances
- Indexing into a list (`address_space[0]`) to surface a single value

**What to write:** An `outputs.tf` surfacing:
- The VNet resource ID — marked `sensitive` for practice
- A map of subnet name → subnet ID (for expression over `azurerm_subnet.hub`)
- The full VNet address space as a list
- The first (primary) address prefix as a single string

**Final solution — `outputs.tf`:**

```hcl
###---exercise 2---###
output "vnet_id" {
  value       = azurerm_virtual_network.hub.id
  description = "Resource ID of the hub VNet"
  sensitive   = true  # terminal shows (sensitive value) — use terraform output -raw vnet_id to read
}

output "subnet_ids" {
  # azurerm_subnet.hub is a map of instances keyed by subnet name (set by for_each in ex04)
  # this expression transforms that map into name → ID pairs
  value       = { for k, v in azurerm_subnet.hub : k => v.id }
  description = "Map of subnet name to subnet resource ID"
}

output "vnet_address_space" {
  # address_space is a list — returns all CIDRs e.g. ["172.22.0.0/20"]
  value       = azurerm_virtual_network.hub.address_space
  description = "Full address space owned by hub vnet"
}

output "vnet_primary_cidr" {
  # [0] indexes the first element — returns the primary CIDR block as a single string
  value = azurerm_virtual_network.hub.address_space[0]
}
###--end-ex2--##
```

---

### Q&A — Topic 2

**Q: A teammate runs `terraform output` on a sensitive output. What do they see? How do they get the actual value?**

They see `<sensitive>`. To get the value: `terraform output -raw vnet_id` for plain text, or `terraform output -json` to dump all outputs including sensitive ones as JSON.

**Q: An output references a resource just created by this apply. During `terraform plan`, what does the output show?**

`(known after apply)` — it can't resolve until the resource exists. Resolves at apply time once the ID is available from Azure.

---

## Topic 3 — Locals

### Theory

Locals hold internal computed values. They are not part of the module's external interface — callers can't set them.

**locals vs variables**

| | Variables | Locals |
|---|---|---|
| Set by | External caller | Internal to config |
| Purpose | External interface / inputs | Internal computed / derived values |

**Why locals over variables for naming conventions:** a variable is part of the interface — callers can override it and break your naming standard. A local is internal — the module enforces it regardless of what the caller passes.

**sensitive values in locals**

A local computed from a sensitive input inherits sensitivity — Terraform will error if you try to output it without marking the output `sensitive = true`. The `sensitive = true` flag (on variables and outputs) suppresses terminal/plan display but never encrypts the value in state.

**Common patterns**

```hcl
locals {
  # Ternary conditional — condition ? value_if_true : value_if_false
  region_code = var.location == "westus" ? "wus" : "eus"

  # Locals referencing other locals — valid, no ordering needed
  prefix    = "${var.owner}-${var.environment}-${local.region_code}"
  vnet_name = "vnet-${local.prefix}"
  rg_name   = "rg-${local.prefix}"

  # Merge maps — last map wins on key conflicts
  all_tags = merge(var.tags, local.common_tags)
}
```

Reference locals with `local.<name>` (singular, not `locals`).

**cidrsubnet()**

```hcl
cidrsubnet(base_cidr, newbits, netnum)
# newbits = bits to add to the prefix length
# netnum  = which subnet, 0-indexed
```

The lab uses the hub VNet `172.22.0.0/20` as the base. Adding `newbits = 4` produces `/24` subnets (`/20 + 4 = /24`). `netnum` maps to the third-octet value within the hub range:

```hcl
cidrsubnet("172.22.0.0/20", 4, 7)   # → 172.22.7.0/24   (mgmt)
cidrsubnet("172.22.0.0/20", 4, 10)  # → 172.22.10.0/24  (web)
cidrsubnet("172.22.0.0/20", 4, 11)  # → 172.22.11.0/24  (app)
cidrsubnet("172.22.0.0/20", 4, 12)  # → 172.22.12.0/24  (db)
```

Using the hub `/20` as the base (rather than the supernet `/16`) is more precise — it constrains computed subnets to the hub's allocated block and prevents accidental overlap with spoke ranges.

---

### Exercise 3 — locals.tf

**Context:** Instead of hardcoding names and CIDRs across dozens of resource blocks, compute them once here and reference `local.*` everywhere else. DRY applied to infrastructure — one change here propagates everywhere. The naming chain built in this exercise (`local.vnet_name`, `local.nsg_name`, etc.) is consumed directly by the resource blocks in Exercises 4, 5, and 6, and is reused every day of the program.

**What this exercise covers:**
- `cidrsubnet()` to compute subnet CIDRs from the hub base CIDR
- A common tags map built from variable inputs
- Ternary conditional for environment-aware values
- Locals referencing other locals to build a naming chain

**What to write:** A `locals.tf` computing:
- A `subnet_map_hub` using `cidrsubnet()` for mgmt, web, app, db — scoped to the hub `/20`
- A `common_tags` map with `environment`, `managed_by`, `owner`, `region`
- A `region_code` ternary: `"wus"` if westus, else `"eus"`
- A naming chain: `prefix` → `vnet_name`, `rg_name`, `nsg_name`

> **Lab note:** `subnet_map_hub` is computed here as a locals exercise but is not directly consumed by any resource block in this lab — the subnet CIDRs are instead supplied via `var.subnets` in `terraform.tfvars`. The value of defining them here is to practice `cidrsubnet()` and demonstrate that locals can precompute any derived data, not just naming. In a production module, you'd drive subnet creation from `local.subnet_map_hub` rather than a variable, keeping all CIDRs in one place.

**Final solution — `locals.tf`:**

```hcl
###---exercise 3---###
## alternatively we could have pulled the subnets from variables as well
## but the exercise wants us to manually define them here.
locals {
  # cidrsubnet: hub base /20 + 4 newbits = /24 subnets
  # netnum maps to the third octet value within the hub range
  subnet_map_hub = {
    mgmt = cidrsubnet("172.22.0.0/20", 4, 7)   # → 172.22.7.0/24
    web  = cidrsubnet("172.22.0.0/20", 4, 10)  # → 172.22.10.0/24
    app  = cidrsubnet("172.22.0.0/20", 4, 11)  # → 172.22.11.0/24
    db   = cidrsubnet("172.22.0.0/20", 4, 12)  # → 172.22.12.0/24
  }

  common_tags = {
    environment = "lab"
    managed_by  = "terraform"
    owner       = "vg"       # optional to build the naming chain
    region      = var.location  # pulled from variable so it stays accurate per deployment
  }

  # Ternary: condition ? value_if_true : value_if_false
  region_code = var.location == "westus" ? "wus" : "eus"

  # Naming chain — each local builds on the previous one
  # local.vnet_name → used in ex05 and ex06 resource name attributes
  # local.nsg_name  → used in ex04 NSG resource name attribute
  # local.rg_name   → available but not consumed directly; RG name is read from the data source in ex05
  prefix    = "${var.owner}-${var.environment}-${local.region_code}"
  vnet_name = "vnet-${local.prefix}"
  rg_name   = "rg-${local.prefix}"
  nsg_name  = "nsg-${local.prefix}"
}
###--end---ex3--###
```

---

### Q&A — Topic 3

**Q: Can a local reference another local defined in the same locals block?**

Yes. No ordering constraint. Terraform builds an internal dependency graph and resolves them in the correct order regardless of declaration order.

**Q: A teammate says "just use a variable with a default for the naming prefix." Why is a local more appropriate?**

A variable is part of the external interface — callers can override it. If the naming convention is a variable, any caller can pass a different value and silently break the standard. A local is internal — the module owns and enforces it unconditionally.

---

## Topic 4 — for_each vs count

### Theory

**count — index-based**

```hcl
resource "azurerm_subnet" "main" {
  count = 3
  name  = "subnet-${count.index}"  # count.index = 0, 1, 2
}
# State references: azurerm_subnet.main[0], [1], [2]
```

**The cascade problem with count:** remove index 1 from a list of 3. Terraform renumbers — `[2]` becomes `[1]`. Plan output:

```
# azurerm_subnet.main[1]  will be destroyed   ← the one you removed
# azurerm_subnet.main[2]  will be destroyed   ← collateral damage — renumbered
# azurerm_subnet.main[1]  will be created     ← [2] recreated as [1]
```

Index 2 is destroyed and recreated even though you never touched it. In production that subnet may have VMs, NSGs, and route tables — all disrupted by a renumber.

**for_each — key-based**

```hcl
resource "azurerm_subnet" "main" {
  for_each = var.subnets
  name     = each.key
}
# State references: azurerm_subnet.main["web"], ["app"], ["db"]
```

Removing `"app"` from the map only touches `azurerm_subnet.main["app"]` — nothing else moves.

**toset()**

`for_each` requires a map or set — not a plain list. Lists allow duplicates; if two entries had the same value, two resources would share an identical map key. `toset()` deduplicates and converts:

```hcl
for_each = toset(["web", "app", "db"])
```

With `toset()`: `each.key == each.value` — both are the string itself. With a map: `each.key` = map key, `each.value` = full value object.

**Filtering a map inline**

```hcl
# has_nsg is already a bool — if v.has_nsg is sufficient, no == true needed
for_each = { for k, v in var.subnets : k => v if v.has_nsg }
```

**for expressions — how k and v work**

```hcl
{ for k, v in var.subnets : k => v.cidr }
```

| k     | v (full object)                               | v.cidr           |
|-------|-----------------------------------------------|------------------|
| `web` | `{ cidr = "172.22.10.0/24", has_nsg = true }`  | `172.22.10.0/24` |
| `app` | `{ cidr = "172.22.11.0/24", has_nsg = true }`  | `172.22.11.0/24` |
| `db`  | `{ cidr = "172.22.12.0/24", has_nsg = false }` | `172.22.12.0/24` |

Result: `{ web = "172.22.10.0/24", app = "172.22.11.0/24", db = "172.22.12.0/24" }`

---

### Exercise 4a — subnet + NSG resources with for_each

**Context:** The `subnets` variable (populated in Exercise 4b via `terraform.tfvars`) drives two resources here: one subnet per map entry, and NSGs only for subnets where `has_nsg = true`. The decision is data-driven — add or remove a subnet in `tfvars` and the resources follow automatically, no code changes needed.

The subnet resource references `data.azurerm_resource_group.main` (declared in Exercise 5) and `azurerm_virtual_network.hub` (declared in Exercise 6). Terraform resolves these cross-file dependencies automatically — file order doesn't matter, only the dependency graph does. The NSG name is built from `local.nsg_name` defined in Exercise 3.

**What this exercise covers:**
- `for_each` over a map variable to create multiple resources from one block
- `each.key` and `each.value` inside a resource block
- Inline map filtering with a `for` expression to conditionally create resources
- Using data source attributes for RG/VNet references and locals for naming

**Final solution — `ex04-foreach.tf`:**

```hcl
# Exercise 4a — for_each: subnets + conditional NSGs
# exercise 4b is in terraform.tfvars file

resource "azurerm_subnet" "hub" {
  ## resource_group_name and virtual_network_name reference the data source and resource
  ## declared in ex05 and ex06 respectively — Terraform resolves cross-file dependencies automatically
  resource_group_name  = data.azurerm_resource_group.main.name  # data source from ex05
  virtual_network_name = azurerm_virtual_network.hub.name       # resource from ex06

  for_each         = var.subnets       # iterates over every entry in the subnets map
  name             = each.key          # map key becomes the subnet name e.g. "web"
  address_prefixes = [each.value.cidr] # each.value is the full object; .cidr drills in
}

resource "azurerm_network_security_group" "main" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location

  # has_nsg is already a bool — if v.has_nsg is sufficient, no == true needed
  # only web and app pass this filter; db and mgmt are excluded
  for_each = { for k, v in var.subnets : k => v if v.has_nsg }

  name = "${local.nsg_name}-${each.key}"  # e.g. "nsg-vg-lab-wus-web"
}
```

---

### Exercise 4b — terraform.tfvars for the subnets variable

**Context:** The `subnets` variable expects `map(object({cidr, has_nsg, service_endpoints}))`. Populate it with the lab's hub subnets. The `service_endpoints` field is declared `optional` in `variables.tf` — omit it for subnets that don't need it and Terraform fills in `[]` automatically. This file is what the Exercise 4a resource blocks iterate over.

**Final solution — relevant section of `terraform.tfvars`:**

```hcl
###--start- used in ex 4b
subnets = { ## used in ex 4a — var.subnets pulls this value
  "web" = {
    cidr    = "172.22.10.0/24"
    has_nsg = true
    # service_endpoints omitted — declared optional() in variables.tf, defaults to []
  }
  "app" = {
    cidr    = "172.22.11.0/24"
    has_nsg = true
  }
  "db" = {
    cidr              = "172.22.12.0/24"
    has_nsg           = false
    service_endpoints = ["Microsoft.Storage"]
  }
  # mgmt added to capture all 4 hub subnets from the lab IP schema
  "mgmt" = {
    cidr    = "172.22.7.0/24"
    has_nsg = false
  }
}
###--end - ex4a & ex4b
```

---

### Q&A — Topic 4

**Q: count = 3, subnets indexed 0/1/2. You remove index 1. Walk through what terraform plan shows.**

Terraform renumbers the remaining items — index 2 becomes index 1. Plan shows: index 1 destroy (the removed one), index 2 destroy (collateral — the index shifted), index 1 create (what was index 2, recreated at its new index). Index 2 is destroyed and recreated even though you never touched it. State tracks resources by index position, not identity — that's the fundamental flaw.

**Q: What does Terraform complain about if you pass a raw list to for_each without toset()?**

It errors: `for_each` requires a map or set, not a tuple. Lists allow duplicates — two identical entries would produce an identical map key, which is impossible. `toset()` forces deduplication.

**Q: With for_each on toset(list) — what are each.key and each.value? How does that differ from for_each on a map?**

With `toset()`: `each.key == each.value` — both are the string value; the set has no separate key structure. With a map: `each.key` is the map key (e.g. `"web"`), `each.value` is the full value object (e.g. `{ cidr = "172.22.10.0/24", has_nsg = true }`).

---

## Topic 5 — Data Sources

### Theory

Data sources read existing infrastructure not managed by this config. Read-only — you cannot create or modify anything through a data source.

**Syntax**

```hcl
# resource block  →  resource "provider_type" "local_name" { }
# data source     →  data    "provider_type" "local_name" { }

data "azurerm_resource_group" "main" {
  name = "rg-vg-lab-wus-01"   # lookup key — must already exist in Azure
}

# Reference pattern: data.<type>.<name>.<attribute>
data.azurerm_resource_group.main.location
data.azurerm_resource_group.main.name
data.azurerm_resource_group.main.id
```

**Common Azure data sources**

| Data source | Key attributes |
|---|---|
| `azurerm_resource_group` | `id`, `name`, `location`, `tags` |
| `azurerm_virtual_network` | `id`, `name`, `address_space`, `location`, `subnets`, `dns_servers`, `guid`, `tags` |
| `azurerm_subnet` | `id`, `name`, `address_prefix`, `address_prefixes` |
| `azurerm_client_config` | `tenant_id`, `subscription_id`, `object_id` (current SP/user) |

**Timing**

- Data sources resolve at **plan time** if the target already exists.
- If the target doesn't exist at plan time → error, even if a resource block in the same config creates it. The fix — `depends_on` on the data source — is covered in Topic 6.

**When to use data source vs variable vs hardcoded**

| Option | Use when |
|---|---|
| Data source | Resource exists in Azure and you need its current state/attributes at apply time |
| Variable | Value is known ahead of time but differs between environments or callers |
| Hardcoded | Truly universal, immutable constants — rare in production |

---

### Exercise 5 — data sources for existing infra

**Context:** The main resource group `rg-vg-lab-wus-01` already exists in Azure — it was created in the Azure CLI labs, not by this Terraform config. Declare a data source to read it, then use its attributes to deploy spoke1 VNet without hardcoding the location or RG name.

The `data "azurerm_resource_group" "main"` block declared here is reused directly by Exercise 4a (subnet and NSG resources) and Exercise 6 (hub VNet resource) — it's the shared RG reference for the entire lab config.

> **Lab note:** A data source for the hub VNet is included but commented out. In this lab, `azurerm_virtual_network.hub` is already declared as a `resource` block in Exercise 6. When a resource block exists, reference it directly — never declare both a `data` block and a `resource` block for the same Azure resource in the same config. The commented block is kept to show the pattern and contrast the two approaches.

**What this exercise covers:**
- Declaring a data source for an existing Azure resource
- Referencing data source attributes in a resource block
- Consuming `var.vnet_address_space` to supply the spoke address space

**Final solution — `ex05-datasources.tf`:**

```hcl
# Exercise 5 — Data Sources
# The resource group already exists in Azure from the CLI labs — it is not managed by this config.
# A data source reads it at plan time so its attributes (name, location) can be referenced
# without hardcoding. This data source is consumed by ex04, ex05, and ex06 resource blocks.

data "azurerm_resource_group" "main" {
  name = "rg-vg-lab-wus-01"
}

###--- below "data" block is redundant with the "resource" block in ex6.
### only use one. "resource" block is the preferred way.
# data "azurerm_virtual_network" "hub" {
#   name                = "vnet-vg-lab-wus-hub"
#   resource_group_name = data.azurerm_resource_group.main.name
# }

resource "azurerm_virtual_network" "spoke1" {
  name                = "${local.vnet_name}-spoke1"                   # e.g. "vnet-vg-lab-wus-spoke1"
  resource_group_name = data.azurerm_resource_group.main.name         # from data source above
  location            = data.azurerm_resource_group.main.location     # from data source above
  address_space       = var.vnet_address_space["spoke1"].address_space # ["172.22.16.0/20"] from tfvars
}
```

---

### Q&A — Topic 5

**Q: Three options for referencing an existing RG name — data source, variable, hardcoded. Concrete scenario for each.**

- **Data source** — the RG already exists and you need its current `location` and `tags` at apply time. One block, referenced everywhere, single update point.
- **Variable** — the RG name differs per environment. Declare `rg_name` as an input and supply `dev.tfvars`, `staging.tfvars`, `prod.tfvars` with different values. Same code, multiple variable files.
- **Hardcoded** — a well-known, truly immutable value that will never change across any environment. Very rare in production.

---

## Topic 6 — Meta-arguments & lifecycle

### Theory

**depends_on**

```hcl
resource "azurerm_virtual_network" "hub" {
  # ...
  depends_on = [data.azurerm_resource_group.main]
}
```

Use when Terraform can't infer the dependency from a direct attribute reference. Most common case: a resource (or data source) depends on a side effect of another resource, but no attribute ties them together.

**lifecycle block**

```hcl
lifecycle {
  prevent_destroy       = true
  create_before_destroy = true
  ignore_changes        = [tags]
}
```

| Argument | What it does |
|---|---|
| `prevent_destroy` | Errors on any plan that would destroy this resource. Removed by deleting the line. |
| `create_before_destroy` | Creates replacement before destroying old one — avoids downtime on forced recreates. |
| `ignore_changes` | Stops tracking listed attributes — drift won't appear in plan. |

**prevent_destroy — the gotcha**

Only works while the line exists in code. Anyone with repo access can remove it and destroy the resource. It's a speed bump, not a lock. For real protection: `azurerm_management_lock` with `lock_level = "CanNotDelete"`.

**ignore_changes + Azure Policy**

If Azure Policy auto-applies a tag post-deploy and you have `ignore_changes = [tags]`, Terraform ignores the drift silently on every subsequent plan. The policy tag sticks. This is the correct and intended pattern for policy-managed attributes.

**provider meta-argument — multi-subscription**

```hcl
provider "azurerm" {
  alias           = "spoke_sub"
  subscription_id = "bbbb-cccc-dddd-eeee"
  features {}
}

resource "azurerm_virtual_network" "spoke" {
  provider = azurerm.spoke_sub  # uses the aliased provider
  # ...
}
```

---

### Exercise 6 — hub VNet with lifecycle block

**Context:** The hub VNet is the most critical resource in the lab — peerings, firewall, DNS, and all traffic flow through it. This exercise protects it from accidental deletion, prevents Terraform from fighting Azure Policy over tags, and ensures ordering against the RG data source.

`azurerm_virtual_network.hub` declared here is referenced by `azurerm_subnet.hub` in Exercise 4a (`virtual_network_name = azurerm_virtual_network.hub.name`) — making Exercise 6 a dependency of Exercise 4a, even though it appears later in file order. Terraform resolves this from the dependency graph, not file order.

**What this exercise covers:**
- `lifecycle` block with `prevent_destroy` and `ignore_changes`
- `depends_on` pointing to a data source to enforce ordering
- Consuming `var.vnet_address_space` for address space (no hardcoded CIDR)
- The real-world limitations of `prevent_destroy`

**Final solution — `ex06-lifecycle.tf`:**

```hcl
# Exercise 6 — Meta-arguments & lifecycle
# Hub VNet with prevent_destroy, ignore_changes, and depends_on.
# Depends on the data source declared in ex05-datasources.tf.

resource "azurerm_virtual_network" "hub" {
  resource_group_name = data.azurerm_resource_group.main.name      # data source from ex05
  location            = data.azurerm_resource_group.main.location  # data source from ex05
  name                = "${local.vnet_name}-hub"                   # e.g. "vnet-vg-lab-wus-hub"
  address_space       = var.vnet_address_space["hub"].address_space # ["172.22.0.0/20"] from tfvars

  lifecycle {
    prevent_destroy = true     # terraform destroy errors on this resource
    ignore_changes  = [tags]   # Azure Policy may add tags post-deploy — stop tracking drift
  }

  # data.azurerm_resource_group.main has no attribute reference to this resource
  # depends_on makes the ordering explicit — hub VNet waits for the RG data source to resolve
  depends_on = [data.azurerm_resource_group.main]
}
```

---

### Q&A — Topic 6

**Q: ignore_changes = [tags] on a VNet. Azure Policy enforces a mandatory tag and adds it post-deploy. What does terraform plan show on subsequent runs?**

Nothing — no changes for that resource. Terraform detects the tag drift but ignores it because of `ignore_changes = [tags]`. The policy tag sticks undisturbed. Correct and intended.

**Q: prevent_destroy = true — "nobody can accidentally delete our hub VNet." What's the flaw?**

Two flaws: (1) anyone with repo access can remove the line, rerun apply, then destroy. (2) portal, CLI, ARM, or any tool outside Terraform bypasses it entirely. `prevent_destroy` only intercepts Terraform-initiated destroys and only while the line exists.

**Q: When is depends_on on a data source actually necessary?**

When a data source reads something created in the same apply with no attribute reference connecting them. Example: an `azurerm_role_assignment` grants an SP read access to a Key Vault; a data source then reads a secret from that vault. No attribute ties the data source to the role assignment, so Terraform doesn't know to wait. Without `depends_on = [azurerm_role_assignment.sp_kv]`, the data source fires at plan time, the role doesn't exist yet, and the read fails with a permission error.

---

## Design Challenge — Hub-Spoke Module Interface

### Objective

Design the complete variable interface for a reusable hub-spoke module — `variables.tf` and `terraform.tfvars` only, no resource blocks. This is the contract any caller must satisfy.

### Design decisions

- **Hub VNet** — always exactly one. Use `object({...})` not `map(object(...))`. A map implies variable number; `object` is a single structured value.
- **Spoke VNets** — variable number, same shape. Use `map(object({...}))` — each key becomes a spoke identity.
- **address_space** — `list(string)` not `string`. VNets support multiple CIDR blocks.
- **DNS flag** — `bool` with `default = false`. Safe default — caller opts in.
- **Tags** — `map(string)` with `default = {}`.

### Final solution — variables.tf

```hcl
variable "tags" {
  type    = map(string)
  default = {}
}

variable "hub_vnet" {
  type = object({
    name          = string
    address_space = list(string)
  })
}

variable "spoke_vnets" {
  type = map(object({
    name          = string
    address_space = list(string)
  }))
}

variable "flag_dns_phz" {
  type    = bool
  default = false
}
```

### Final solution — terraform.tfvars

```hcl
# Hub VNet — single object, no outer key
hub_vnet = {
  name          = "vnet-vg-lab-wus-hub"
  address_space = ["172.22.0.0/20"]
}

# Spoke VNets — map, each key becomes the spoke identity in state
spoke_vnets = {
  "spoke1" = {
    name          = "vnet-vg-lab-wus-spoke1"
    address_space = ["172.22.16.0/20"]
  }
  "spoke2" = {
    name          = "vnet-vg-lab-wus-spoke2"
    address_space = ["172.22.32.0/20"]
  }
}

flag_dns_phz = true  # create Private DNS zones for this deployment

tags = {
  environment = "lab"
  owner       = "vg"
}
```

### Refinement — one naming source of truth

The solution above hardcodes each `name` in tfvars (`"vnet-vg-lab-wus-spoke1"`). That works, but it duplicates the naming convention that `locals.tf` already computes — two sources of truth for the same string. This can be tightened:

- `name` is made **optional** in the variable: `name = optional(string)`.
- tfvars omits `name` entirely — only the map key (`spoke1`) and `address_space` are supplied.
- Resource code derives the full name from the locals chain: `name = each.value.name != null ? each.value.name : "${local.vnet_name}-${each.key}"`.

This mirrors how `subnets` already works (the map key *is* the name) and keeps the naming convention defined in exactly one place — `locals.tf`. Set `name` explicitly only when you need to override the convention for a specific resource.

Note the deliberate contrast between the two variable shapes:

- `subnets` → `map(object({ cidr, has_nsg, ... }))` — no `name` field, because the map key *is* the subnet name.
- `spoke_vnets` → `map(object({ name, address_space }))` — `name` exists (optional) because a spoke's full Azure resource name differs from its short handle (`spoke1` key vs `vnet-vg-lab-wus-spoke1` name).

The rule: if the map key can serve as the resource name directly, don't add a `name` field. If the resource needs a fuller name distinct from its handle, include an optional `name` and derive it from locals when omitted.

---

## Corrections & Gotchas

| Mistake | Correct |
|---|---|
| `all_true(...)` | `alltrue(...)` — no underscore |
| `can(regex("pattern"), var)` | `can(regex("pattern", var))` — string is the second arg to `regex()`, not to `can()` |
| `regex()` returns false on no match | `regex()` **throws an error** on no match — always wrap in `can()` |
| `"^172//."` for regex escape | `"^172\\."` — HCL needs `\\` to produce a single `\` for the regex engine |
| `optional(list(string))` → empty list | → `null`. Use `optional(list(string), [])` for an empty-list default |
| `object(string)` | Invalid — `object()` takes named attributes: `object({ name = string })` |
| `object(string, string)` | Invalid — one attribute block only: `object({ f1 = type, f2 = type })` |
| `k => v` in for expression | Returns the full object. Use `k => v.id` to surface a specific attribute |
| `prevent_destroy` = permanent lock | It's a speed bump — remove the line and rerun to bypass. Use `azurerm_management_lock` for real protection |
| Output named `vnet_address_space_0` | Use descriptive names: `vnet_primary_cidr` |
| Hub VNet variable as `map(object(...))` | Hub is always one — use `object({...})` |
| tfvars key `subnet = {...}` when variable is `subnets` | Names must match exactly |
| `address_space = [var.vnet_address_space["hub"].address_space]` | `.address_space` already returns `list(string)` — wrapping in `[...]` produces `list(list(string))`. Drop the brackets. |
| `resource_group_name = data.azurerm_resource_group.main` | Passing the object, not the string. Append `.name`. |
| `virtual_network_name = azurerm_virtual_network.hub` | Same — append `.name`. |
| `if v.has_nsg == true` in for filter | `has_nsg` is already a bool — `if v.has_nsg` is sufficient |
| `cidrsubnt(...)` | Typo — `cidrsubnet(...)` |

---

## Quick Reference

### for expression syntax

```hcl
# List → list
[for item in list : item.field]
[for item in list : item.field if condition]

# Map → map
{ for k, v in map : k => v.field }
{ for k, v in map : k => v.field if condition }

# Index into list
var.address_space[0]   # first element

# Merge maps — last map wins on key conflicts
merge(map1, map2)
```

### cidrsubnet()

```hcl
# Hub /20 → /24 subnets (newbits=4)
cidrsubnet("172.22.0.0/20", 4, 7)   # → 172.22.7.0/24   (mgmt)
cidrsubnet("172.22.0.0/20", 4, 10)  # → 172.22.10.0/24  (web)
cidrsubnet("172.22.0.0/20", 4, 11)  # → 172.22.11.0/24  (app)
cidrsubnet("172.22.0.0/20", 4, 12)  # → 172.22.12.0/24  (db)

# General formula: newbits = bits added to prefix (/20 + 4 = /24)
# netnum = subnet index within that prefix space
```

### Data source reference pattern

```hcl
data "azurerm_resource_group" "main" { name = "rg-vg-lab-wus-01" }
# data.<type>.<name>.<attribute>
data.azurerm_resource_group.main.location
data.azurerm_resource_group.main.name
```

### lifecycle block

```hcl
lifecycle {
  prevent_destroy       = true         # errors on destroy — not a permanent lock
  create_before_destroy = true         # avoid downtime on forced recreates
  ignore_changes        = [tags, ...]  # ignore drift on these attributes
}
```

### for_each patterns

```hcl
for_each = var.subnets                                        # map input
for_each = toset(var.subnet_names)                            # list → set
for_each = { for k, v in var.subnets : k => v if v.has_nsg }  # filtered map (bool — no == true)

# Inside the resource block:
name             = each.key            # map key or set value
address_prefixes = [each.value.cidr]   # map value attribute
```

---

## Running the Lab — init, plan & apply

### File layout

```
azure-terraform-labs/
└── day01-hcl-deep-dive/
    ├── main.tf
    ├── variables.tf
    ├── locals.tf
    ├── outputs.tf
    ├── terraform.tfvars
    ├── ex04-foreach.tf
    ├── ex05-datasources.tf
    └── ex06-lifecycle.tf
```

### Step 1 — Initialize

```powershell
cd azure-terraform-labs\day01-hcl-deep-dive
terraform init
```

Expected output:

```
Initializing the backend...
Initializing provider plugins...
- Finding hashicorp/azurerm versions matching "~> 3.100"...
- Installing hashicorp/azurerm v3.116.0...
- Installed hashicorp/azurerm v3.116.0 (signed by HashiCorp)

Terraform has created a lock file .terraform.lock.hcl to record the provider
selections made above. Include this file in your version control repository
so that Terraform can guarantee to make the same provider selections by
default when you run "terraform init" in the future.

Terraform has been successfully initialized!
```

> Commit `.terraform.lock.hcl` to Git. Add `.terraform/` to `.gitignore` — the provider binaries don't belong in source control.

### Step 2 — Plan

```powershell
terraform plan
```

Terraform reads `terraform.tfvars` automatically — no `-var-file` flag needed. If it prompts interactively for any variable, that variable is missing from `tfvars`. Add it and rerun.

### Expected plan output

```
Terraform will perform the following actions:

  # azurerm_network_security_group.main["app"] will be created
  + resource "azurerm_network_security_group" "main" {
      + location            = "westus"
      + name                = "nsg-vg-lab-wus-app"
      + resource_group_name = "rg-vg-lab-wus-01"
    }

  # azurerm_network_security_group.main["web"] will be created
  + resource "azurerm_network_security_group" "main" {
      + location            = "westus"
      + name                = "nsg-vg-lab-wus-web"
      + resource_group_name = "rg-vg-lab-wus-01"
    }

  # azurerm_subnet.hub["app"] will be created
  + resource "azurerm_subnet" "hub" {
      + address_prefixes     = ["172.22.11.0/24"]
      + name                 = "app"
      + resource_group_name  = "rg-vg-lab-wus-01"
      + virtual_network_name = "vnet-vg-lab-wus-hub"
    }

  # azurerm_subnet.hub["db"] will be created
  + resource "azurerm_subnet" "hub" {
      + address_prefixes     = ["172.22.12.0/24"]
      + name                 = "db"
      + resource_group_name  = "rg-vg-lab-wus-01"
      + virtual_network_name = "vnet-vg-lab-wus-hub"
    }

  # azurerm_subnet.hub["mgmt"] will be created
  + resource "azurerm_subnet" "hub" {
      + address_prefixes     = ["172.22.7.0/24"]
      + name                 = "mgmt"
      + resource_group_name  = "rg-vg-lab-wus-01"
      + virtual_network_name = "vnet-vg-lab-wus-hub"
    }

  # azurerm_subnet.hub["web"] will be created
  + resource "azurerm_subnet" "hub" {
      + address_prefixes     = ["172.22.10.0/24"]
      + name                 = "web"
      + resource_group_name  = "rg-vg-lab-wus-01"
      + virtual_network_name = "vnet-vg-lab-wus-hub"
    }

  # azurerm_virtual_network.hub will be created
  + resource "azurerm_virtual_network" "hub" {
      + address_space       = ["172.22.0.0/20"]
      + location            = "westus"
      + name                = "vnet-vg-lab-wus-hub"
      + resource_group_name = "rg-vg-lab-wus-01"
    }

  # azurerm_virtual_network.spoke1 will be created
  + resource "azurerm_virtual_network" "spoke1" {
      + address_space       = ["172.22.16.0/20"]
      + location            = "westus"
      + name                = "vnet-vg-lab-wus-spoke1"
      + resource_group_name = "rg-vg-lab-wus-01"
    }

Plan: 8 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + subnet_ids         = {
      + app  = (known after apply)
      + db   = (known after apply)
      + mgmt = (known after apply)
      + web  = (known after apply)
    }
  + vnet_address_space = ["172.22.0.0/20"]
  + vnet_id            = (sensitive value)
  + vnet_primary_cidr  = "172.22.0.0/20"
```

### What to verify in the plan

- NSGs created for `web` and `app` only — `db` and `mgmt` correctly excluded by the `has_nsg` filter
- All 4 subnet CIDRs match the lab IP schema exactly
- Hub VNet name `vnet-vg-lab-wus-hub` came from the locals naming chain, not hardcoded
- `vnet_id` shows as `(sensitive value)` — `sensitive = true` is working
- `vnet_primary_cidr` resolves to `"172.22.0.0/20"` as a string, not a list

### Step 3 — Apply

> **Pre-apply prerequisite:** only `rg-vg-lab-wus-01` needs to exist in Azure before running apply. All other resources — hub VNet, spoke1 VNet, subnets, NSGs — must be absent. The data source reads the RG at plan time; everything else is created fresh by Terraform. If any of those resources exist from a prior CLI lab session, delete them from the portal first.

> **Subscription:** verify `az account show` returns subscription ID `<your-subscription-id>` before applying. If not, run `az account set --subscription "<your-subscription-id>"`.

```powershell
terraform apply
```

Terraform runs a plan first and prompts for confirmation. Type `yes` to proceed.

#### Apply output

```
data.azurerm_resource_group.main: Reading...
data.azurerm_resource_group.main: Read complete after 0s [id=/subscriptions/<your-subscription-id>/resourceGroups/rg-vg-lab-wus-01]

Terraform used the selected providers to generate the following execution plan. Resource actions are indicated with the following symbols:
  + create

Terraform will perform the following actions:

  # azurerm_network_security_group.main["app"] will be created
  # azurerm_network_security_group.main["web"] will be created
  # azurerm_subnet.hub["app"] will be created
  # azurerm_subnet.hub["db"] will be created
  # azurerm_subnet.hub["mgmt"] will be created
  # azurerm_subnet.hub["web"] will be created
  # azurerm_virtual_network.hub will be created
  # azurerm_virtual_network.spoke1 will be created

Plan: 8 to add, 0 to change, 0 to destroy.

Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes

azurerm_virtual_network.hub: Creating...
azurerm_network_security_group.main["web"]: Creating...
azurerm_network_security_group.main["app"]: Creating...
azurerm_virtual_network.spoke1: Creating...
azurerm_network_security_group.main["web"]: Creation complete after 6s
azurerm_virtual_network.spoke1: Creation complete after 8s
azurerm_network_security_group.main["app"]: Creation complete after 8s
azurerm_virtual_network.hub: Creation complete after 8s
azurerm_subnet.hub["web"]: Creating...
azurerm_subnet.hub["db"]: Creating...
azurerm_subnet.hub["mgmt"]: Creating...
azurerm_subnet.hub["app"]: Creating...
azurerm_subnet.hub["app"]: Creation complete after 7s
azurerm_subnet.hub["mgmt"]: Creation complete after 14s
azurerm_subnet.hub["web"]: Creation complete after 21s
azurerm_subnet.hub["db"]: Creation complete after 28s

Apply complete! Resources: 8 added, 0 changed, 0 destroyed.

Outputs:

subnet_ids = {
  "app"  = "/subscriptions/<your-subscription-id>/virtualNetworks/vnet-vg-lab-wus-hub/subnets/app"
  "db"   = "/subscriptions/<your-subscription-id>/virtualNetworks/vnet-vg-lab-wus-hub/subnets/db"
  "mgmt" = "/subscriptions/<your-subscription-id>/virtualNetworks/vnet-vg-lab-wus-hub/subnets/mgmt"
  "web"  = "/subscriptions/<your-subscription-id>/virtualNetworks/vnet-vg-lab-wus-hub/subnets/web"
}
vnet_address_space = tolist([
  "172.22.0.0/20",
])
vnet_id           = <sensitive>
vnet_primary_cidr = "172.22.0.0/20"
```

#### What to observe in the apply output

- **Data source resolves first** — `data.azurerm_resource_group.main: Read complete` appears before any resource is created. Terraform always resolves data sources before touching resources.
- **Parallelism** — hub VNet, spoke1 VNet, and both NSGs all start creating simultaneously. Terraform identifies no dependency between them and runs them in parallel. Subnets start only after the hub VNet completes — they depend on it.
- **Outputs print at the end** — subnet IDs are now real Azure resource IDs, not `(known after apply)`. `vnet_id` still shows `<sensitive>` because of `sensitive = true` in `outputs.tf`.
- **`terraform.tfstate` now exists** — apply writes state. This file is what Terraform uses to track what it owns. Don't edit it manually.
- **`vnet_address_space` returns `tolist([...])` not a plain list** — this is Terraform surfacing the internal type. Functionally identical to `["172.22.0.0/20"]`.

#### Reading sensitive output

```powershell
terraform output -raw vnet_id
```

Returns the actual resource ID without the `<sensitive>` mask.

---

*Day 1 complete. Day 2 takes this config and moves its state to a remote Azure Storage backend with locking and workspaces.*