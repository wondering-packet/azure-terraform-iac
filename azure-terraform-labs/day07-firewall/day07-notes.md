# Day 7 — Azure Firewall

> **How to use this guide.** Each topic's theory gives you the building blocks — not the
> finished answer. Each exercise states a full problem: objective, inputs, constraints,
> and a "Blocks to write" line. Attempt it from the theory, predict the plan, then read the
> solution and apply. This is the payoff day: the `172.22.1.4` placeholder every Day-4 UDR
> has pointed at since Day 4 becomes a real firewall.
>
> **Assumed knowledge this day:** firewall rule-processing *fundamentals* — stateful
> inspection, the general idea of allow/deny precedence — are assumed from the Azure CLI
> phase. This guide teaches the **Azure-specific three-pass model** and the **Terraform
> resource shapes**, not a generic firewall primer.

## File & marker conventions
- `d07…` files are day-scoped: `d07ex01-fw_pip.tf`, `d07ex02ex04-fw_policy.tf` (policy **and** its rule-collection group live in one file), `d07ex03-fw.tf`, `d07ex05-diagnostics.tf`, `d07-base.tf` (re-declared base data sources), `remote-state.tf` (the cross-stack read).
- Shared files (`locals.tf`, `variables.tf`, `terraform.tfvars`, `backend.tf`, `main.tf`) carry inline markers: `###---d07exNN >>>` / `<<<`.

## Prerequisites & continuity
This is a **new, ephemeral stack** with its own state key `networking/firewall`. It does not build subnets, peerings, routing, or DNS — those are live in the base (`networking/hub-spoke`) at Day-5 end state, plus the `spoke1_to_private_endpoint` route you restore in Ex 0. The firewall stack **reads** the base `AzureFirewallSubnet` via `terraform_remote_state` and attaches the firewall there, becoming the real `172.22.1.4`. The Azure Firewall (~$1.25/hr) is **torn down at session end**; the Firewall Policy + rules are free and persistent in the real world but share this stack's key, so the whole stack is destroyed together. Day 8 inherits the base (now with the permanent PE route) and a placeholder `172.22.1.4` again.

## Standard lab environment
| Setting | Value |
|---|---|
| Subscription | `<your-subscription-id>` |
| Region / RG | `westus` / `rg-vg-lab-wus-01` |
| State key (this day) | `networking/firewall` (new ephemeral stack) |
| Base state (read-only) | `networking/hub-spoke` via `terraform_remote_state` |
| Backend / auth | `stvglabwustfstate` / `tfstate` — Azure AD (`use_azuread_auth` / `use_cli`) — `default` workspace |
| Provider | `hashicorp/azurerm ~> 3.100` (resolved: v3.117.1) |
| Firewall private IP | `172.22.1.4` (first assignable in `AzureFirewallSubnet 172.22.1.0/26`) |
| OS / shell | Windows / PowerShell — backtick (`` ` ``) continuation |

## Table of contents
0. [Exercise 0 — restore the PE route + new-stack gate](#exercise-0--restore-the-pe-route--new-stack-gate)
1. [Topic 1 — The firewall as the real next-hop](#topic-1--the-firewall-as-the-real-next-hop)
2. [Topic 2 — Firewall Policy vs Firewall](#topic-2--firewall-policy-vs-firewall)
3. [Topic 3 — The three-pass rule model](#topic-3--the-three-pass-rule-model)
4. [Topic 4 — DNAT, inter-spoke inspection, and the Private Endpoint trap](#topic-4--dnat-inter-spoke-inspection-and-the-private-endpoint-trap)
5. [Design challenge](#design-challenge)
6. [Corrections & gotchas](#corrections--gotchas)

---

### Exercise 0 — restore the PE route + new-stack gate

Day 7 is special: unlike a normal zero-change gate, it opens with a **required base edit** *and* a new-stack remote-state check. Two tasks, both before any firewall build.

**Objective:** (a) restore the `spoke1_to_private_endpoint` route in the base and apply it; (b) scaffold the firewall stack on key `networking/firewall` and prove its `terraform_remote_state` read of the base resolves.

**Tasks:**
- **(a) Restore the PE route (base folder).** The route (`172.22.3.0/24 → 172.22.1.4`, `VirtualAppliance`) was commented out since Day 5 so spoke1 wouldn't blackhole PE traffic into the dead placeholder. A real firewall is now arriving, so it comes back. Uncomment it in the base `d04ex03-routing.tf`, `plan`, and `apply`.
- **(b) Scaffold the firewall stack (new folder).** Copy Day 6 forward, repoint the backend `key` to `networking/firewall`, strip the VPN resources, keep the `terraform_remote_state` scaffolding. Then prove the cross-stack read resolves.

**Constraints:**
- (a) is a **base-owned** change applied in the *base* folder — not a cross-stack write from the firewall stack. Touch nothing else in the base.
- **Cross-stack boundary (outputs-only):** `terraform_remote_state` exposes the base's **root `outputs` only** — never its locals or variables. Anything you need from the base that is *not* an output must be **re-declared locally as a `data` source**. The resource group is the canonical case — rebuild its name from the workspace-aware naming chain, don't hardcode:

```hcl
# base resources NOT published as outputs get re-declared locally (d07-base.tf)
data "azurerm_resource_group" "main" {
  name = # ?  -> build from the naming chain: "${local.rg_name}-01"
}
```

**Blocks to write:** `data.terraform_remote_state.base` (carried from Day 6, key stays `networking/hub-spoke`); `data.azurerm_resource_group.main` + `data.azurerm_subnet.spoke1_workload` / `spoke2_workload` (re-declared). **No firewall resources yet.**

**Predict:**
- (a) `terraform plan` in the base → `1 to add` on exactly `azurerm_route.spoke1_to_private_endpoint`. Until the firewall exists (Ex 3), spoke1→PE still blackholes — restoring the route re-arms the steer, it does not fix connectivity.
- (b) `terraform workspace show` → `default`; `terraform plan` on the fresh stack → `No changes` (config holds only data sources so far). What does `terraform console` return for the remote-state read on a *never-applied* stack — the real subnet ID, or something else?

**Solution** — attempt the tasks and predictions above before reading on.

**(a) Restore + apply, in the base folder:**
```powershell
# in the BASE folder (networking/hub-spoke), after uncommenting the route
terraform plan     # 1 to add -> azurerm_route.spoke1_to_private_endpoint
terraform apply
```

**(b) The re-declared base data sources and the remote-state read:**
```hcl
# d07-base.tf — re-looked-up because the base does NOT publish these as outputs
data "azurerm_resource_group" "main" {
  name = "${local.rg_name}-01"     # rebuilt from the naming chain, not hardcoded
}

data "azurerm_subnet" "spoke1_workload" {
  name                 = "${local.snet_name}-spoke1-workload"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = "${local.vnet_name}-spoke1"
}

data "azurerm_subnet" "spoke2_workload" {
  name                 = "${local.snet_name}-spoke2-workload"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = "${local.vnet_name}-spoke2"
}
```

```hcl
# remote-state.tf — the read of the base stack
data "terraform_remote_state" "base" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-vg-lab-wus-01"
    storage_account_name = "stvglabwustfstate"
    container_name       = "tfstate"
    key                  = "networking/hub-spoke"   # the base stack's key
    use_azuread_auth     = true                      # AAD flags are load-bearing — must match the base backend
    use_cli              = true
  }
}
```

```powershell
terraform init -reconfigure
terraform workspace show    # default
terraform plan              # No changes (data sources only)
terraform apply             # 0 to add — persists the remote-state read (see quirk)
terraform console
> data.terraform_remote_state.base.outputs.firewall_subnet_id
# -> ".../virtualNetworks/vnet-vg-lab-wus-hub/subnets/AzureFirewallSubnet"
```

> **Observed quirk (Rule F).** On a *never-applied* stack, `terraform console` shows the remote-state read as `(known after apply)`, because the read isn't yet persisted to this stack's state. A **no-op `terraform apply`** (0 to add — the config is data-sources only) persists it; the second console call returns the real value. Also: a **mistyped output name** (e.g. `azurefirewall_subnet_id` instead of `firewall_subnet_id`) *also* returns `(known after apply)` pre-apply with **no error** — verify output names against the base `outputs.tf`, don't trust a pre-apply console read to validate them.

Ex 0 produces no firewall `.tf`; build exercises begin at Ex 1.

**Locals** (relevant): `local.rg_name` = `rg-${local.prefix}` (`rg-vg-lab-wus`), `local.snet_name`, `local.vnet_name` — all **reused** from the carried chain.

---

## Topic 1 — The firewall as the real next-hop

### Theory

For three days every Day-4 UDR set `next_hop_type = VirtualAppliance`, `next_hop_ip_address = 172.22.1.4` — aimed at nothing. The address isn't a guess: `AzureFirewallSubnet` is `172.22.1.0/26`, and Azure reserves the first three usable host addresses (`.1`–`.3`) on top of the `.0` network address, so the first assignable address is `.4`. Azure Firewall lands there deterministically — which is *why* the UDRs could be pre-aimed days before the firewall existed. "Deterministic" is not "confirmed for your eyes," so **verify the assigned private IP** once the firewall provisions (Ex 5).

The cross-stack seam is the whole design: this stack **reads** `firewall_subnet_id` from the base and attaches the firewall there; it does not create the subnet (Day 3 owns it) and does not touch the UDRs (Day 4 owns them). It only makes their target real.

Ex 1 is the day's simplest build — the firewall needs a Standard public IP to front-end.

### Exercise 1 — Public IP for the firewall

**Objective:** create the Standard, statically-allocated PIP the firewall attaches.

**Inputs:**
| Field | Value |
|---|---|
| Name | `pip-vg-lab-wus-fw` (`${local.pip_name}-fw`) |
| SKU | `Standard` |
| Allocation | `Static` |
| Location / RG | `westus` / from the re-declared RG data source |
| Tags | `local.lab_tags` |

**Constraints:** Standard SKU + Static allocation are **required** for Azure Firewall (a zonal appliance won't attach a Basic/Dynamic PIP). Don't rely on provider defaults — set both explicitly.

**Blocks to write:** `azurerm_public_ip.fw` — **no child blocks**. Derive attributes from hover + Lab 6 Step 1.

**Predict:** `1 to add`; `sku = "Standard"`, `allocation_method = "Static"`, and `sku_tier = "Regional"` in the plan.

**Solution** — try the exercise above before reading on.

```hcl
# d07ex01-fw_pip.tf
resource "azurerm_public_ip" "fw" {
  name                = "${local.pip_name}-fw"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  allocation_method   = "Static"   # required for Azure Firewall
  sku                 = "Standard"  # required for Azure Firewall
  tags                = local.lab_tags
}
```

```powershell
terraform plan     # Predict: 1 to add, the PIP
terraform apply
```

**Locals** (relevant): `local.pip_name` = `pip-${local.prefix}` (`pip-vg-lab-wus`) — **reused** (declared Day 6); `local.lab_tags` — reused (Day 5).

### Q&A

**Q1 — The firewall reads its subnet from the base via remote state. What exactly is read, and why can't the firewall stack just create the subnet itself?** It reads the base output `firewall_subnet_id` — the resource ID of `AzureFirewallSubnet`. The stack can't create the subnet because **Day 3 owns it** (it lives in `networking/hub-spoke`); two stacks creating the same subnet would fight over one resource. Cross-stack ownership stays one-directional: the base owns and publishes; the firewall stack consumes.

---

## Topic 2 — Firewall Policy vs Firewall

### Theory

The CLI lab ran two commands — `policy create`, then `firewall create`. That maps to two Terraform resources, and the reasoning is the point:

- `azurerm_firewall_policy` — free, standalone, **portable**: holds every rule; one policy can front multiple firewalls. Persistent in prod.
- `azurerm_firewall` — the billed data-plane appliance that *references* a policy via `firewall_policy_id`. Ephemeral here.

That lifecycle asymmetry is why they're separate resources. We still key them in **one stack** because real platform teams own the firewall-and-its-policy as a unit. The containment hierarchy hangs off the policy, not the firewall:

```
azurerm_firewall_policy
  └── ..._rule_collection_group        # priority only, no action
        ├── network_rule_collection    # action (Allow/Deny) lives HERE
        ├── application_rule_collection # action lives HERE
        └── nat_rule_collection         # action = Dnat
              └── rule { }              # match criteria only — NO action field
```

The CLI's **two-step** create (`firewall create` then a separate `ip-config` step) collapses into **one** declarative `azurerm_firewall`: the `ip_configuration` block *is* the second step. That two-step is a CLI/extension artifact, not a Terraform fact.

### Exercise 2 — Firewall Policy

**Objective:** create the Standard-tier policy the firewall references and the rules hang off.

**Inputs:** name `fwpol-vg-lab-wus`; `sku = "Standard"`; location/RG from the RG data source; `local.lab_tags`.

**Constraints:** SKU **Standard** (Lab 6 Step 2 — Premium buys IDPS/TLS-inspection out of scope here). Bare policy — no rules yet (Ex 4).

**Blocks to write:** `azurerm_firewall_policy.main` — **no child blocks**.

**Predict:** `1 to add`; creating the policy changes nothing about the not-yet-existing firewall or any base resource (nothing references it yet).

**Solution** — try the exercise above before reading on.

```hcl
# d07ex02ex04-fw_policy.tf (policy portion)
resource "azurerm_firewall_policy" "main" {
  name                = local.fwpol_name
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  sku                 = "Standard"
  tags                = local.lab_tags
}
```

**Locals** (relevant): `local.fwpol_name` = `fwpol-${local.prefix}` (`fwpol-vg-lab-wus`) — **declared this exercise**.

### Exercise 3 — Azure Firewall (the complex resource)

**Objective:** deploy `fw-vg-lab-wus-hub` into the base `AzureFirewallSubnet`, fronted by Ex 1's PIP, referencing Ex 2's policy. This is the ~30-minute provision — apply it early and fill the wait with Topic 3.

**Inputs:**
| Field | Value / source |
|---|---|
| Name | `fw-vg-lab-wus-hub` (`${local.fw_name}-hub`) |
| `sku_name` | `AZFW_VNet` |
| `sku_tier` | `Standard` |
| `firewall_policy_id` | Ex 2's policy |
| `ip_configuration.subnet_id` | base `firewall_subnet_id` (remote state) |
| `ip_configuration.public_ip_address_id` | Ex 1's PIP |
| Tags | `local.lab_tags` |

**Constraints:** the subnet is **read from remote state**, never created here. The CLI's two-step create is **one** declarative resource — the `ip_configuration` block is the second step.

**Blocks to write (complex-resource barebones skeleton — the day's one exception):**

```hcl
resource "azurerm_firewall" "hub" {
  # name, resource_group_name, location
  # sku_name           =   # which value for a VNet firewall?
  # sku_tier           =   # Standard this lab
  # firewall_policy_id =   # reference Ex 2's policy
  # tags
  ip_configuration {
    # name
    # subnet_id            =   # remote-state: which base output?
    # public_ip_address_id =   # Ex 1's PIP
  }
}
```

**Predict:** `1 to add`; apply sits ~30 min. `ip_configuration.private_ip_address` shows `(known after apply)` — you expect `172.22.1.4`, and Ex 5's discipline is to *verify*, not assume it.

**Solution** — try the exercise above before reading on. (Verbatim, including the original spacing quirk on the last `ip_configuration` line.)

```hcl
# d07ex03-fw.tf
resource "azurerm_firewall" "hub" {
  name = "${local.fw_name}-hub"
  resource_group_name = data.azurerm_resource_group.main.name
  location = data.azurerm_resource_group.main.location
  sku_name = "AZFW_VNet"     # VNet-based firewall (not AZFW_Hub / secured vHub)
  sku_tier = "Standard"
  firewall_policy_id = azurerm_firewall_policy.main.id   # the load-bearing attachment
  ip_configuration {
    name = "${local.fwipconf_name}"
    subnet_id = data.terraform_remote_state.base.outputs.firewall_subnet_id   # read, not created
     public_ip_address_id = azurerm_public_ip.fw.id
  }
  tags = local.lab_tags
}
```

```powershell
terraform apply     # ~30 min; kick off early, then do Topic 3 in parallel
```

**Locals** (relevant): `local.fw_name` = `fw-${local.prefix}` (`fw-vg-lab-wus`) and `local.fwipconf_name` = `fwipconf-${local.prefix}` — **declared this exercise**.

### Q&A

**Q2 — Policy is free and persistent; the firewall is billed and ephemeral. Why keep them in the same state key rather than splitting policy into `hub-spoke`?** Because the state boundary should model an ownership/lifecycle boundary that actually exists. The firewall-and-its-policy are owned by the same team as one unit; splitting the policy into the base would invent a boundary that isn't there and couple base applies to firewall-rule churn. Keeping them together means the whole firewall concern lives, and tears down, as one stack — even though the policy *could* survive for free in the real world.

---

## Topic 3 — The three-pass rule model

### Theory

The Azure-specific, non-obvious fact: **rule *type* is evaluated before RCG priority.** Azure runs the rule base in fixed passes:

```
Threat Intel  →  DNAT pass  →  Network pass  →  Application pass  →  implicit Deny
```

The entire network pass completes before the application pass begins. So a network rule in an RCG at priority 500 is evaluated **before** an application rule in an RCG at priority 100 — RCG priority never gets a vote across type boundaries. Within a pass: RCGs by priority, then collections by priority, first match wins.

Three structural facts the Terraform schema mirrors exactly:
- **The collection carries the action** (`action = "Allow" / "Deny" / "Dnat"` on the `*_rule_collection` block).
- **Rules carry match criteria only — there is no `action` on a `rule {}` block.** If you go looking for one, you've misread the hierarchy.
- **RCGs carry priority only, no action** — a pure ordering container.

Priority namespaces are **per rule type** (network priority 100 and application priority 100 never collide). Everything lives in **one** `azurerm_firewall_policy_rule_collection_group` resource with repeatable `network_rule_collection {}` / `application_rule_collection {}` / `nat_rule_collection {}` blocks — the provider does not let you split collections into separate RCG resources.

Two base prerequisites were already satisfied, so nothing to build here: peering `allow_forwarded_traffic = true` / spoke `use_remote_gateways = false` (Day 4, reverted-clean after Day 6), and the spoke1 PE UDR (restored in Ex 0).

> **CLI-vs-Terraform (Rule F).** The CLI's `--target-fqdns` becomes `destination_fqdns`, and `--protocols https=443` becomes a nested `protocols {}` child block (`type` + `port`) — not a string. Network rules take a flat `protocols` list; application rules need the child block.

### Exercise 4 — Rule collection group + rules

**Objective:** build the single RCG `fwrcg-vg-lab-wus-main` (priority 100) on Ex 2's policy, replicating Lab 6's collections. It binds to the *policy*, so it applies independently of the ~30-min firewall provision.

**Inputs:**
| Collection | Type | Coll. priority | Action | Rule | Source | Dest | Ports | Proto |
|---|---|---|---|---|---|---|---|---|
| `fwnetcol-vg-lab-wus-allow` | network | 100 | Allow | `allow-spoke1-to-pe` | spoke1 /24 | PE `172.22.3.4` | 443 | TCP |
| " | " | " | " | `allow-spoke2-to-rfc1918` | spoke2 /24 | RFC1918 ×3 | * | TCP |
| " | " | " | " | `allow-spoke1workload-to-spoke2workload` | spoke1 /24 | spoke2 /24 | * | Any |
| `fwappcol-vg-lab-wus-allow` | application | 200 | Allow | `allow-spoke1-github` | spoke1 /24 | fqdns: github.com, *.github.com | 80/443 | Http/Https |
| `fwnetcol-vg-lab-wus-deny` | network | 300 | Deny | `deny-spoke2-to-internet` | spoke2 /24 | `*` | * | Any |
| `fwnatcol-vg-lab-wus` | nat | 150 | Dnat | `dnat-ssh-spoke1` | `var.lab_public_ip` | fw public IP | 2222 | TCP |

DNAT extras: `translated_address = local.spoke1_workload_vm_ip` (`172.22.16.4`), `translated_port = 22`.

**Constraints:** one resource, many nested collection blocks; `action` on each collection; `rule {}` blocks carry match criteria only. Application rule needs a `protocols {}` child block.

**Blocks to write:** `azurerm_firewall_policy_rule_collection_group.main_100` with child blocks `network_rule_collection {}` (×2), `application_rule_collection {}` (×1, whose `rule {}` needs a `protocols {}` grandchild), `nat_rule_collection {}` (×1).

**Predict:** `1 to add` (one RCG *resource*, not one per collection); it applies even while the firewall is still provisioning, because it attaches to the policy, not the firewall.

**Solution** — try the exercise above before reading on.

> **PE inspection: why this ships as a network rule.** We also built an *application* rule for the storage PE (`allow-spoke1-pe-app`, FQDN-based) and tested it, but it did **not** work in this environment and was **dropped from the end state**. Two legitimate reasons (both detailed in Topic 4): (1) an application rule proxies the connection, so the firewall resolves the storage FQDN *itself* — and without `privatelink.blob.core.windows.net` linked to the firewall's own VNet **and DNS proxy enabled** on the firewall, it resolves the storage account's **public** IP, which the storage account (public access denied) refuses → the connection hangs; (2) because application rules SNAT, the PE would see the firewall's IP rather than spoke1, which **breaks the source-based PE-subnet NSG** and would require reworking that NSG to allow the firewall subnet. The zone link is a base resource (out of scope this day) and the DNS-proxy/NSG changes weren't worth it for a lab, so the day concludes with the **network rule** `allow-spoke1-to-pe`, which worked (storage stays symmetric — see Topic 4) and matches Lab 6.

```hcl
# d07ex02ex04-fw_policy.tf (rule-collection-group portion)
resource "azurerm_firewall_policy_rule_collection_group" "main_100" {
  name               = "${local.fwrcg_name}-main"
  firewall_policy_id = azurerm_firewall_policy.main.id
  priority           = 100

  network_rule_collection {
    name     = "${local.fwnetcol_name}-allow"
    priority = 100
    action   = "Allow"                      # action on the COLLECTION, not the rule
    rule {                                   # the working PE rule (network; storage stays symmetric)
      name                  = "allow-spoke1-to-pe"
      protocols             = ["TCP"]
      destination_ports     = ["443"]
      source_addresses      = [data.azurerm_subnet.spoke1_workload.address_prefixes[0]]
      destination_addresses = [data.terraform_remote_state.base.outputs.storage_pe_private_ip]  # PE IP via remote state
    }
    rule {
      name                  = "allow-spoke2-to-rfc1918"
      protocols             = ["TCP"]        # TCP-only -> spoke2->spoke1 ICMP is NOT allowed by this rule
      source_addresses      = [data.azurerm_subnet.spoke2_workload.address_prefixes[0]]
      destination_addresses = local.rfc1918_address
      destination_ports     = ["*"]
    }
    rule {
      name                  = "allow-spoke1workload-to-spoke2workload"
      protocols             = ["Any"]        # Any -> inter-spoke ping works this direction
      source_addresses      = [data.azurerm_subnet.spoke1_workload.address_prefixes[0]]
      destination_addresses = [data.azurerm_subnet.spoke2_workload.address_prefixes[0]]
      destination_ports     = ["*"]
    }
  }

  application_rule_collection {
    name     = "${local.fwappcol_name}-allow"
    action   = "Allow"
    priority = 200
    rule {
      name = "allow-spoke1-github"
      protocols {                            # nested child block (CLI's https=443 becomes this)
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }
      destination_fqdns = ["github.com", "*.github.com"]   # provider name, not the CLI's --target-fqdns
      source_addresses  = [data.azurerm_subnet.spoke1_workload.address_prefixes[0]]
    }
    # NOTE: an allow-spoke1-pe-app application rule was tested here and dropped — see the
    # "PE inspection" note above and Topic 4 (firewall-side DNS resolution + NSG/SNAT reasons).
  }

  network_rule_collection {
    name     = "${local.fwnetcol_name}-deny"
    action   = "Deny"
    priority = 300
    rule {
      name                  = "deny-spoke2-to-internet"
      protocols             = ["Any"]
      destination_ports     = ["*"]
      destination_addresses = ["*"]
      source_addresses      = [data.azurerm_subnet.spoke2_workload.address_prefixes[0]]
    }
  }

  nat_rule_collection {
    name     = local.fwnatcol_name
    action   = "Dnat"                        # only valid action for a NAT collection
    priority = 150
    rule {
      name                = "dnat-ssh-spoke1"
      protocols           = ["TCP"]
      source_addresses    = var.lab_public_ip              # your public IP (from tfvars)
      destination_address = azurerm_public_ip.fw.ip_address # singular string (NOT the plural network-rule form)
      translated_address  = local.spoke1_workload_vm_ip     # static local -> no dependency on the ephemeral test VM
      translated_port     = 22
      destination_ports   = ["2222"]
    }
  }
}
```

```powershell
terraform apply     # Predict: 1 to add (the RCG); succeeds even if the firewall is still provisioning
```

**Locals** (relevant): `local.fwrcg_name`, `local.fwnetcol_name`, `local.fwappcol_name`, `local.fwnatcol_name`, `local.rfc1918_address`, `local.spoke1_workload_vm_ip` (= `172.22.16.4`) — all **declared this exercise**. The last mirrors the static IP pinned on the spoke1 test VM, single-sourced here so the DNAT rule doesn't depend on the (ephemeral, toggleable) test VM's data source.

### Q&A

**Q3 — A network rule sits at RCG priority 500; an application rule at RCG priority 100. Which is evaluated first, and why doesn't RCG priority decide it?** The **network** rule — because rule *type* is the outer sort key: the whole network pass runs before the application pass. RCG priority only orders rules *within the same pass*, so the app rule's lower (higher-priority) number is irrelevant across the type boundary. We saw this directly while experimenting: an application rule for the storage PE could never match the flow while the network `allow-spoke1-to-pe` rule was present, because the network pass matched first — the network rule had to be removed before the app rule got a look (that experiment was later dropped; see Topic 4).

**Q4 — Rules have no action field. Where does Allow/Deny live, and why is that the correct design?** On the **collection**. A collection is "a set of rules that share one action," so hoisting the action to the collection removes a per-rule contradiction risk (you can't write an Allow rule and a Deny rule in the same collection) and makes evaluation order — collection priority — line up with policy intent.

---

## Topic 4 — DNAT, inter-spoke inspection, and the Private Endpoint trap

### Theory

**DNAT** publishes an internal service on the firewall's public IP: a `nat_rule_collection` (`action = "Dnat"`) matches inbound to the firewall's public IP on a port and rewrites destination + port to an internal target. Your rule maps `<fw public IP>:2222 → 172.22.16.4:22` (SSH to the spoke1 VM), restricted to `var.lab_public_ip`. `destination_address` is a **singular string** here (network rules use the plural `destination_addresses` list).

**Inter-spoke** works because both spokes default-route `0.0.0.0/0 → 172.22.1.4`; the spokes aren't peered to each other, so the only path to the other spoke is via the firewall, which `allow-spoke1workload-to-spoke2workload` permits.

**The Private Endpoint trap** is the day's deepest lesson, and it's why the two PE rules behaved so differently in testing:

- **Return-path asymmetry.** A private endpoint does **not** honor UDRs on its own subnet — it replies straight to the source IP, bypassing the firewall. A stateful firewall that only ever sees the forward half drops the flow. **Azure Storage is the documented exception** that stays symmetric without SNAT; most other PE services need SNAT. Best practice is to SNAT (or use application rules, which SNAT automatically) for guaranteed symmetry.
- **SNAT source IP.** For intra-VNet traffic the firewall SNATs to its **private** IP (`172.22.1.4`), never its public one — so traffic stays private and the private-DNS resolution is unaffected. But the PE-subnet NSG now sees the **firewall's** source, not the client's — so a source-based NSG allow (spoke1 /24) stops matching, and you must allow the firewall subnet at the NSG and push client-granular control up to the firewall.
- **Who resolves the name.** A **network** rule matches on destination *IP*: the **client** (spoke1) does the DNS lookup, resolves the storage FQDN to the PE via the privatelink zone linked to spoke1, and the firewall forwards on IP. An **application** rule proxies: the **firewall** terminates TLS, reads the SNI, and resolves the FQDN **itself**. If the privatelink zone isn't linked to the firewall's own VNet (and DNS proxy isn't enabled), the firewall resolves to the storage account's **public** IP — and with public access denied on the storage account, the connection hangs. This is why a tried application rule was dropped and the day concludes with the **network** rule `allow-spoke1-to-pe`, which worked.

### Exercise 5 — Diagnostics, verify, destroy

**Objective:** three tasks — (1) stand up Log Analytics + a diagnostic setting so rule hits are queryable; (2) verify the firewall's assigned private IP and exercise the whole rule base, recording what you observe against your prediction; (3) destroy the stack.

**Inputs (diagnostics):** LAW `law-vg-lab-wus`; diagnostic setting `diag-vg-lab-wus-fw` on the firewall → the LAW; log categories `AzureFirewallApplicationRule`, `AzureFirewallNetworkRule`, `AzureFirewallDnsProxy`; metric `AllMetrics`.

**Constraints:** use the current `enabled_log {}` block, **not** the deprecated `log {}` form.

**Blocks to write:** `azurerm_log_analytics_workspace.main` (bare — `sku`/retention default fine); `azurerm_monitor_diagnostic_setting.fw` with `target_resource_id`, `log_analytics_workspace_id`, one `metric {}` and three `enabled_log {}` child blocks.

**Verify task — predict, run, record.** First confirm the firewall's IP:
```powershell
terraform console
> azurerm_firewall.hub.ip_configuration[0].private_ip_address   # Predict: ?
```
Then, from the test VMs (via Bastion), exercise each path below. **Predict allow/deny/works for each, run it, and record your result** before reading the solution. After generating traffic, wait ~2–3 min, then query `AzureDiagnostics | where Category == "AzureFirewallNetworkRule"` to see the rule decisions.

| Test | Your prediction (allow / deny / works?) | Your result |
|---|---|---|
| firewall assigned private IP | | |
| spoke1 → spoke2 (ping) | | |
| spoke2 → spoke1 (ping) | | |
| spoke2 → internet | | |
| spoke1 → internet (non-github) | | |
| spoke1 → `https://github.com` | | |
| spoke1 → storage blob PE (`https://stvglabwus01.blob.core.windows.net`) | | |

**Predict (diagnostics build):** `2 to add`.

**Solution** — attempt the build and record your test results above before reading on.

```hcl
# d07ex05-diagnostics.tf
resource "azurerm_log_analytics_workspace" "main" {
  name = local.law_name
  resource_group_name = data.azurerm_resource_group.main.name
  location = data.azurerm_resource_group.main.location
  tags = local.lab_tags
}

resource "azurerm_monitor_diagnostic_setting" "fw" {
  name = "${local.mon_diag_name}-fw"
  target_resource_id = azurerm_firewall.hub.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  metric {
    category = "AllMetrics"
  }
  enabled_log {category = "AzureFirewallApplicationRule"}   # current form; log {} is deprecated on v3.x
  enabled_log {category = "AzureFirewallNetworkRule"}
  enabled_log {category = "AzureFirewallDnsProxy"}
}
```

Expected results:

| Test | Result | Why |
|---|---|---|
| firewall assigned private IP | `172.22.1.4` | first assignable in `AzureFirewallSubnet` — verify, don't assume |
| spoke1 → spoke2 (ping) | allowed | `allow-spoke1workload-to-spoke2workload` (`Any` covers ICMP) |
| spoke2 → spoke1 (ping) | **denied** | `allow-spoke2-to-rfc1918` is TCP-only; ICMP falls through to `deny-spoke2-to-internet`. Over TCP it would be allowed |
| spoke2 → internet | denied | `deny-spoke2-to-internet` |
| spoke1 → internet (non-github) | denied | implicit deny (no matching allow) |
| spoke1 → `https://github.com` | allowed | `allow-spoke1-github` (application rule) |
| spoke1 → storage blob PE | **worked** | `allow-spoke1-to-pe` (network rule); storage stays symmetric — curl returns `PublicAccessNotPermitted`, an app-layer success |

> **Observed (Rule F).** The `AzureFirewallNetworkRule` log shows the storage-PE flow `Allow`ed at the firewall, but the log records only rule decisions on new flows — not established-session return packets — so "no return traffic in the logs" is expected and does not by itself indicate a problem. Separately, the dropped **application-rule** experiment produced the opposite signature: `Allow` in the log yet the connection *hung* — the classic "allowed but wrong resolution / asymmetry" tell (Topic 4).

**Destroy:**
```powershell
terraform destroy     # tears down PIP, policy, RCG, firewall, LAW, diagnostic setting
terraform show        # Predict: empty state
```

**Locals** (relevant): `local.law_name` = `law-${local.prefix}` and `local.mon_diag_name` = `diag-${local.prefix}` — **declared this exercise**.

### Q&A

**Q5 — Spoke1 and spoke2 both default-route to the firewall. Trace a spoke1→spoke2 packet. What forces it through the firewall, and what would BGP propagation on the spoke route tables change?** The spokes have no spoke-to-spoke peering, so spoke2's range matches only spoke1's `0.0.0.0/0 → 172.22.1.4` UDR — the firewall is the sole path, and `allow-spoke1workload-to-spoke2workload` permits it. If BGP route propagation were **on** for the spoke route tables, a learned VNet/peering route could become more specific than the `0.0.0.0/0` UDR and steer inter-spoke traffic *around* the firewall — which is exactly why the spoke route tables keep propagation **off** (Day 4).

---

## Design challenge

### The challenge

1. Every Day-4 UDR pointed at `172.22.1.4` for three days with nothing there. What precisely happened to spoke→internet and spoke→spoke traffic during Days 4–6, and what changed the instant the firewall was applied?
2. The restored `spoke1_to_private_endpoint` route is `172.22.3.0/24 → firewall`, but the PE auto-injects a `/32`. Which route wins for traffic to the PE, does the `/24` UDR actually force PE traffic through the firewall, and if inspection still doesn't work, why — and what would fix it?
3. The firewall lives in `networking/firewall`; its subnet and the UDRs targeting it live in `networking/hub-spoke`. If someone destroys the firewall stack but leaves the base UDRs pointing at `172.22.1.4`, what happens to traffic, and what does the base `terraform plan` say? What does this reveal about the coupling?

### The resolution

1. **Silent blackhole, both flows.** Packets were delivered toward a next-hop IP with no NVA answering and were dropped (no ICMP unreachable). Inter-spoke had no more-specific route (spokes aren't peered to each other), so it also fell to `0.0.0.0/0 → 172.22.1.4`. The instant the firewall answered, every flow began hitting the policy: inter-spoke allowed, spoke1→internet denied except github (app rule), spoke2→internet denied explicitly.

2. **The `/24` wins the forward path — because Day 5 enabled network policies on the PE subnet** (which invalidates the propagated `/32` for VNets with a UDR), so spoke1→PE is steered through the firewall. But *forward steering isn't inspection working*. Two further gates decide that:
   - **Return-path asymmetry.** The PE ignores UDRs on its own subnet and replies straight to the client; a stateful firewall that sees only the forward half drops the flow. **Storage is the documented exception** that stays symmetric — which is why the **network** rule (`allow-spoke1-to-pe`) *worked* in testing (curl returned `PublicAccessNotPermitted`, an app-layer success). For non-storage services you'd need SNAT (network rule) or an application rule (auto-SNAT) for symmetry.
   - **Who resolves the FQDN.** We *also tried* an **application** rule (`allow-spoke1-pe-app`) for the PE and it **hung**, so it was dropped from the end state: the firewall proxies and resolves the storage FQDN *itself*, but the privatelink zone isn't linked to the firewall's hub VNet (and DNS proxy is off), so it resolved to the **public** storage IP — which the storage account (public access denied) refuses. The fix for app-rule PE inspection: link `privatelink.blob.core.windows.net` to the firewall's VNet and enable firewall DNS proxy — but the zone link is a **base** resource, out of scope on a day where the base is frozen except the PE route. Hence the day concludes with the **network** rule.
   - **NSG side effect.** With SNAT/app-rule the PE sees the firewall's private IP, so a source-based PE-subnet NSG (allow spoke1 /24) stops matching; you must allow the firewall subnet and move client-granularity to the firewall.

3. **The base plan lies quiet.** After the firewall stack is destroyed, `172.22.1.4` is empty again, but the base UDRs still target it — so spoke→spoke and spoke→internet blackhole again, exactly like Days 4–6. Yet `terraform plan` on the base reports **No changes**: the base faithfully records its UDRs and has no way to know a resource in a *different* state file vanished, because the UDR targets a **hardcoded string**, not a `remote_state` reference. Terraform's dependency graph cannot span the two stacks.

**What this reveals.** Pre-aiming UDRs at a deterministic placeholder IP is what let the base and firewall be built independently — but it creates an **invisible cross-stack dependency** that neither state file enforces. And UDR-based PE inspection is only the *first* of several gates: forward steering, return symmetry (service-dependent), firewall-side DNS resolution, and NSG source semantics all have to line up. The honest real-world posture: many teams simply **don't** route PE traffic through the firewall — they rely on the PE's inherent privateness plus NSG and private DNS, and reserve inspection for internet-bound and cross-premises flows.

---

## Corrections & gotchas

| # | Gotcha | Correction | Scope |
|---|---|---|---|
| 1 | `terraform console` shows a `terraform_remote_state` read as `(known after apply)` | Never-applied stack hasn't persisted the read; run a no-op `apply` first, then re-read | observed |
| 2 | A mistyped remote-state **output name** also returns `(known after apply)` pre-apply, with no error | Verify output names against the base `outputs.tf`; don't trust a pre-apply console read to validate them | observed |
| 3 | `.address_prefix` (singular) on the subnet data source | Deprecated on azurerm v3.x — use `.address_prefixes[0]` | universal |
| 4 | VM data source: reaching for `private_ip_addresses[0]` as "future-proofing" | `private_ip_address` (singular = primary) is **not** deprecated and is the correct intent; `[0]` is a different, positional semantic. Here the value is single-sourced as a static local instead | universal |
| 5 | Cross-stack: expecting to read the base's locals/variables | `terraform_remote_state` exposes root **outputs only**; re-declare anything else (RG, subnets) as local `data` sources | universal |
| 6 | Assuming RCG/collection priority orders all rules | **Rule TYPE beats priority**: network pass runs entirely before application pass; priority only orders within a pass | universal |
| 7 | Looking for an `action` on a `rule {}` block | Action lives on the **collection**; rules carry match criteria only | universal |
| 8 | spoke2→spoke1 ping denied despite `allow-spoke2-to-rfc1918` | That allow is `protocols = ["TCP"]`; ICMP isn't matched and falls to `deny-spoke2-to-internet`. Test over TCP to see it allowed | lab-specific (rule scoping) |
| 9 | Expecting a stateful firewall to inspect PE return traffic | PEs ignore UDRs on their own subnet and reply direct → asymmetry → dropped. Storage is the exception; SNAT / app rules restore symmetry | universal (documented) |
| 10 | App-rule PE inspection hangs though the firewall shows `Allow` | The firewall resolves the FQDN itself; if the privatelink zone isn't linked to the firewall's VNet (+ DNS proxy), it resolves **public** and a locked-down storage account refuses it | universal (documented) |
| 11 | SNAT for intra-VNet PE traffic breaks source-based PE-subnet NSG | SNAT uses the firewall's **private** IP; the NSG then sees the firewall, not the client — allow the firewall subnet, move granular control to the firewall | universal |
| 12 | `log { }` block on the diagnostic setting | Deprecated on azurerm v3.x — use `enabled_log { category = ... }` | universal |
| 13 | After destroying the firewall stack, base `plan` says "No changes" but traffic blackholes | Base UDRs target a hardcoded `172.22.1.4` in another state file; the dependency is real but unenforced by either state | design lesson |
| 14 | Trying to model the CLI's two-step `firewall create` + `ip-config` | It's **one** declarative `azurerm_firewall` — the `ip_configuration` block is the second step | CLI-vs-TF |
| 15 | An application-rule PE approach (`allow-spoke1-pe-app`) was tested and **dropped** | It hung (firewall resolves FQDN public → storage public-deny) and would need the base privatelink zone linked to the firewall VNet + DNS proxy + PE-NSG rework for SNAT. End state ships the working network rule `allow-spoke1-to-pe` (Lab-6-faithful) | dropped experiment |