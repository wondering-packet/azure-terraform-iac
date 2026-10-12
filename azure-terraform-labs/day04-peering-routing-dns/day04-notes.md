# Day 4 — Hub-Spoke: Peering, Routing & DNS

> **How to use this guide.** Each topic's theory gives you the building blocks — not the
> finished answer. Each exercise states a full problem: objective, inputs, constraints.
> Attempt it from the theory, predict the plan, then read the solution and apply. You are
> adopting a live 19-resource base and growing it — every mutation starts from a
> zero-change plan.

## File & marker conventions
- `dNNexNN-*.tf` files are day-scoped (this repo extends the base convention to carry the exercise number).
- Shared files (`locals.tf`, `variables.tf`, `outputs.tf`, `backend.tf`, `main.tf`) carry inline markers: `###---dNNexNN >>>` / `<<<`.

## Prerequisites & continuity
**Live now (from Day 3):** 19 resources under key `networking/hub-spoke`, `default` workspace, Azure AD backend auth. Hub VNet (`prevent_destroy = true`) with the full named subnet set including reserved `GatewaySubnet` (172.22.0.0/27) and `AzureFirewallSubnet` (172.22.1.0/26), and `dns-inbound`/`dns-outbound` delegated to `Microsoft.Network/dnsResolvers`; web/app NSGs; spoke1 + spoke2 VNets with workload subnets; base outputs published.

**What this day does:** wire the topology onto that base — VNet peering (hub↔spoke1, hub↔spoke2), route tables + UDRs steering traffic toward the future firewall at `172.22.1.4`, a private DNS zone `internal.lab.com` with links, and an *ephemeral* Private Resolver on the Day-3 delegated subnets. Extend base outputs with `route_table_ids`.

**What Day 5 builds on it:** Private Endpoints + the `privatelink.blob.core.windows.net` zone, layered on today's DNS foundation.

## Standard lab environment
| Setting | Value |
|---|---|
| Subscription | `<your-subscription-id>` |
| Region / RG | westus / rg-vg-lab-wus-01 |
| Backend | stvglabwustfstate / tfstate / key `networking/hub-spoke` — Azure AD auth — `default` workspace |
| Provider | azurerm v3.117.1 |
| Naming | `<resource-type>-vg-lab-wus-<purpose>` (global resources drop `-wus-`) |
| Firewall placeholder IP | 172.22.1.4 (VirtualAppliance next-hop; real firewall arrives Day 7) |
| OS / shell | Windows / PowerShell — backtick continuation, never `\` |

## Table of contents
1. [Topic 1 — VNet peering as paired resources](#topic-1--vnet-peering-as-paired-resources)
2. [Topic 2 — Route tables & UDRs](#topic-2--route-tables--udrs)
3. [Topic 3 — BGP route propagation](#topic-3--bgp-route-propagation)
4. [Topic 4 — Private DNS zones & links](#topic-4--private-dns-zones--links)
5. [Topic 5 — Extending base outputs](#topic-5--extending-base-outputs)
6. [Topic 6 — Private Resolver (ephemeral)](#topic-6--private-resolver-ephemeral)
7. [Design challenge — gateway transit & the firewall next-hop](#design-challenge--gateway-transit--the-firewall-next-hop)
8. [Corrections & gotchas](#corrections--gotchas)

Before Topic 1, prove the base is clean:

```powershell
Copy-Item -Recurse day03-extend-base day04-peering-routing-dns
cd day04-peering-routing-dns
terraform init
terraform workspace show   # must be: default
terraform plan             # must be: No changes
```

`No changes` and `default` are the gate. If the plan shows anything — especially a `-/+` on the hub VNet — stop and investigate (usual cause: wrong workspace or key). Do not fix forward.

> **Exercise numbering.** This attach-and-verify gate is **Exercise 1** in the repo's counting — it's not a build step, but it occupies the number, so the build exercises below start at **Exercise 2** and align with the `d04exNN-*.tf` file names and `# added in d04exNN` markers. Numbering then runs straight through: Ex 2 peering, Ex 3 routes, Ex 4 associations, Ex 5 DNS, Ex 6 outputs, Ex 7 resolver.

---

## Topic 1 — VNet peering as paired resources

### Theory

Peering is **two independent directional objects**, one anchored on each VNet — there is no single "link" resource. Create only one side and the peering sits `Initiated`, never `Connected`, and **no traffic flows in either direction**: the fabric only programs the data plane once both objects exist. So a hub↔spoke pair is two `azurerm_virtual_network_peering` resources; four total across two spokes.

```hcl
resource "azurerm_virtual_network_peering" "LABEL" {
  name                      = "peer-..."
  resource_group_name       = data.azurerm_resource_group.main.name
  virtual_network_name      = <the VNet THIS side lives on, by name>
  remote_virtual_network_id = <the OTHER VNet, by .id>   # gives the dependency edge

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = ...   # hub side only
  use_remote_gateways          = ...   # spoke side only
}
```

The four flags, and what each actually controls:

| Flag | Meaning | Setting here |
|---|---|---|
| `allow_virtual_network_access` | Grants VM-to-VM reachability across the peering | `true` — **required**; `false` leaves the peering `Connected` but drops every VM-to-VM packet |
| `allow_forwarded_traffic` | **Receive-side**: this VNet accepts traffic arriving over the peering whose source is not the directly-peered VNet (i.e. traffic forwarded by an NVA) | `true` all four; load-bearing on the **spoke** side (see note) |
| `allow_gateway_transit` | Hub offers its VPN/ExpressRoute gateway to the peer | `true` on the **hub** side only |
| `use_remote_gateways` | Spoke uses the peer's gateway instead of its own | `false` for now — `true` requires the remote gateway to already exist |

> **Which side does `allow_forwarded_traffic` actually do work on?** It's a receive-side control. On the path spoke1 → hub firewall → spoke2, the packet enters *spoke2* with a spoke1 source (not the hub's space = "forwarded"), so the peering object **on spoke2** must accept it. The hub-side objects never receive forwarded traffic in this topology (spokes have no NVA forwarding into the hub), so setting it there is belt-and-suspenders — harmless, symmetric, future-proof, but not load-bearing. Ignore the ARM property's backwards-sounding wording; the behavioral rule is "the local VNet accepts forwarded traffic inbound over this peering."

> **Why no spoke-to-spoke peering?** It's deliberately absent so all inter-spoke traffic transits the hub firewall for inspection. Peering is non-transitive — spoke1 never learns spoke2's prefix through the hub — so absence in config *is* the enforcement. (The CLI lab created and deleted a spoke1↔spoke2 peering to prove Azure allows it; in Terraform you prove it by reasoning about effective routes, not by building throwaway state.)

### Exercise 2 — Peering

**Objective:** declare the 4 directional peerings so hub↔spoke1 and hub↔spoke2 both reach `Connected`.

**Inputs:**

| Resource name | On VNet | Remote VNet | allow_gateway_transit | use_remote_gateways |
|---|---|---|---|---|
| peer-vg-lab-wus-hub-to-spoke1 | hub | spoke1 | true | false |
| peer-vg-lab-wus-hub-to-spoke2 | hub | spoke2 | true | false |
| peer-vg-lab-wus-spoke1-to-hub | spoke1 | hub | false | false |
| peer-vg-lab-wus-spoke2-to-hub | spoke2 | hub | false | false |

`allow_virtual_network_access = true` and `allow_forwarded_traffic = true` on all four.

**Constraints:**
- Reference the remote VNet by `.id` attribute, not a string — this also gives Terraform the ordering edge.
- `resource_group_name` from the RG data source (workspace-derived; never hardcode).
- New file `d04ex02-peering.tf`. Requires a `peering_name` local (add it to `locals.tf`).

**Predict:** exactly `4 to add, 0 to change, 0 to destroy`. Which resource type must **not** appear? The three `azurerm_virtual_network` resources — referencing an existing resource's `.id`/`.name` reads it, never mutates it; the hub especially must show no `-/+` (`prevent_destroy` would hard-fail the plan otherwise).

**Solution** — try the exercise above before reading on.

Local added to `locals.tf`:
```hcl
  peering_name = "peer-${local.prefix}"   # added in d04ex02 -> peer-vg-lab-wus-wus
```

`d04ex02-peering.tf`:
```hcl
resource "azurerm_virtual_network_peering" "hub_to_spoke1" {
  name                      = "${local.peering_name}-hub-to-spoke1"
  resource_group_name       = data.azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.spoke1.id

  allow_virtual_network_access = true   # required — grants VM-to-VM reachability
  allow_forwarded_traffic      = true   # belt-and-suspenders on the hub side
  allow_gateway_transit        = true   # standing offer; no gateway yet (Day 6)
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "hub_to_spoke2" {
  name                      = "${local.peering_name}-hub-to-spoke2"
  resource_group_name       = data.azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.spoke2.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "spoke1_to_hub" {
  name                      = "${local.peering_name}-spoke1-to-hub"
  resource_group_name       = data.azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.spoke1.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true   # load-bearing: spoke accepts firewall-forwarded traffic
  allow_gateway_transit        = false
  use_remote_gateways          = false  # no gateway to use yet
}

resource "azurerm_virtual_network_peering" "spoke2_to_hub" {
  name                      = "${local.peering_name}-spoke2-to-hub"
  resource_group_name       = data.azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.spoke2.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
```

Run — predict the plan, then apply:
```powershell
terraform plan    # expect: 4 to add, 0 to change, 0 to destroy; no VNet lines
terraform apply
```

### Q&A

**Q1 — You create only `hub_to_spoke1` and forget the reverse. Apply succeeds — then what?** The apply succeeds (a single directional peering is a valid object), but it lands `Initiated`, never `Connected`. The data-plane consequence is **zero traffic in either direction** — not "forward works, return drops." Peering connectivity is all-or-nothing per link; the forward/return-asymmetry intuition belongs to routing (an NVA path issue), not to a half-built peering. Declaring both resources with the `.id` dependency edge is what makes a half-peering impossible to ship.

---

## Topic 2 — Route tables & UDRs

### Theory

Three resource types, deliberately separate — the Terraform-idiomatic split of the CLI's `route-table create` → `route create` → `subnet update`:

```hcl
resource "azurerm_route_table" "LABEL" {
  name                          = "rt-..."
  location                      = ...
  resource_group_name           = ...
  bgp_route_propagation_enabled = ...   # Topic 3
}

resource "azurerm_route" "LABEL" {
  name                   = "route-..."
  route_table_name       = azurerm_route_table.LABEL.name
  resource_group_name    = ...
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "172.22.1.4"   # ONLY valid when type = VirtualAppliance
}

resource "azurerm_subnet_route_table_association" "LABEL" {
  subnet_id      = <existing subnet .id>
  route_table_id = azurerm_route_table.LABEL.id
}
```

Three things that matter:

- **`next_hop_type = "VirtualAppliance"` is the only type that takes an IP.** For `Internet`, `VnetLocal`, `VnetPeering`, `None`, you omit `next_hop_in_ip_address`. `None` is the blackhole (silent drop).
- **Routes point at `172.22.1.4` before the firewall exists.** A UDR is a forwarding instruction Azure never validates against a live next-hop, so apply succeeds; traffic hitting the route **blackholes** until Day 7's firewall answers at `.4` (the first usable IP of `AzureFirewallSubnet`, which Azure Firewall deterministically claims). The production consequence of a wrong next-hop is exactly this with no error — fat-finger `.5` and every matching packet silently disappears until an app times out.
- **The association is load-bearing and separate.** A route table with perfect routes does nothing until associated to a subnet. Keeping it a distinct resource means associating/disassociating never rewrites the table, and never shows as a change on the subnet object.

> **The spoke1 PE route is a Day-4 deviation from CLI lab 2.** The CLI spoke1 table had `0.0.0.0/0` plus a throwaway challenge blackhole (`192.168.100.0/24 -> None`). The persistent design drops the blackhole and adds `172.22.3.0/24 -> firewall` instead. Reason: spoke1 already has a `/20` VNetPeering route covering the whole hub, so a more-specific `/24` UDR overrides it *only* for the PE subnet — forcing spoke1→Private-Endpoint traffic through the firewall for inspection, pre-wiring Day 5.

### Exercise 3 — Route tables + routes

**Objective:** create the 3 route tables and their 5 routes. Associations are the next exercise — do not associate here.

**Inputs:**

| Route table | BGP propagation | Route name | Prefix | Next hop |
|---|---|---|---|---|
| rt-vg-lab-wus-spoke1 | OFF | route-vg-lab-default | 0.0.0.0/0 | VirtualAppliance -> 172.22.1.4 |
| rt-vg-lab-wus-spoke1 | OFF | route-vg-lab-pe | 172.22.3.0/24 | VirtualAppliance -> 172.22.1.4 |
| rt-vg-lab-wus-spoke2 | OFF | route-vg-lab-default | 0.0.0.0/0 | VirtualAppliance -> 172.22.1.4 |
| rt-vg-lab-wus-gw | ON | route-vg-lab-spoke1 | 172.22.16.0/20 | VirtualAppliance -> 172.22.1.4 |
| rt-vg-lab-wus-gw | ON | route-vg-lab-spoke2 | 172.22.32.0/20 | VirtualAppliance -> 172.22.1.4 |

**Constraints:**
- BGP polarity correct for the resolved provider (Topic 3).
- `next_hop_in_ip_address` only on `VirtualAppliance` routes.
- Route tables `location = westus`, RG from the data source.
- Routes as separate `azurerm_route` resources — do **not** also add inline `route {}` blocks on the same table (mixing conflicts).
- Terraform resource **labels** must be unique; the Azure route **names** may repeat across tables (`route-vg-lab-default` legitimately appears on both spoke tables — route names are scoped per table).

**Predict:** `8 to add` (3 tables + 5 routes). Nothing from prior state appears — this references only the RG data source, so it's purely additive.

**Solution** — try the exercise above before reading on.

Locals added to `locals.tf`:
```hcl
  rt_name    = "rt-${local.prefix}"                      # added in d04ex03 — route tables are regional, keep -wus-
  route_name = "route-${var.owner}-${local.environment}" # added in d04ex03 — a route has no location of its own, so the name carries no region code
```

`d04ex03-routing.tf`:
```hcl
##---route tables---##
resource "azurerm_route_table" "rt_gateway" {
  name                          = "${local.rt_name}-gw"
  resource_group_name           = data.azurerm_resource_group.main.name
  location                      = data.azurerm_resource_group.main.location
  bgp_route_propagation_enabled = true    # gateway subnet must keep propagation ON
}

resource "azurerm_route_table" "rt_spoke1" {
  name                          = "${local.rt_name}-spoke1"
  resource_group_name           = data.azurerm_resource_group.main.name
  location                      = data.azurerm_resource_group.main.location
  bgp_route_propagation_enabled = false   # explicit UDR control only
}

resource "azurerm_route_table" "rt_spoke2" {
  name                          = "${local.rt_name}-spoke2"
  resource_group_name           = data.azurerm_resource_group.main.name
  location                      = data.azurerm_resource_group.main.location
  bgp_route_propagation_enabled = false
}

##---routes---##
resource "azurerm_route" "gateway_to_spoke1" {
  name                   = "${local.route_name}-spoke1"
  route_table_name       = azurerm_route_table.rt_gateway.name
  resource_group_name    = data.azurerm_resource_group.main.name
  address_prefix         = "172.22.16.0/20"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "172.22.1.4"
}

resource "azurerm_route" "gateway_to_spoke2" {
  name                   = "${local.route_name}-spoke2"
  route_table_name       = azurerm_route_table.rt_gateway.name
  resource_group_name    = data.azurerm_resource_group.main.name
  address_prefix         = "172.22.32.0/20"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "172.22.1.4"
}

resource "azurerm_route" "spoke1_to_default" {
  name                   = "${local.route_name}-default"
  route_table_name       = azurerm_route_table.rt_spoke1.name
  resource_group_name    = data.azurerm_resource_group.main.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "172.22.1.4"
}

resource "azurerm_route" "spoke1_to_private_endpoint" {
  name                   = "${local.route_name}-pe"
  route_table_name       = azurerm_route_table.rt_spoke1.name
  resource_group_name    = data.azurerm_resource_group.main.name
  address_prefix         = "172.22.3.0/24"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "172.22.1.4"
}

resource "azurerm_route" "spoke2_to_default" {
  name                   = "${local.route_name}-default"
  route_table_name       = azurerm_route_table.rt_spoke2.name
  resource_group_name    = data.azurerm_resource_group.main.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "172.22.1.4"
}
```

```powershell
terraform plan    # expect: 8 to add, 0 to change, 0 to destroy
terraform apply
```

### Q&A

**Q2 — Routes point at `172.22.1.4`, but the firewall doesn't exist until Day 7. Why does apply succeed, and what happens to traffic today?** Apply succeeds because a UDR is a declarative forwarding instruction — Azure never checks whether anything answers at the next-hop. Traffic matching those routes reaches the next-hop and **blackholes** (silent drop, no ICMP) until Day 7's firewall claims `.4`. This is the intended pre-wire: the path is declared now, activated later.

---

## Topic 3 — BGP route propagation

### Theory

The setting controls whether **gateway-learned routes** (from a VPN/ExpressRoute gateway) are auto-injected into a subnet's effective route table.

- **OFF on spokes.** You want spoke forwarding decided only by your explicit UDRs. Once Day 6's gateway advertises on-prem prefixes over BGP, a learned route more *specific* than your `0.0.0.0/0 -> firewall` UDR would win longest-prefix-match and **silently bypass the firewall**. Off means only your UDRs decide.
- **ON for the GatewaySubnet.** Not optional — the gateway won't function with propagation disabled on its subnet, and it needs full route awareness to advertise spoke prefixes to on-prem in Day 6.

The argument is `bgp_route_propagation_enabled` (boolean): `false` = propagation OFF (spokes), `true` = propagation ON (gateway). Set the boolean to match the *intent*. It defaults to `true`, so **always state it explicitly** on the spokes — omitting it would silently leave propagation ON and reintroduce the exact firewall-bypass this topic prevents.

### Exercise 4 — Associate the route tables

**Objective:** one `azurerm_subnet_route_table_association` per table, so the inert tables take effect.

**Inputs:**

| Route table | Subnet |
|---|---|
| rt_spoke1 | spoke1 workload subnet |
| rt_spoke2 | spoke2 workload subnet |
| rt_gateway | GatewaySubnet (hub reserved) |

**Constraints:**
- Reference the subnet resource's `.id` and the route table resource's `.id` — GatewaySubnet via its `hub_reserved` for_each key.
- New file `d04ex04-associate_rt.tf`.

**Predict:** `3 to add`. The subnets must **not** show as `~ changed` — the association is its own resource, so wiring a table to a subnet never mutates the subnet object.

**Solution** — try the exercise above before reading on.

`d04ex04-associate_rt.tf`:
```hcl
resource "azurerm_subnet_route_table_association" "spoke1_workload_to_rt_spoke1" {
  route_table_id = azurerm_route_table.rt_spoke1.id
  subnet_id      = azurerm_subnet.spoke1.id
}

resource "azurerm_subnet_route_table_association" "spoke2_workload_to_rt_spoke2" {
  route_table_id = azurerm_route_table.rt_spoke2.id
  subnet_id      = azurerm_subnet.spoke2.id
}

resource "azurerm_subnet_route_table_association" "gateway_to_rt_gateway" {
  route_table_id = azurerm_route_table.rt_gateway.id
  subnet_id      = azurerm_subnet.hub_reserved["GatewaySubnet"].id
}
```

```powershell
terraform plan    # expect: 3 to add
terraform apply
terraform plan    # re-plan: must converge to No changes
```

The moment this applies, a spoke1 workload VM's **internet-bound** traffic diverts to `172.22.1.4` and blackholes (no firewall yet) — because `0.0.0.0/0` is the least-specific route and only wins where nothing else matches. Intra-spoke traffic keeps flowing (system `VnetLocal` route) and general spoke→hub keeps flowing (`VnetPeering` /20 route) — both more specific. The one extra slice that changes: spoke1→PE-subnet (`172.22.3.0/24`) now also diverts to the firewall, by design.

### Q&A

**Q3 — Propagation is OFF on spokes, ON for the GatewaySubnet. Give the specific failure mode of turning it ON for a spoke once Day 6's gateway advertises on-prem routes.** The spoke's route table would learn the on-prem prefixes (e.g. `10.0.0.0/16 -> VirtualNetworkGateway`). If any learned prefix is more specific than your `0.0.0.0/0 -> firewall` UDR — which it almost always is — LPM picks the gateway route and the spoke sends that traffic **straight to the gateway, bypassing the firewall entirely**. No error, no log: uninspected egress to on-prem. That is precisely why spokes stay OFF and steer purely on UDRs.

---

## Topic 4 — Private DNS zones & links

### Theory

Two resources: the zone, and one link per VNet that needs it.

```hcl
resource "azurerm_private_dns_zone" "LABEL" {
  name                = "internal.lab.com"
  resource_group_name = ...
}

resource "azurerm_private_dns_zone_virtual_network_link" "LABEL" {
  name                  = "..."
  resource_group_name   = ...
  private_dns_zone_name = azurerm_private_dns_zone.LABEL.name
  virtual_network_id    = <the VNet .id>
  registration_enabled  = ...
}
```

- `registration_enabled = true` → the VNet auto-registers an A record for every VM it holds (and removes it on delete). The **hub** gets this.
- `registration_enabled = false` → **resolution only**: VMs resolve records in the zone (including the registration VNet's auto-registered ones) but don't register their own. The **spokes** get this.

> **"Only the hub registers" is a design choice, not a zone limit.** The real Azure constraint is *per-VNet* — a given VNet can auto-register into only one zone — but a single zone can have multiple registration VNets. We centralize registration in the hub for one predictable registration domain; spokes are name consumers.

> **Peering does not carry DNS — this is why you create three links, not one.** A private DNS zone is resolvable only from VNets explicitly linked to it. A spoke being peered to the hub buys it zero resolution against `internal.lab.com`; it needs its own resolution link. Skip the spoke links and spoke VMs resolve nothing in the zone, peering notwithstanding.

### Exercise 5 — Private DNS zone + links

**Objective:** create `internal.lab.com` and link all three VNets with the correct registration/resolution split.

**Inputs:**

| Link | VNet | registration_enabled |
|---|---|---|
| pdnslink-vg-lab-hub | hub | true |
| pdnslink-vg-lab-spoke1 | spoke1 | false |
| pdnslink-vg-lab-spoke2 | spoke2 | false |

**Constraints:**
- `registration_enabled = true` on the hub link only.
- `private_dns_zone_name` / `virtual_network_id` reference the resource attributes.
- Links need `resource_group_name`.
- Link names **drop the region code** — private DNS zones are global resources, so links carry no `-wus-` (matches CLI lab 3: `pdnslink-vg-lab-<vnet>`).
- New file `d04ex05-dns.tf`.

**Predict:** `4 to add` (1 zone + 3 links). Creation order (zone before links) is not something you specify — the links reference the zone's `.name`, so Terraform derives the dependency and orders it.

**Solution** — try the exercise above before reading on.

Local added to `locals.tf`:
```hcl
  pdslink_name = "pdnslink-${var.owner}-${local.environment}" # added in d04ex05 -> pdnslink-vg-lab (no region: global resource)
```

`d04ex05-dns.tf`:
```hcl
resource "azurerm_private_dns_zone" "internal_lab" {
  resource_group_name = data.azurerm_resource_group.main.name
  name                = "internal.lab.com"
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  resource_group_name   = data.azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.internal_lab.name
  virtual_network_id    = azurerm_virtual_network.hub.id
  name                  = "${local.pdslink_name}-hub"
  registration_enabled  = true    # hub registers
}

resource "azurerm_private_dns_zone_virtual_network_link" "spoke1" {
  resource_group_name   = data.azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.internal_lab.name
  virtual_network_id    = azurerm_virtual_network.spoke1.id
  name                  = "${local.pdslink_name}-spoke1"
  registration_enabled  = false   # spoke resolves only
}

resource "azurerm_private_dns_zone_virtual_network_link" "spoke2" {
  resource_group_name   = data.azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.internal_lab.name
  virtual_network_id    = azurerm_virtual_network.spoke2.id
  name                  = "${local.pdslink_name}-spoke2"
  registration_enabled  = false
}
```

```powershell
terraform plan    # expect: 4 to add
terraform apply
```

### Q&A

**Q4 — Registration link vs resolution link: what does each do, and why only the hub gets registration?** A registration link makes its VNet auto-create/destroy A records for its VMs in the zone; a resolution link lets its VNet query the zone (including those auto-registered records) without registering its own. Only the hub registers by design — one centralized registration domain — not because the zone forbids more (it doesn't; the one-registration-zone limit is per-VNet).

---

## Topic 5 — Extending base outputs

### Theory

Outputs are the cross-stack contract, and they flow **forward in time**: a stack that applies earlier publishes; stacks that apply later consume via `terraform_remote_state`. Publish `route_table_ids` now so a future separate-state stack can reference these tables without hardcoding resource paths. You already have the pattern — `hub_subnet_ids` is a map for bulk reference, scalars like `gateway_subnet_id` for single identity-bound IDs.

Three route tables, each a distinct named resource with heterogeneous config, means there's no collection to iterate — a hand-built **map literal keyed by role** is the honest, clearest shape. (A list would force positional access and break on reordering. Don't retrofit the tables into a `for_each` just to iterate — they have genuinely different configs; this is not a candidate for the Day-8 collapse refactor, which targets *near-identical* blocks.)

### Exercise 6 — Add `route_table_ids`

**Objective:** publish a `route_table_ids` map output keyed by role.

**Inputs:**

| Key | Resource |
|---|---|
| gw | azurerm_route_table.rt_gateway |
| spoke1 | azurerm_route_table.rt_spoke1 |
| spoke2 | azurerm_route_table.rt_spoke2 |

**Constraints:**
- Reference each `.id`; mirror the `hub_subnet_ids` map style.
- Goes in the **shared** `outputs.tf` under `###---d04ex06 >>>` / `<<<` markers — not a new day file (outputs extend the base).

**Predict:** `0 to add, 0 to change, 0 to destroy`, plus a `Changes to Outputs:` block showing `+ route_table_ids = { ... }`. Outputs aren't state resources, so they never appear in the add/change/destroy counts; and since the tables already exist, the values are known (no `(known after apply)`).

**Solution** — try the exercise above before reading on.

In `outputs.tf`:
```hcl
###---d04ex06 >>>

output "route_table_ids" {
  value = {
    gw     = azurerm_route_table.rt_gateway.id,
    spoke1 = azurerm_route_table.rt_spoke1.id,
    spoke2 = azurerm_route_table.rt_spoke2.id
  }
}

###---d04ex06 <<<
```

```powershell
terraform plan    # expect: 0/0/0 + Changes to Outputs: + route_table_ids
terraform apply
```

### Q&A

**Q5 — Why can't Day 4's route table read the firewall's IP from Day 7's state via `terraform_remote_state`?** Because outputs only flow forward in time and `terraform_remote_state` requires the state it reads to already exist. Day 4 applies before `networking/firewall` state exists, so there's nothing to read. Worse, even on Day 7 it would be the wrong direction: the base stack must exist *before* the firewall stack, so the base depending on the firewall's output inverts the dependency — future references past, never the reverse. That's why `172.22.1.4` is a literal here.

---

## Topic 6 — Private Resolver (ephemeral)

### Theory

The managed replacement for a self-run DNS forwarder VM. Two endpoint types plus a ruleset, and direction is everything:

- **Inbound endpoint — ingress.** Gets a private IP in a dedicated delegated subnet. On-prem conditional forwarders point at this IP to resolve Azure private zones. The "on-prem → Azure" path.
- **Outbound endpoint — egress.** No IP. Own dedicated delegated subnet. Useless alone — only acts once attached to a forwarding ruleset. The "Azure → external" path.
- **Forwarding ruleset + rules.** Attaches to the outbound endpoint; holds `domain -> target DNS servers` rules. **The ruleset-to-VNet link is the actual forwarding trigger — not the inbound endpoint.** A VNet uses the ruleset only if linked to it, peered or not.

```hcl
resource "azurerm_private_dns_resolver" "LABEL" {
  virtual_network_id = <hub .id>   # one VNet, same region
}
resource "azurerm_private_dns_resolver_inbound_endpoint" "LABEL" {
  private_dns_resolver_id = ...
  ip_configurations {
    subnet_id                    = <dns-inbound .id>
    private_ip_allocation_method = "Static"
    private_ip_address           = "172.22.4.4"   # must be in the subnet range
  }
}
resource "azurerm_private_dns_resolver_outbound_endpoint" "LABEL" {
  private_dns_resolver_id = ...
  subnet_id               = <dns-outbound .id>     # no IP block
}
resource "azurerm_private_dns_resolver_dns_forwarding_ruleset" "LABEL" {
  private_dns_resolver_outbound_endpoint_ids = [<outbound .id>]
}
resource "azurerm_private_dns_resolver_forwarding_rule" "LABEL" {
  dns_forwarding_ruleset_id = ...
  domain_name               = "fakedomain.internal."   # trailing dot REQUIRED
  target_dns_servers { ip_address = "8.8.8.8"; port = 53 }
}
resource "azurerm_private_dns_resolver_virtual_network_link" "LABEL" {
  dns_forwarding_ruleset_id = ...
  virtual_network_id        = <hub .id>
}
```

Gotchas: `domain_name` must end with a trailing dot; each endpoint subnet must be dedicated and delegated to `Microsoft.Network/dnsResolvers` with nothing else in it (which is why Day 3 carved `dns-inbound`/`dns-outbound` out up front); the static inbound IP must sit inside the `dns-inbound` range.

> **Why ephemeral here.** The resolver bills continuously (~$0.50/hr) and the lab has no on-prem to forward from, so you build it, confirm it provisions, and tear it down. In production it's persistent because hybrid resolution depends on it 24/7.

### Exercise 7 — Private Resolver (build, then destroy)

**Objective:** stand up all six resources on the hub, verify the inbound endpoint claims `172.22.4.4`, then tear it down with `-target` so state returns to the persistent set.

**Inputs:**

| Resource | Key config |
|---|---|
| dnsresolver-vg-lab-wus | on hub VNet |
| inbound endpoint | dns-inbound subnet, Static 172.22.4.4 |
| outbound endpoint | dns-outbound subnet, no IP |
| fwruleset-vg-lab-wus | linked to the outbound endpoint |
| forwarding rule | fakedomain.internal. -> 8.8.8.8:53 |
| ruleset VNet link | ruleset -> hub VNet |

**Constraints:**
- Reference delegated subnets by their `azurerm_subnet.hub[...]` for_each keys.
- Trailing dot on `domain_name`; confirm `dns-inbound` is `172.22.4.0/24`.
- New file `d04ex07-resolver.tf`. This is **Exercise 7**, the last build step of the day — an ephemeral demo built and torn down after the permanent Exercise 6 outputs change.
- Resolver resources are regional, so their names **keep** the `-wus-` region code (unlike the global DNS zone).

**Predict:** `6 to add`. For teardown: the minimum `-target` set is **one** — the resolver — because every other resolver resource depends on it (inbound/outbound → resolver; ruleset → outbound; rule/link → ruleset), and nothing persistent depends on the resolver, so the cascade can't escape into permanent infra.

**Solution** — try the exercise above before reading on.

Locals added to `locals.tf`:
```hcl
  dnsresolver_name = "dnsresolver-${local.prefix}" # added in d04ex07 -> dnsresolver-vg-lab-wus (regional)
  fwrule_name      = "fwrule-${local.prefix}"      # added in d04ex07
  vnetlink_name    = "vnetlink-${local.prefix}"    # added in d04ex07
```

`d04ex07-resolver.tf` — shown active for the build step. **In the repo this whole block is left commented out at day-end** (its resources were destroyed), with a header line `## code now commented out cuz end of exercise task is destroy.` — uncomment to build, re-comment (or delete) after the teardown below.
```hcl
resource "azurerm_private_dns_resolver" "hub" {
  virtual_network_id  = azurerm_virtual_network.hub.id
  location            = azurerm_virtual_network.hub.location
  name                = local.dnsresolver_name
  resource_group_name = data.azurerm_resource_group.main.name
}

resource "azurerm_private_dns_resolver_inbound_endpoint" "hub_inbound" {
  name                    = "inbound-${local.prefix}"
  location                = azurerm_virtual_network.hub.location
  private_dns_resolver_id = azurerm_private_dns_resolver.hub.id

  ip_configurations {
    subnet_id                    = azurerm_subnet.hub["dns-inbound"].id
    private_ip_allocation_method = "Static"
    private_ip_address           = "172.22.4.4"
  }
}

resource "azurerm_private_dns_resolver_outbound_endpoint" "hub_outbound" {
  name                    = "outbound-${local.prefix}"
  location                = azurerm_virtual_network.hub.location
  private_dns_resolver_id = azurerm_private_dns_resolver.hub.id
  subnet_id               = azurerm_subnet.hub["dns-outbound"].id
}

resource "azurerm_private_dns_resolver_dns_forwarding_ruleset" "hub_ruleset" {
  name                = "fwruleset-${local.prefix}"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  private_dns_resolver_outbound_endpoint_ids = [
    azurerm_private_dns_resolver_outbound_endpoint.hub_outbound.id
  ]
}

resource "azurerm_private_dns_resolver_forwarding_rule" "test" {
  name                      = "${local.fwrule_name}-test"
  dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.hub_ruleset.id
  domain_name               = "fakedomain.internal."

  target_dns_servers {
    ip_address = "8.8.8.8"
    port       = 53
  }
}

resource "azurerm_private_dns_resolver_virtual_network_link" "hub_link" {
  name                      = "${local.vnetlink_name}-hub"
  virtual_network_id        = azurerm_virtual_network.hub.id
  dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.hub_ruleset.id
}
```

Build, verify, tear down:
```powershell
terraform plan    # expect: 6 to add
terraform apply
terraform state show azurerm_private_dns_resolver_inbound_endpoint.hub_inbound   # confirm 172.22.4.4

# Teardown — either path:
terraform destroy -target azurerm_private_dns_resolver.hub    # cascades to all 6
# ...or the cleaner pattern: remove d04ex07-resolver.tf from config, then:
terraform apply    # plan reads 6 to destroy

terraform plan    # must converge to No changes
```

> **`-target` vs removing the file.** `-target` is officially for exceptional/ephemeral surgery, not routine use (Terraform prints a warning to that effect). Removing the file and applying produces a clean `6 to destroy` plan with no targeting caveat — prefer it as the default habit on real stacks.

> **`terraform state show` reads the state file, not live Azure.** It reflects the last apply/refresh, not a fresh API call. It was accurate here only because the destroy-plan's refresh had just reconciled state. For a guaranteed-live read use `terraform plan`/`refresh` or `az network dns-resolver inbound-endpoint show`.

### Q&A

**Q6 — In production the resolver is persistent. If you tore down a real one that spokes depend on for on-prem resolution, what breaks — and why does it read as an application outage, not a DNS alert?** Both directions die: the outbound/ruleset path (Azure→on-prem conditional forwarding) and the inbound path (on-prem→Azure private-zone resolution via `172.22.4.4`). It presents as an app outage because cached lookups keep working until TTL expiry, so failures trickle in staggered across clients, and the symptom is connection timeouts to on-prem hosts long before anyone suspects DNS. The failure is **SERVFAIL/timeout**, not NXDOMAIN (a dead forwarder target returns no answer; NXDOMAIN only if queries fall through to a public resolver that authoritatively denies the internal name). And the on-prem conditional-forwarder config lives outside Terraform, so nothing in state flags the now-dangling pointer at a dead IP — which is the argument for `prevent_destroy` + separate state + change control on real resolvers.

---

## Design challenge — gateway transit & the firewall next-hop

**Part A — the gateway-transit flag lifecycle.** You set `allow_gateway_transit = true` (hub) and `use_remote_gateways = false` (spokes) with no gateway anywhere yet.

- **When Day 6's VPN gateway comes online, flip only the spoke peerings' `use_remote_gateways` to `true`; the hub peerings don't change** — they already offer transit. Pre-setting the offer means Day 6 is a low-blast-radius, spoke-side-only edit; you never reopen the `prevent_destroy`-anchored hub peerings. Editing the highest-stakes shared object less often is the real win.
- The two flags live on the **control plane** (peering), not the data plane (route tables), and they do different jobs from BGP propagation:
  - `use_remote_gateways` (spoke peering) makes the gateway **advertise the spoke's address space to on-prem** — i.e. return reachability. Without it, on-prem never learns the spoke exists and return traffic blackholes.
  - BGP route propagation (subnet route table) controls whether a subnet **installs** gateway-learned routes.
  - We deliberately set them opposite on spokes: `use_remote_gateways = true` (gateway advertises the spoke outward) + propagation `false` (spoke doesn't install gateway routes, so its outbound still tunnels through the firewall via the `/0` UDR). Peering flags = who's *allowed* to use/advertise; route tables = where packets *actually go*. They never overlap, which is why you need both.
- `use_remote_gateways` is a **peering** property — it never lives on a subnet, and never near the firewall subnet (which is inside the hub, so the gateway is a VNet-local hop). The firewall subnet has no custom route table in this build, so it learns `on-prem -> gateway` by default propagation once the gateway exists.

**Part B — the `172.22.1.4` next-hop.** Three candidate designs: (a) hardcoded string, (b) variable with default, (c) `terraform_remote_state` from the firewall stack.

- **(c) is impossible on Day 4** — the firewall's `networking/firewall` state doesn't exist yet, and `terraform_remote_state` requires an existing state to read. It's also the wrong dependency direction even on Day 7 (Q5).
- Between **(a)** and **(b)**: the IP is deterministic (Azure Firewall always claims `.4` in `AzureFirewallSubnet`), so by "don't hardcode volatile values" it's actually a valid constant. But it's repeated five times across three tables — so the real argument is **single source of truth + naming**, not mutability. Promote it to a **`local`** (e.g. `firewall_private_ip`), not a variable: it's derived from your own subnet schema, not something a caller should override. One definition, a self-documenting name instead of a magic number. That's the refactor to make (deferred; not required for Day 4 correctness).

---

## Corrections & gotchas

| # | Gotcha | Correction |
|---|---|---|
| 1 | Referenced `local.peering_name` before defining it | Add `peering_name = "peer-${local.prefix}"` to `locals.tf`; an undefined local fails `terraform validate`. |
| 2 | Assumed the hub needs `allow_forwarded_traffic` to receive packets | It's a receive-side flag; the hub never receives forwarded traffic in this topology. The load-bearing copies are on the **spoke** peerings (so a spoke accepts firewall-forwarded traffic sourced from another spoke). Hub-side is belt-and-suspenders. |
| 3 | Comment claimed `allow_virtual_network_access` "most likely not needed" | It's **required** — it's the flag that grants VM-to-VM reachability; `false` leaves the peering `Connected` but drops every packet. The "no forwarded packets needed" reasoning belongs to `allow_forwarded_traffic`. |
| 4 | Gateway routes written as `172.16.0.0/20` / `172.32.0.0/20` | Correct spokes are `172.22.16.0/20` / `172.22.32.0/20`. The wrong prefixes apply cleanly with no error and silently blackhole — the exact "wrong next-hop/prefix, apply succeeds, times out later" trap. |
| 5 | Two `azurerm_route` blocks shared the TF label `route-to-nva_default` | TF resource labels must be unique in the module (duplicate = `validate` error). Azure route *names* may repeat across tables (`route-vg-lab-default` on both spoke tables is fine — names are per-table-scoped). |
| 6 | DNS link names came out as `pdslink-*` (missing the `n`) | Required CLI-matching names are `pdnslink-*`. The fix is in the *value*: `pdslink_name = "pdnslink-${var.owner}-${local.environment}"` -> `pdnslink-vg-lab-<vnet>`. (The local's identifier stays `pdslink_name`; a local's name doesn't affect the resource name.) Dropping the region code is correct — the zone/links have no location. |
| 7 | After destroying the resolver, plan showed the two DNS subnets re-adding their delegation | Deleting a resolver endpoint strips the `Microsoft.Network/dnsResolvers` delegation from its subnet. Terraform self-heals because the delegation is declared in the **persistent Day-3 base** — an argument for keeping shared plumbing out of ephemeral files. Apply it (in-place, subnets empty, safe). |
| 8 | Assumed `terraform state show` reads live Azure | It reads the **state file** — only as fresh as the last apply/refresh. Use `plan`/`refresh` or `az ... show` for a live read. |
| 9 | Unsure of the minimum `-target` set to tear the resolver down | One target — the resolver — cascades to all six (everything depends on it transitively; nothing persistent depends on it). Cleaner still: remove the file and `apply`. |