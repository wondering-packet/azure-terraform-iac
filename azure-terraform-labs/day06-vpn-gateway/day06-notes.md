# Day 6 — VPN Gateway & Hybrid Connectivity

> **How to use this guide.** Each topic's theory gives you the building blocks — not the
> finished answer. Each exercise names the resource blocks to write and states the problem;
> you derive the attributes yourself from the Terraform docs and the CLI lab, predict the
> plan, then read the solution and run it. This is the first **ephemeral-stack** day: a
> brand-new state key that reads the base and is torn down at the end.

> **Working the exercises.** From this day on, each exercise gives you the **resource block name(s)** and any **required child blocks**, not a full skeleton. Derive the attributes yourself: in VS Code, type the `resource "<type>" "<label>" {}` block and **hover the resource type** — the azurerm docs pop up inline — and cross-check `azurecli_lab5.md` for the exact lab values. The one exception is Exercise 3 (gateways), which is complex enough to get a barebones skeleton. BGP fundamentals are assumed knowledge this day.

## File & marker conventions

- `d06…` files are day-scoped (`d06ex01-pips.tf`, `d06ex02-onprem.tf`, …).
- Shared files (`locals.tf`, `variables.tf`, `backend.tf`, `main.tf`, `terraform.tfvars`) carry inline markers: `###---d06exNN >>>` / `<<<`.
- The base read lives in its own `remote-state.tf`, kept separate from `backend.tf` — both hold `azurerm` config but do different jobs (one configures *this* stack's state, one *reads* another's).

## Prerequisites & continuity

Days 0–5 are done; this guide does not re-teach subnets, peering, routing, DNS, Private Endpoints, state, or HCL.

**Live right now** in `networking/hub-spoke` (the base, read-only from here): the full hub+spoke topology, peering, routing, `internal.lab.com` + `privatelink.blob…` DNS, the storage Private Endpoint, and the base outputs. The hub `GatewaySubnet` (`172.22.0.0/27`) exists and sits **empty** — waiting since Day 3 for this day's gateway.

**What this day does:** stand up a *separate* stack under a new key `networking/vpn` that reads the base's GatewaySubnet through `terraform_remote_state`, builds a simulated on-prem VNet with its own gateway, establishes a BGP-enabled site-to-site VPN between "hub" and "on-prem," proves BGP route learning across the tunnel, then **destroys** the whole stack. Everything here is ephemeral (~$5 of gateway for ~2 hours). The base is never written from this stack.

**What Day 7 inherits / must do:** builds Azure Firewall in `networking/firewall`, and **must restore the commented-out `spoke1_to_private_endpoint` route** carried over from Day 5 (a Day 7 action, not this day's).

## Standard lab environment

| Setting | Value |
|---|---|
| Subscription | Infrastructure Networking Dev/Test — `<your-subscription-id>` |
| Region / RG | `westus` / `rg-vg-lab-wus-01` |
| State key (this day) | `networking/vpn` — new, ephemeral stack |
| Base state (read-only) | `networking/hub-spoke` via `terraform_remote_state` |
| Backend / auth | `stvglabwustfstate` / `tfstate` — Azure AD (`use_azuread_auth` + `use_cli`) — `default` workspace |
| Provider | `azurerm` v3.117.1 (`~> 3.100`) |
| OS / shell | Windows / PowerShell — backtick (`` ` ``) line continuation |
| Key base resource read | hub `GatewaySubnet` `172.22.0.0/27` (empty, base-owned) |
| Key resource built | on-prem sim VNet `172.22.64.0/20` |

## Table of contents

1. [Exercise 0 — new-stack setup and remote-state gate](#exercise-0--new-stack-setup-and-remote-state-gate)
2. [Topic 1 — Why the VPN is a separate stack](#topic-1--why-the-vpn-is-a-separate-stack)
3. [Topic 2 — VPN gateways and the gateway-transit payoff](#topic-2--vpn-gateways-and-the-gateway-transit-payoff)
4. [Topic 3 — Local Network Gateways and Connections](#topic-3--local-network-gateways-and-connections)
5. [Topic 4 — BGP over the tunnel](#topic-4--bgp-over-the-tunnel)
6. [Design challenge — the coupling that straddles the boundary](#design-challenge--the-coupling-that-straddles-the-boundary)
7. [Corrections and gotchas](#corrections-and-gotchas)

---

## Exercise 0 — new-stack setup and remote-state gate

**Objective:** stand up the `day06-vpn-gateway` folder as a **VPN-only** stack with its own state key, wire a `terraform_remote_state` read of the base, and prove a clean plan before building anything.

This is the copy-and-validate gate adapted for a *new* stack. There is no prior VPN state to be zero-change against, so the gate is different: **the remote-state read must resolve, and the plan must run without error.**

**Inputs:**

| Item | Value |
|---|---|
| Copy from | `day05-private-endpoints` |
| New folder | `day06-vpn-gateway` |
| New backend key | `networking/vpn` |
| Base key to read | `networking/hub-spoke` |
| Backend SA / container | `stvglabwustfstate` / `tfstate` |
| Workspace | `default` |

**Constraints:**

- The copied folder carries every base resource `.tf` (hub VNet, subnets, peering, routing, DNS, PE, storage, test rig). **Remove them all.** This stack's blob starts empty; leaving base resources in with the new key makes `plan` propose to *re-create* the entire hub topology — a duplicate that collides with the real base. Slimming is not cosmetic.
- Keep only reusable scaffolding: the provider block, `backend.tf` (repointed), the naming chain in `locals.tf`, the variables the VPN actually needs, and an **empty** `outputs.tf` (the base's outputs reference base resources and will hard-error otherwise).
- **Re-declare, as local `data` sources, any base resource you need that is NOT a base output.** `terraform_remote_state` exposes *only* the base's published outputs — locals and variables of the base are unreachable. The resource group is the obvious one (used constantly, not an output), so it goes in `d06-base.tf`. Any other non-output base resource you end up needing follows the same pattern: re-look-it-up locally.
- The base read requires Azure AD in the data-source `config` — the base SA has shared-key disabled, so without `use_azuread_auth`/`use_cli` the read silently 403s.

**Blocks to write:**

- `backend.tf` — repoint the existing `terraform { backend "azurerm" {} }` `key` to `networking/vpn`.
- `remote-state.tf` — `data "terraform_remote_state" "base"` pointed at key `networking/hub-spoke` (mirror the AAD flags into its `config`).
- `d06-base.tf` — the resource-group re-lookup. Skeleton (fill the one attribute yourself using the workspace-aware naming chain):

```hcl
# d06-base.tf — base resources that are NOT published as outputs get re-declared here.
# terraform_remote_state gives you outputs ONLY, so the RG is looked up locally.
data "azurerm_resource_group" "main" {
  name = # ?  -> build from the naming chain so it resolves to rg-vg-lab-wus-01
}
```

**Predict:** with zero resource blocks written yet, `terraform plan` prints `No changes` — not because it is diffing a prior VPN state (there is none) but because you have declared nothing to build. A `terraform_remote_state` block is a *data source*: read, never created. The real proof is that `init -reconfigure` succeeds against the new key and the remote read resolves.

**Solution** — try the setup above before reading on.

`backend.tf`:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-vg-lab-wus-01"
    storage_account_name = "stvglabwustfstate"
    container_name       = "tfstate"
    key                  = "networking/vpn"   # this stack's OWN blob, separate from the base
    use_azuread_auth     = true
    use_cli              = true
  }
}
```

`remote-state.tf`:

```hcl
data "terraform_remote_state" "base" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-vg-lab-wus-01"
    storage_account_name = "stvglabwustfstate"
    container_name       = "tfstate"
    key                  = "networking/hub-spoke"  # reads the BASE blob (read-only)
    use_azuread_auth     = true  # load-bearing: base SA shared-key disabled, must use AAD
    use_cli              = true  # authenticate with the current az CLI session
  }
}
```

`d06-base.tf`:

```hcl
data "azurerm_resource_group" "main" {
  name = "${local.rg_name}-01"   # workspace-aware -> rg-vg-lab-wus-01 in the default workspace
}
```

**Locals** (relevant): `local.rg_name` (`rg-${local.prefix}` → `rg-vg-lab-wus`) — used by `d06-base.tf` to build the RG name. Declared on an earlier day; reused here.

Run it:

```powershell
terraform init -reconfigure   # backend key changed, so -reconfigure is required
terraform workspace show      # must be: default
terraform plan                # must be: No changes
```

Prove the cross-stack read actually resolves:

```powershell
terraform console
> data.terraform_remote_state.base.outputs.gateway_subnet_id
> exit
```

> **Observed quirk — console may show `(known after apply)`.** On a freshly `init`+`plan`ed stack that has never been applied, the `terraform_remote_state` read isn't yet persisted into local state, so `terraform console` can print the base outputs as `(known after apply)` instead of the real value. Running a **no-op `terraform apply`** first (nothing to create, but it refreshes and stores the data-source read) makes the console print the concrete IDs. If your console output looks unresolved, apply once and retry.

> **`terraform output` vs `terraform console`.** `terraform output NAME` prints *this* stack's own root outputs by *name* — it cannot evaluate an expression and returns "No outputs found" here because this stack publishes none. `terraform console` evaluates arbitrary HCL, including a cross-stack `data.terraform_remote_state…` expression.

---

## Topic 1 — Why the VPN is a separate stack

### Theory

Days 3–5 all extended **one** state (`networking/hub-spoke`). Day 6 breaks that pattern. A VPN gateway earns its own state key for three reasons:

- **Independent lifecycle.** The base is permanent; the gateway is torn down nightly for cost (or, in production, resized/patched on its own cadence). Different change frequency, different state.
- **Blast radius.** A botched apply on the VPN stack cannot corrupt or lock the base state blob — they are separate files.
- **Ownership boundary.** In the real world a platform team owns the hub while a connectivity team owns hybrid links.

The cost of splitting: this stack no longer has the hub's resources in its own state, so it cannot reference them by a normal `azurerm_…` address. It reads them across the boundary with `terraform_remote_state`, and the base's published **outputs** become this stack's inputs:

```hcl
# consume a base output anywhere in this stack:
data.terraform_remote_state.base.outputs.<output_name>
```

Two properties matter. It reads **published outputs only** — locals and variables of the base are *not* reachable, only what the base explicitly `output`-ed; the outputs are the stack's public API and everything else is private. And the **dependency is one-way**: vpn reads hub-spoke, never the reverse; the base has no idea this stack exists.

Exercise 0 above is Topic 1's hands-on: you built the separate key, proved the read resolves, and saw why the RG had to be re-declared (it isn't an output).

### Q&A

**Q1 — `terraform_remote_state` reads the base's `gateway_subnet_id`. What is it reading, and what breaks if the base never `output`-ed that value?**
It reads the base's *published root output* named `gateway_subnet_id` (repointed to the standalone `hub_gateway` resource in the Day 5 refactor) out of the base blob. If the base only *declared* the resource but never `output`-ed its ID — or never applied that output — the read errors with "This object does not have an attribute named gateway_subnet_id." The cross-stack contract is exactly the outputs the base chose to publish, nothing else — which is also why you can't reach `base` locals or variables, only outputs.

---

## Topic 2 — VPN gateways and the gateway-transit payoff

### Theory

The VPN gateway deploys **into** the empty `GatewaySubnet` that has waited since Day 3. It is the slowest resource in Azure networking — **25–45 minutes** — because Azure stands up dedicated gateway VM instances, wires the routing/BGP engine, and allocates a BGP peer IP from the GatewaySubnet range. Fire the apply and walk away; that is why the supporting resources (public IPs, on-prem VNet) are built first, so the gateway apply starts early.

The gateway's behavior is defined by a few choices you'll set: it is a `Vpn` gateway (not ExpressRoute), `RouteBased` (required for BGP; PolicyBased is legacy static-only), SKU `VpnGw1AZ` (the AZ SKU, mandatory for new gateways), and a BGP speaker (`enable_bgp` at the top level). It also needs child blocks — an `ip_configuration` and a `bgp_settings` — which the exercise calls out.

Two supporting builds come first. **Standard-SKU public IPs**: an AZ gateway attaches only a Standard PIP with Static allocation — the provider default is Basic, which the gateway rejects. And a **simulated on-prem VNet**: a *second* Azure VNet that plays on-prem, purely to produce a real IKE/IPsec negotiation and eBGP session to observe. In production you would never VPN two same-region Azure VNets — you would peer them. This is a teaching rig, not a pattern.

> **The gateway-transit payoff.** The hub peerings have carried `allow_gateway_transit = true` since Day 4, doing nothing because no gateway existed. Once this gateway is live, that flag finally means something: the hub can share its gateway with the spokes. The *other* half — `use_remote_gateways = true` on the spoke peerings — lives in the **base** state, and flipping it is the design challenge at the end of this guide.

### Exercise 1 — Public IPs (`d06ex01-pips.tf`)

**Objective:** two Standard-SKU public IPs, one per gateway.

**Inputs:**

| Name | Purpose | SKU | Allocation |
|---|---|---|---|
| `pip-vg-lab-wus-vpngw` | hub gateway | Standard | Static |
| `pip-vg-lab-wus-vpngw-onprem` | on-prem gateway | Standard | Static |

**Constraints:** Standard SKU **and** Static allocation. Do not set `zones` — leaving it unset gives the zone-redundant default that matches an AZ gateway.

**Blocks to write:** `azurerm_public_ip.hub_vpngw`, `azurerm_public_ip.onprem_vpngw`. No child blocks. Hover the type in VS Code for the `sku` / `allocation_method` attributes; the names come from the inputs table.

**Predict:** `2 to add`. The `sku` line must read `Standard` — if it shows `Basic` (the provider default), the gateway create in Exercise 3 fails.

**Solution** — try the exercise above before reading on.

```hcl
resource "azurerm_public_ip" "hub_vpngw" {
  name                = "${local.pip_name}-vpngw"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  allocation_method   = "Static"    # Standard SKU is always Static; Dynamic is not allowed on Standard
  sku                 = "Standard"   # required for an AZ gateway; provider default is Basic (rejected)
  tags                = local.lab_tags
}
resource "azurerm_public_ip" "onprem_vpngw" {
  name                = "${local.pip_name}-vpngw-onprem"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.lab_tags
}
```

**Locals** (relevant): `local.pip_name` = `pip-${local.prefix}` (`pip-vg-lab-wus`) — **declared this exercise** in `locals.tf`. Also uses `local.lab_tags` (the standard tag block from Day 5).

> The causal chain: it is **not** "Static forces Standard." An AZ gateway needs a Standard PIP, and Standard SKU is always Static. On a Basic PIP you could have used Dynamic.

### Exercise 2 — On-prem sim VNet + subnets (`d06ex02-onprem.tf`)

**Objective:** the second Azure VNet that plays on-prem, with its own GatewaySubnet and a workload subnet.

**Inputs:**

| Resource | Name | CIDR |
|---|---|---|
| VNet | `vnet-vg-lab-wus-onprem` | `172.22.64.0/20` |
| Gateway subnet | `GatewaySubnet` (exact literal) | `172.22.64.0/27` |
| Workload subnet | `snet-vg-lab-wus-onprem-workload` | `172.22.65.0/24` |

**Constraints:** `GatewaySubnet` must be the exact literal string — Azure validates the name at gateway-create time. No NSG, no route table on it. **Do not peer this VNet to the hub** — peering would short-circuit the tunnel the lab exists to demonstrate.

**Blocks to write:** `azurerm_virtual_network.onprem`, `azurerm_subnet.onprem_gateway`, `azurerm_subnet.onprem_workload`. No child blocks (subnets are separate resources, not inline). You'll also add an `onprem` variable that bundles the VNet address space and both subnets into one object — check the CLI lab for the CIDRs.

**Predict:** `3 to add` for this file. If you named the gateway subnet `gatewaysubnet` (lowercase), this apply *succeeds* but the gateway create in Exercise 3 fails fast with a name-validation error.

**Solution** — try the exercise above before reading on.

```hcl
resource "azurerm_virtual_network" "onprem" {
  name                = "${local.vnet_name}-onprem"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  address_space       = [var.onprem.vnet.main.address_space]   # bundled in the onprem object, not a leftover base var
}

resource "azurerm_subnet" "onprem_gateway" {
  resource_group_name  = data.azurerm_resource_group.main.name
  name                 = "GatewaySubnet"   # exact literal — Azure requires this name for a gateway subnet
  virtual_network_name = azurerm_virtual_network.onprem.name
  address_prefixes     = [var.onprem.subnets_special.GatewaySubnet.cidr]
}

resource "azurerm_subnet" "onprem_workload" {
  name                 = "${local.snet_name}-onprem-workload"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.onprem.name
  address_prefixes     = [var.onprem.subnets.workload.cidr]
}
```

The variable and its values (`variables.tf` + `terraform.tfvars`):

```hcl
# variables.tf
variable "onprem" {
  type = object({
    vnet = map(object({ address_space = string }))
    subnets = map(object({ cidr = string }))
    subnets_special = map(object({ cidr = string }))
  })
}
```

```hcl
# terraform.tfvars
onprem = {
  vnet = {
    "main" = { address_space = "172.22.64.0/20" }
  }
  subnets = {
    "workload" = { cidr = "172.22.65.0/24" }
  }
  subnets_special = {
    "GatewaySubnet" = { cidr = "172.22.64.0/27" }
  }
}
```

**Locals** (relevant): `local.vnet_name` (`vnet-vg-lab-wus`) and `local.snet_name` (`snet-vg-lab-wus`) — both declared on earlier days, reused here. No new local this exercise.

Run Exercises 1 + 2 together (both are seconds), so the gateway apply in Exercise 3 starts as early as possible:

```powershell
terraform plan    # expect: 5 to add (2 PIPs + on-prem VNet + 2 subnets), 0 to change
terraform apply
```

### Exercise 3 — Both VPN gateways (`d06ex03-gateways.tf`)

**Objective:** build both gateways. The hub gateway attaches to the **base's** GatewaySubnet, read via remote state; the on-prem gateway attaches to its own local GatewaySubnet.

**Inputs:**

| Gateway | Name | ASN | subnet_id source |
|---|---|---|---|
| Hub | `vpngw-vg-lab-wus-hub` | 65010 | `data.terraform_remote_state.base.outputs.gateway_subnet_id` |
| On-prem | `vpngw-vg-lab-wus-onprem` | 65000 | `azurerm_subnet.onprem_gateway.id` |

**Constraints:** `type = "Vpn"`, `vpn_type = "RouteBased"`, `sku = "VpnGw1AZ"`, `active_active = false`, `enable_bgp = true`. Do **not** hardcode the BGP peer IP — Azure auto-assigns it from the GatewaySubnet; you'll reference it as an attribute in Exercise 4. ASNs must differ (65010 vs 65000); never 65515 (Azure-reserved).

**Blocks to write:** `azurerm_virtual_network_gateway.hub`, `azurerm_virtual_network_gateway.onprem`. Each needs **two child blocks**: an `ip_configuration {}` and a `bgp_settings {}`. Because this one is more involved, here's the barebones skeleton — fill the attributes from the docs and the inputs table:

```hcl
resource "azurerm_virtual_network_gateway" "hub" {
  # top-level: name, resource_group_name, location, type, sku, vpn_type, active_active, enable_bgp
  ip_configuration {
    # subnet_id (HUB: from remote state), public_ip_address_id, private_ip_address_allocation
  }
  bgp_settings {
    # asn (hub = 65010) — peer IP is auto-assigned, do NOT set it here
  }
}
# second block: azurerm_virtual_network_gateway.onprem — same shape, onprem subnet + ASN 65000
```

**Predict:** `2 to add`. The hub gateway's `subnet_id` shows a **concrete** base-subnet ID at plan time (the subnet already exists, in another state); the two gateways provision **in parallel** (~40 min), not serially, because neither depends on the other.

**Solution** — try the exercise above before reading on.

```hcl
resource "azurerm_virtual_network_gateway" "hub" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  name                = "${local.vpngw_name}-hub"
  type                = "Vpn"
  sku                 = "VpnGw1AZ"
  vpn_type            = "RouteBased"
  active_active       = false
  enable_bgp          = true
  ip_configuration {
    # THE cross-stack read: this gateway attaches to a subnet owned by networking/hub-spoke,
    # which this stack does not and will not manage.
    subnet_id                     = data.terraform_remote_state.base.outputs.gateway_subnet_id
    public_ip_address_id          = azurerm_public_ip.hub_vpngw.id
    private_ip_address_allocation = "Dynamic"
  }
  bgp_settings {
    asn = 65010   # hub ASN; Azure auto-assigns the peer IP (do not hardcode)
  }
}

resource "azurerm_virtual_network_gateway" "onprem" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  name                = "${local.vpngw_name}-onprem"
  type                = "Vpn"
  sku                 = "VpnGw1AZ"
  vpn_type            = "RouteBased"
  active_active       = false
  enable_bgp          = true
  ip_configuration {
    subnet_id                     = azurerm_subnet.onprem_gateway.id   # local subnet, this stack owns it
    public_ip_address_id          = azurerm_public_ip.onprem_vpngw.id
    private_ip_address_allocation = "Dynamic"
  }
  bgp_settings {
    asn = 65000   # on-prem ASN — must differ from the hub's
  }
}
```

**Locals** (relevant): `local.vpngw_name` = `vpngw-${local.prefix}` (`vpngw-vg-lab-wus`) — **declared this exercise** in `locals.tf`.

```powershell
terraform plan     # expect: 2 to add, 0 to change
terraform apply    # ~40 min; both gateways build in parallel — let it run
```

### Q&A

**Q2 — Two VpnGw1AZ gateways provision for ~40 minutes. Why so long, and what is the pipeline implication?**
Azure is not flipping a config bit — it provisions dedicated gateway VM instances, wires the routing/BGP control plane, and allocates the GatewaySubnet BGP IP. The pipeline implication: a naive apply timeout will kill the run mid-provision. Gateways belong in their own long-timeout stage (or an out-of-band pre-provision), never inline with fast resource applies. The `terraform apply` here blocks the terminal for the full duration; there is no `--no-wait` equivalent, but independent gateways parallelize, so it is ~40 min total, not ~80.

---

## Topic 3 — Local Network Gateways and Connections

### Theory

The gateways can terminate a tunnel but do not yet know *who is on the other end*. The **Local Network Gateway (LNG)** is that data object — it represents the remote peer: its public IP (where to dial IKE/IPsec) and its BGP identity (ASN + BGP peer address). It provisions instantly; it is metadata, not infrastructure.

Because both ends are in Azure, there are **two** LNGs, and the rule that prevents confusion is: **every field in one LNG describes the single remote peer it represents** — `gateway_address`, `asn`, `bgp_peering_address`, and the `address_space` bootstrap route all point at the *same* gateway.

Two IPs on the LNG are easy to conflate:

- `gateway_address` — the remote gateway's **public** IP, for IKE/IPsec tunnel setup over the internet.
- `bgp_settings.bgp_peering_address` — the remote gateway's **private** BGP peer IP from its GatewaySubnet. BGP runs *inside* the tunnel, never over the public IP. Point BGP at the public IP and the tunnel comes up with zero routes exchanged — a silent failure.

The Terraform improvement over the CLI lab: the CLI told you to note each BGP peering address by hand and paste it in. Here you **reference the gateway's computed attribute** instead, so it is correct even if Azure assigns a different address. This attribute path is non-obvious, so here it is explicitly:

```hcl
# the auto-assigned BGP peer IP, read straight off the gateway resource:
azurerm_virtual_network_gateway.<name>.bgp_settings[0].peering_addresses[0].default_addresses[0]
```

That attribute is a **bare IP** (`172.22.0.30`). Two LNG fields consume it in two shapes: `bgp_peering_address` wants the bare IP; `address_space` wants it as a **/32 CIDR**, built by appending `/32` in an interpolation.

**What goes in `address_space` with BGP on?** Just the remote BGP peer as a `/32` host route — the bootstrap that lets the local gateway reach the remote BGP peer through the tunnel to *establish* the session. Once BGP is up it advertises every real prefix dynamically. (`address_space` is the same field the CLI calls `--local-address-prefixes`.) Without BGP you would list every remote CIDR here as static routes instead.

The **Connection** joins a gateway to an LNG and carries `type = "IPsec"`, the pre-shared `shared_key`, and `enable_bgp = true`. There are two, one per direction, and the pairing is **crossed** — a connection consumes the LNG representing the *opposite* side.

> **`enable_bgp` in two places is not redundancy.** On the gateway it is a *capability* — "this gateway is a BGP speaker," which is what made Azure allocate its peer IP and ASN. On the connection it is *activation* — "run BGP over *this* tunnel." A BGP-capable gateway can run dynamic routing on one connection and static on another. Both must be true for routes to exchange on a given link.

### Exercise 4 — Local Network Gateways (`d06ex04-lng.tf`)

**Objective:** two LNGs, each representing the remote peer, with the auto-assigned BGP peer IP referenced (not hardcoded).

**Inputs:**

| LNG | Represents | `gateway_address` | `asn` | `bgp_peering_address` |
|---|---|---|---|---|
| `lng-vg-lab-wus-onprem` | on-prem | on-prem public IP | 65000 | on-prem peer (`172.22.64.30`) |
| `lng-vg-lab-wus-hub` | hub | hub public IP | 65010 | hub peer (`172.22.0.30`) |

**Constraints:** within each LNG, **all four fields describe the same gateway**. `address_space` is that gateway's BGP peer IP as a `/32`. Reference `default_addresses[0]` (see the theory attribute path); do not hardcode.

**Blocks to write:** `azurerm_local_network_gateway.onprem`, `azurerm_local_network_gateway.hub`. Each needs a **child `bgp_settings {}` block** (holds `asn` + `bgp_peering_address`). The `gateway_address` and `address_space` are top-level. Hover the type for the exact attribute names.

**Predict:** `2 to add`. Each LNG's `address_space` /32 must match its own `bgp_peering_address` (`lng.hub` → `172.22.0.30/32`, `lng.onprem` → `172.22.64.30/32`). If they disagree, the /32 is crossed.

**Solution** — try the exercise above before reading on.

```hcl
resource "azurerm_local_network_gateway" "onprem" {   # represents on-prem
  name                = "${local.lng_name}-onprem"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  # bootstrap /32 = on-prem's own BGP peer IP, built from the bare attribute + "/32"
  address_space   = ["${azurerm_virtual_network_gateway.onprem.bgp_settings[0].peering_addresses[0].default_addresses[0]}/32"]
  gateway_address = azurerm_public_ip.onprem_vpngw.ip_address   # remote PUBLIC ip, for IKE/IPsec
  bgp_settings {
    asn                 = 65000                                  # on-prem ASN
    bgp_peering_address = azurerm_virtual_network_gateway.onprem.bgp_settings[0].peering_addresses[0].default_addresses[0]
  }
}

resource "azurerm_local_network_gateway" "hub" {      # represents the hub
  name                = "${local.lng_name}-hub"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  address_space   = ["${azurerm_virtual_network_gateway.hub.bgp_settings[0].peering_addresses[0].default_addresses[0]}/32"]
  gateway_address = azurerm_public_ip.hub_vpngw.ip_address
  bgp_settings {
    asn                 = 65010                                  # hub ASN
    bgp_peering_address = azurerm_virtual_network_gateway.hub.bgp_settings[0].peering_addresses[0].default_addresses[0]
  }
}
```

**Locals** (relevant): `local.lng_name` = `lng-${local.prefix}` (`lng-vg-lab-wus`) — **declared this exercise** in `locals.tf`.

> Both `address_space` and `bgp_peering_address` in one LNG read from the **same** gateway — `.onprem` in the on-prem LNG, `.hub` in the hub LNG. Crossing them (a real mistake caught mid-session) leaves each gateway without a tunnel route to the peer it must reach: the tunnel still comes up, but BGP never establishes and no routes are learned.

### Exercise 5 — Connections (`d06ex05-connections.tf`)

**Objective:** two BGP-enabled IPsec connections, one per direction.

**Inputs:**

| Connection | On gateway | Consumes LNG | shared_key |
|---|---|---|---|
| `conn-vg-lab-wus-onprem-to-hub` | on-prem | `lng…hub` | `Azure123!` |
| `conn-vg-lab-wus-hub-to-onprem` | hub | `lng…onprem` | `Azure123!` |

**Constraints:** the pairing is crossed — the connection on the on-prem gateway dials the hub, so it consumes the **hub** LNG. `local_network_gateway_id` is required for `type = "IPsec"`. The `shared_key` must be identical on both ends.

**Blocks to write:** `azurerm_virtual_network_gateway_connection.gw_onprem_to_lng_hub`, `azurerm_virtual_network_gateway_connection.gw_hub_to_lng_onprem`. No child blocks. The three IDs/keys you need — `virtual_network_gateway_id`, `local_network_gateway_id`, `shared_key` — plus `type` and `enable_bgp`; hover the type for exact names.

**Predict:** `2 to add`. Both connections carry `enable_bgp = true`; `shared_key` renders as `(sensitive value)`.

**Solution** — try the exercise above before reading on.

```hcl
resource "azurerm_virtual_network_gateway_connection" "gw_onprem_to_lng_hub" {
  resource_group_name        = data.azurerm_resource_group.main.name
  name                       = "${local.gw_conn_name}-onprem-to-hub"
  location                   = data.azurerm_resource_group.main.location
  virtual_network_gateway_id = azurerm_virtual_network_gateway.onprem.id   # sits on the on-prem gateway
  local_network_gateway_id   = azurerm_local_network_gateway.hub.id        # dials the HUB (opposite side)
  type                       = "IPsec"
  shared_key                 = var.vpn_shared_key                          # must match the other connection
  enable_bgp                 = true                                        # activate BGP on THIS tunnel
}

resource "azurerm_virtual_network_gateway_connection" "gw_hub_to_lng_onprem" {
  resource_group_name        = data.azurerm_resource_group.main.name
  name                       = "${local.gw_conn_name}-hub-to-onprem"
  location                   = data.azurerm_resource_group.main.location
  virtual_network_gateway_id = azurerm_virtual_network_gateway.hub.id      # sits on the hub gateway
  local_network_gateway_id   = azurerm_local_network_gateway.onprem.id     # dials ON-PREM (opposite side)
  type                       = "IPsec"
  shared_key                 = var.vpn_shared_key
  enable_bgp                 = true
}
```

The shared key comes from a variable, set in tfvars for the lab:

```hcl
# variables.tf
variable "vpn_shared_key" {
  type = string
}
```

```hcl
# terraform.tfvars
vpn_shared_key = "Azure123!"
```

**Locals** (relevant): `local.gw_conn_name` = `conn-${local.prefix}` (`conn-vg-lab-wus`) — **declared this exercise** in `locals.tf`.

```powershell
terraform plan     # expect: 4 to add (2 LNGs + 2 connections), 0 to change
terraform apply    # LNGs and connections are seconds, not minutes
```

> Hardcoding a PSK in tfvars matches the CLI lab, but in production it is a real anti-pattern — the shared key would come from Key Vault or a pipeline secret, never committed.

### Q&A

**Q3 — Why two connection resources instead of one? What must each direction's shared key match?**
A Connection is unidirectional configuration — it defines how *this* gateway dials *that* peer. Each gateway needs its own outbound config, so each end gets a Connection. Both `shared_key` values must be identical (`Azure123!`); the PSK authenticates the IKE negotiation, and a mismatch means the tunnel never authenticates.

---

## Topic 4 — BGP over the tunnel

### Theory

With both connections up and `enable_bgp = true`, each gateway opens a BGP session to the other's **private** peer IP *through* the established IPsec tunnel, and routes flow dynamically. The ASNs — hub `65010`, on-prem `65000` — **must differ** (this is eBGP, between different autonomous systems). `65515` is off-limits: it is Azure's reserved default and an LNG rejects it.

The Azure-specific payoff is **gateway transit**: the hub advertises not just its own VNet but the *spoke* prefixes too, once the transit flags are set. The spoke prefixes reach on-prem stamped with the **hub's** ASN (65010), because the spokes are not autonomous systems — they are peered VNets whose prefixes the hub originates into BGP on their behalf. Expected on-prem learned routes:

```
172.22.0.0/20   via 172.22.0.30  AS-PATH 65010   (hub VNet)
172.22.16.0/20  via 172.22.0.30  AS-PATH 65010   (spoke1, advertised through the hub)
172.22.32.0/20  via 172.22.0.30  AS-PATH 65010   (spoke2)
```

The spoke-advertising half depends on the Day-4 `allow_gateway_transit = true` (already set on the hub peerings) **plus** `use_remote_gateways = true` on the spoke peerings — which lives in the base state. That crossing is the design challenge below.

### Exercise 6 — Verify BGP, then destroy

**Objective:** confirm the on-prem gateway learned the hub and both spoke prefixes via AS 65010, then tear the stack down.

**Constraints:** verify *before* destroying. Teardown order is load-bearing (see below). This stack is destroyed; the base must end untouched.

**Predict:** with the base untouched, on-prem learns only `172.22.0.0/20` — the two spoke `/20`s appear **only after** `use_remote_gateways` is flipped on the spoke peerings (a base-side change).

**Solution** — verify:

```powershell
# LEARNED ROUTES — this works and is the real proof:
az network vnet-gateway list-learned-routes `
  --resource-group rg-vg-lab-wus-01 `
  --name vpngw-vg-lab-wus-onprem `
  --output table
```

Observed learned-routes table (all three Azure prefixes present after the flag flip):

```
Network         NextHop      Origin    SourcePeer    AsPath    Weight
172.22.64.0/20               Network   172.22.64.30            32768   # on-prem's own VNet
172.22.0.30/32               Network   172.22.64.30            32768   # the LNG bootstrap /32 doing its job
172.22.0.0/20   172.22.0.30  EBgp      172.22.0.30   65010     32768   # hub VNet
172.22.16.0/20  172.22.0.30  EBgp      172.22.0.30   65010     32768   # spoke1, via the hub
172.22.32.0/20  172.22.0.30  EBgp      172.22.0.30   65010     32768   # spoke2, via the hub
```

> **Connection status must be checked in the portal.** `az network vpn-connection list --query "[].{status:connectionStatus}"` does **not** return the status reliably (observed empty output — the same problem that came up in the CLI labs). To confirm the tunnel is `Connected`, use the portal: **Virtual network gateway → `vpngw-vg-lab-wus-onprem` → Connections**. Don't rely on the CLI for connection status.

**Teardown — revert the base flag first, then destroy.** Destroying the hub gateway while spoke peerings still reference it via `use_remote_gateways = true` can leave the gateway wedged in a **Failed** provisioning state that requires Resource Explorer surgery to clear.

```powershell
# 1. In the BASE folder (day05-private-endpoints, key networking/hub-spoke):
#    set use_remote_gateways = false on both spoke peerings, then:
terraform apply        # expect: 2 to change — detaches spokes while the gateway still exists

# 2. In the VPN folder (key networking/vpn):
terraform destroy      # Terraform orders connections -> gateways -> LNGs -> PIPs; ~15-20 min for gateway delete

# 3. Prove the base survived (this is Q6):
#    back in the BASE folder:
terraform plan         # expect: No changes — base is bit-for-bit at its Day-5 end state
```

A future relaunch is `terraform apply` in the VPN folder — the config is left fully intact (no commented-out blocks). The auto-assigned BGP peer IPs re-derive from `default_addresses[0]`, so a rebuild needs no edits; the one thing to remember is to re-flip `use_remote_gateways` in the base again for spoke advertisement.

### Q&A

**Q4 — On-prem learns `172.22.16.0/20` (spoke1), yet spoke1 has no gateway and runs no BGP. How does that prefix reach on-prem, and why does it carry AS-PATH `65010`?**
Gateway transit. With `allow_gateway_transit = true` on the hub peering and `use_remote_gateways = true` on the spoke peering, the hub gateway advertises the peered spokes' prefixes into the BGP session on their behalf. The spokes never speak BGP themselves — the hub originates their prefixes — so the routes carry the *hub's* ASN (65010), not a spoke ASN. Flip either transit flag off and the spoke prefixes disappear from on-prem's table while the hub's own `172.22.0.0/20` remains.

**Q5 — ASN 65515 is off-limits. What is it reserved for, and what fails if you set a gateway to it?**
65515 is Azure's reserved default ASN for VPN gateways. Using it in a Local Network Gateway is rejected, and reusing the platform's reserved number invites ASN collisions with Azure's own control plane. Pick any other private ASN (64512–65534) that differs between the two ends.

**Q6 — This stack is destroyed at day-end but the base is untouched. How do you prove the base was not affected?**
Run `terraform plan` in the base folder after teardown and confirm `No changes`. The temporary `use_remote_gateways` flip was applied in the base folder and reverted there before destroy, so the base returns to its exact Day-5 state — a clean plan is the proof. The vpn stack only ever *read* the base via `terraform_remote_state`; it has no write path to it.

---

## Design challenge — the coupling that straddles the boundary

### The challenge

The hub gateway lives in `networking/vpn` but attaches to a GatewaySubnet owned by `networking/hub-spoke`. Reason through two questions:

1. When this stack drops a gateway into the base's subnet, does the base's next `plan` see drift?
2. For spokes to reach on-prem, the spoke peerings need `use_remote_gateways = true` — but those peerings live in the **base** state (Day 4). What is the cleanest way to flip that flag now that the gateway exists: edit the base from this stack, or handle it as a base-side change? And what does the answer reveal about where the state boundary was drawn?

### The resolution

**Question 1 — no drift.** Attaching a gateway does not modify the subnet resource, and the base does not manage the gateway; the base's plan stays clean. That cut is safe — the gateway and on-prem sim have an independent lifecycle and are disposable.

**Question 2 — you update the base from the base; there is no write path from here.** The only cross-stack tool this stack has is `terraform_remote_state`, which reads published outputs and nothing else. The two ways to force a write are both anti-patterns worth naming: re-declaring the spoke peering in this stack (now two state files own one resource, and every apply fights the other), or `import`-ing it here after `state rm` on the base (one logical resource smeared across two keys). Both "work" and both are landmines. The correct move is to make the flag flip in the base folder, its own plan/apply — which in this session was done as a deliberate, temporary base edit to demonstrate spoke advertisement, then reverted before teardown (verified by a clean base plan).

**What it reveals.** The split is cheap until a feature needs both halves at once. Peering is inherently two-sided — the hub side (`allow_gateway_transit`) and the spoke side (`use_remote_gateways`) are one logical feature, "spokes use the hub's gateway." Putting the gateway in `vpn` and the peerings in `hub-spoke` means enabling that feature straddles two states and cannot be done atomically in one apply. That is the real cost of splitting tightly-coupled resources across state keys.

## Corrections and gotchas

| # | Gotcha | Correction |
|---|---|---|
| 1 | LNG `address_space` /32 crossed to the wrong peer | Every field in one LNG (`gateway_address`, `asn`, `bgp_peering_address`, `address_space`) describes the *same* remote gateway. `address_space` is that gateway's own BGP peer IP as a `/32`. Crossing them keeps the tunnel up but BGP never establishes. |
| 2 | Public IP defaulted to `sku = "Basic"` | An AZ gateway attaches only a Standard, Static PIP. Set `sku = "Standard"` explicitly — the provider default is Basic and the gateway create rejects it ~40 min in. |
| 3 | Assuming `Static` allocation forces Standard SKU | It is the reverse: an AZ gateway needs a Standard PIP, and Standard is always Static. Basic PIPs can be Dynamic. |
| 4 | Hardcoding the BGP peer IP (`172.22.0.30`) | Azure auto-assigns it from the GatewaySubnet. Reference `bgp_settings[0].peering_addresses[0].default_addresses[0]`; a rebuild then survives a different assignment. |
| 5 | Pointing BGP at the public IP | `gateway_address` = remote **public** IP (IKE/IPsec setup). `bgp_peering_address` = remote **private** peer IP (BGP inside the tunnel). Swapping them exchanges no routes, silently. |
| 6 | Expecting `enable_bgp` on both gateway and connection to be redundant | Gateway `enable_bgp` = capability (BGP speaker + peer IP allocation). Connection `enable_bgp` = per-tunnel activation. Both required. |
| 7 | Lowercase `gatewaysubnet` | Must be the exact literal `GatewaySubnet`. A wrong-case name applies fine but fails the gateway create at submission. |
| 8 | Trying to flip `use_remote_gateways` from the vpn stack | It lives in the base state; there is no write path from here. Change it in the base folder; document it as a cross-stack dependency. |
| 9 | Destroying the gateway before reverting `use_remote_gateways` | Revert the spoke flag in the base and apply first, then destroy the vpn stack — otherwise the gateway can wedge in a Failed provisioning state. |
| 10 | Carried-but-unused base scaffolding in the vpn stack | `variable "hub"`, `subnets_spoke1/2`, `vnet_name`, `address_space`, and the `subnet_map_hub` local are inherited from the copy-forward and unused here. Harmless, but a truly slim ephemeral stack would drop them (and their tfvars entries). |
| 11 | `terraform output <expression>` returns "No outputs found" | `output` prints this stack's own root outputs by name; it cannot evaluate a cross-stack expression, and this stack publishes none. Use `terraform console` to inspect `data.terraform_remote_state…`. |
| 12 | `terraform console` shows base outputs as `(known after apply)` | On a never-applied new stack the remote-state read isn't persisted yet. Run a no-op `terraform apply` first to refresh and store the read, then the console prints concrete IDs. |
| 13 | Only base **outputs** are cross-stack readable | `terraform_remote_state` exposes root outputs only — not the base's locals or variables. Anything else you need (e.g. the RG) must be re-declared as a local `data` source. |
| 14 | `az network vpn-connection list` connection status is empty | The CLI does not reliably return `connectionStatus` (same as the CLI labs). Verify `Connected` in the portal: Virtual network gateway → gateway → Connections. |