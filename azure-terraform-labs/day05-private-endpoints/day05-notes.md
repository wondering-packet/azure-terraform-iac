# Day 5 — Private Endpoints & Private Link

> **How to use this guide.** Each topic's theory gives you the building blocks — not the
> finished answer. Each exercise states a full problem: objective, inputs, constraints, and a
> prediction to make *before* you apply. Attempt it from the theory, predict the plan, then read
> the solution (your own repo code, annotated) and apply. The payoff of this day is empirical:
> you build a Service Endpoint and a Private Endpoint, then prove — from real VMs — exactly what
> each one blocks and why.

## File & marker conventions

- `dNN…` files are day-scoped (e.g. `d05ex03ex04ex05-private_endpoint.tf`).
- Shared files (`locals.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars`) carry inline
  `###---dNNexNN >>>` / `<<<` markers around the lines a given exercise added or changed.
- Files that span multiple exercises are named for every exercise they own
  (`d05ex01ex02-service_endpoint.tf`, `d05ex03ex04ex05-private_endpoint.tf`).

## Prerequisites & continuity

**Prereq:** Days 0–4.

**Live now (inherited from Day 4), state key `networking/hub-spoke`, `default` workspace, Azure AD backend auth, azurerm v3.117.1:**
- Peered hub + spoke1 + spoke2 topology; hub carries the full subnet set including the empty
  PE subnet `snet-vg-lab-wus-pe` (`172.22.3.0/24`).
- Route tables on both spokes with `0.0.0.0/0 → 172.22.1.4` (the Day-7 firewall placeholder —
  a dead next hop until Day 7 builds the real appliance).
- Private DNS zone `internal.lab.com` + its three links (Day 4). **Untouched this day.**

**What this day does:** add the PaaS-isolation layer — a storage account, a **Service Endpoint**
demonstration (Lab 4a), then a **Private Endpoint** (Lab 4b) with its
`privatelink.blob.core.windows.net` zone + links + A record, and a PE-subnet NSG with
`private_endpoint_network_policies` enabled. It also restructures the hub subnet variable
(`subnets` + `subnets_special`) and stands up a throwaway VM/Bastion test rig to prove the
controls end-to-end.

**What Day 6 inherits:** the storage PE identity/IP and storage account ID via new outputs, read
through `terraform_remote_state` from a separate `networking/vpn` key.

## Standard lab environment

| Setting | Value |
|---|---|
| Subscription | `<your-subscription-id>` |
| Region / RG | westus / rg-vg-lab-wus-01 |
| Backend | stvglabwustfstate / container `tfstate` / key `networking/hub-spoke` — Azure AD auth — `default` workspace |
| Provider | azurerm v3.117.1 |
| Naming | `<resource-type>-vg-lab-wus-<purpose>`; global/no-location resources drop `-wus-`; storage accounts drop hyphens entirely |
| PE subnet | `snet-vg-lab-wus-pe` `172.22.3.0/24` (PE lands at `172.22.3.4`) |
| Lab storage | `stvglabwus01` (distinct from the backend account `stvglabwustfstate`) |
| OS / shell | Windows / PowerShell — backtick continuation, never `\` |

## Table of contents

1. [Exercise 0 — attach & verify](#exercise-0--attach--verify)
2. [Topic 1 — Service Endpoint vs Private Endpoint (framing)](#topic-1--service-endpoint-vs-private-endpoint-framing)
3. [Topic 2 — Service Endpoint + storage firewall (Lab 4a)](#topic-2--service-endpoint--storage-firewall-lab-4a)
4. [Topic 3 — Private Endpoint + DNS (Lab 4b)](#topic-3--private-endpoint--dns-lab-4b)
5. [Topic 4 — NSG enforcement on the PE subnet](#topic-4--nsg-enforcement-on-the-pe-subnet)
6. [Topic 5 — SE vs PE comparison + outputs](#topic-5--se-vs-pe-comparison--outputs)
7. [Test rig (scope addition) — VMs, Bastion, power script](#test-rig-scope-addition--vms-bastion-power-script)
8. [The subnet refactor and the `moved` blocks](#the-subnet-refactor-and-the-moved-blocks)
9. [Design challenge](#design-challenge)
10. [Corrections & gotchas](#corrections--gotchas)

---

### Exercise 0 — attach & verify

**Objective:** copy the Day 4 folder forward and prove a zero-change attach to live state before mutating anything.

```powershell
Copy-Item -Recurse day04-peering-routing-dns day05-private-endpoints
cd day05-private-endpoints
terraform init
terraform workspace show   # must be: default
terraform plan             # must be: No changes
```

**Predict:** `terraform workspace show` → `default`; `terraform plan` → `No changes`. A `-/+` on
the hub VNet or any subnet means you're on the wrong workspace or key — stop and investigate, do
not fix forward. Ex 0 produces no `.tf`; build exercises begin at Ex 1.

> **Prerequisite for the verification steps: the test rig.** Labs 4a and 4b are only falsifiable
> from real VMs — you prove what each control allows/blocks by running `curl`/`nslookup` from
> spoke1, spoke2, and hub over Bastion. Before you reach the SE/PE tests, stand up the VMs, the
> three Developer-SKU Bastions, and the power script — see
> [Test rig](#test-rig-scope-addition--vms-bastion-power-script). Bring them up with
> `enable_test_vms = true` and `TF_VAR_vm_admin_password` set; deallocate them between sessions with
> `lab-power.ps1 -Action Stop`. The builds themselves don't need the rig — only the tests do.

---

## Topic 1 — Service Endpoint vs Private Endpoint (framing)

### Theory

Both features answer the same question — "how do I reach a PaaS service like Storage without the
traffic riding the public internet?" — but they enforce in completely different places, and
*where* they enforce is the whole day.

**Service Endpoint (SE)** is an attribute on a *subnet*. Enabling it does two things: it injects
routes for the target service's public prefixes into the subnet (next hop
`VirtualNetworkServiceEndpoint`, so traffic takes the Azure backbone instead of the internet), and
it stamps the subnet's identity onto the traffic so the *service's own firewall* can recognize it.
What it does **not** do: change the destination (still the service's **public** IP) or touch DNS.
Enforcement lives on the PaaS resource's firewall (`default_action = Deny` + a subnet allow-list).

**Private Endpoint (PE)** is a real resource — a NIC with a **private IP inside your subnet**
(`172.22.3.4` here), mapped by Private Link to one specific instance of a service. Because the
resource now answers on a private IP, **DNS must be overridden** or clients keep resolving the
public IP and never use the endpoint. Enforcement here is **not** the storage firewall at all — it
is an **NSG on the PE subnet**.

> **Private Link is not storage-only.** A PE binds to a specific *instance* of a supported service
> — Azure SQL, Key Vault, Cosmos, App Service, AKS API server, and many more, each with its own
> `privatelink.*` zone and its own subresource/group-id — and even to your own services via
> Private Link Service. In this lab the instance happens to be a storage account and the
> subresource is `blob`.

The one-line contrast to carry through the day: **SE keeps a public destination and enforces at
the service; PE creates a private destination and enforces at the network.** That split cascades
into DNS behavior, what blocks a peered spoke, whether on-prem can reach it natively, and cost.

### Q&A

**Q1 — With SE enabled, traffic rides the Azure backbone, yet `nslookup` still returns a public
IP. Why — and what does that mean for on-prem reaching the resource privately?**
Because SE does not touch DNS. It is a routing + identity mechanism; the storage account's only
address is its public IP, so there is no private alternative for DNS to return. SE changes the
*path* and the *source identity*, not the name resolution. SE itself gives on-prem nothing — the
subnet identity does not extend past the VNet. But the storage firewall's **IP network rules** do
handle on-prem: you can whitelist your corporate NAT/public egress IP, and traffic then rides the
public internet to the storage public endpoint and is allowed. (Over ExpressRoute Microsoft peering
it is the same idea — you whitelist the NAT IP used for Microsoft peering.) What SE and IP rules
cannot give on-prem is a *private* path with no public IP in it — that is a Private Endpoint job.

---

## Topic 2 — Service Endpoint + storage firewall (Lab 4a)

### Theory

Lab 4a proves the SE gate. Three moving parts:

1. **The Service Endpoint on the subnet** — a subnet attribute. On its own it restricts nothing;
   it only arms routing + identity.
   ```hcl
   service_endpoints = ["Microsoft.Storage"]
   ```
2. **The storage account** (`azurerm_storage_account`) — the target. Two CLI→Terraform attribute
   mappings: `Standard_LRS` → `account_tier = "Standard"` + `account_replication_type = "LRS"`; and
   `--allow-blob-public-access false` → `allow_nested_items_to_be_public = false` (not
   `public_network_access_enabled`, which disables the public endpoint entirely — Lab 4a needs it).
3. **The storage firewall** (`azurerm_storage_account_network_rules`) — `default_action` + a subnet
   allow-list + `bypass`. In azurerm this is expressible **two mutually exclusive ways**: the inline
   `network_rules {}` block on the account, *or* the standalone
   `azurerm_storage_account_network_rules` resource. Mixing both causes perpetual diffs. The
   standalone resource keeps the rule's lifecycle off the account and dodges a known state
   round-trip bug (>3.112.0) in the inline block.

> **Nothing is restricted until you flip `default_action` to `Deny`.** A storage account defaults
> to `default_action = "Allow"` (all networks permitted), and **network rules have no effect while
> the default action is `Allow`**. So enabling the SE on the subnet *and even adding the subnet to
> the allow-list* changes nothing observable — the account still accepts everyone — until you set
> `default_action = "Deny"`, which flips the baseline to "deny unless explicitly allowed."

The core lesson: enabling the endpoint does nothing until `default_action = "Deny"` + the subnet is
allow-listed — and even then, the firewall only governs traffic arriving at the **public** endpoint.

### Exercise 1 — Storage account (`d05ex01-*` in `d05ex01ex02-service_endpoint.tf`)

**Objective:** create the lab target storage account (`azurerm_storage_account`) with public blob
access off and the `mg-wondering-packet-all` policy satisfied. No SE, no firewall lockdown yet.

**Inputs:**

| Field | Value |
|---|---|
| Name | `stvglabwus01` (`local.st_lab_name`) |
| RG / location | via `data.azurerm_resource_group.main` |
| Tier / replication / kind | `Standard` / `LRS` / `StorageV2` |
| Public blob access | off |
| Tags | `local.lab_tags` |

**Constraints:** reuse the workspace-derived RG data source; public blob access off via the
*renamed* attribute; do **not** set `default_action = "Deny"` yet (that locks the firewall before
the allow-list exists).

**Predict:** `1 to add`. Any `RequestDisallowedByPolicy`? Reason about azurerm's default `bypass`
before deciding.

**Solution** — try the exercise above before reading on.

```hcl
resource "azurerm_storage_account" "lab" {
  name                            = local.st_lab_name
  resource_group_name             = data.azurerm_resource_group.main.name
  location                        = data.azurerm_resource_group.main.location
  account_tier                    = "Standard"       # Standard_LRS splits into tier + replication
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  allow_nested_items_to_be_public = false            # maps --allow-blob-public-access false (not public_network_access_enabled)
  tags                            = local.lab_tags
}
```

Run: `terraform plan` → predict `1 to add` → `terraform apply`. The bare account created cleanly
with no policy rejection — because with no `network_rules` block, `default_action` defaults to
`Allow` and the API default `bypass` is already `AzureServices`, which satisfied `mg-wondering-packet-all`
without any explicit flag.

Added to `locals.tf` for this exercise — the storage name (hyphens aren't allowed in storage
account names, so it breaks the `-vg-lab-wus-` convention) and the standard tag block that all
Day 5+ resources reuse:

```hcl
# locals.tf
st_lab_name = "stvglabwus01"        # storage account name — no hyphens, globally unique

###---d05ex01 >>>
lab_tags = {
  env        = local.environment   # workspace-aware ("lab" in default)
  managed_by = "terraform"         # deliberate divergence from the CLI lab's owner/env/purpose set
  owner      = var.owner
  purpose    = "networking"
}
###---d05ex01 <<<
```

### Exercise 2 — Service Endpoint + storage firewall (Lab 4a) (`d05ex02`)

**Objective:** enable the `Microsoft.Storage` SE on the spoke1 workload subnet (`azurerm_subnet`,
in-place edit), then lock the storage firewall (`azurerm_storage_account_network_rules`) so only
that subnet is allowed and everything else is denied.

**Inputs:**

| Field | Value |
|---|---|
| SE target subnet | `snet-vg-lab-wus-spoke1-workload` (`172.22.16.0/24`) |
| Service endpoint | `Microsoft.Storage` |
| Storage allow-list | the spoke1 workload subnet only |
| Default action | `Deny` |
| Leave alone | the `db` hub subnet (already carries `Microsoft.Storage` from Day 3) |

**Constraints:** standalone `azurerm_storage_account_network_rules` (not the inline block);
reference the spoke1 subnet by resource address; `default_action = "Deny"`; decide `bypass`
explicitly.

**Predict:** enabling `service_endpoints` on a *live* subnet — `~` in-place or `-/+` replace?
And the total change count.

**Solution** — try the exercise above before reading on.

The SE is one added attribute on the existing spoke1 subnet resource (an in-place `~`, because
`service_endpoints` is not ForceNew):

```hcl
resource "azurerm_subnet" "spoke1" {
  virtual_network_name = azurerm_virtual_network.spoke1.name
  resource_group_name  = data.azurerm_resource_group.main.name
  name                 = "${local.snet_name}-spoke1-workload"
  address_prefixes     = [var.subnets_spoke1["workload"].cidr]
  ###---d05ex02 >>>
  service_endpoints = var.subnets_spoke1["workload"].service_endpoints  # ["Microsoft.Storage"]
  ###---d05ex02 <<<
}
```

The firewall, as a standalone resource:

```hcl
resource "azurerm_storage_account_network_rules" "lab_st_rules" {
  storage_account_id = azurerm_storage_account.lab.id
  default_action     = "Deny"
  ## i realized even if i comment out the bypass line.
  ## azure by default bypasses azureservices.
  ## you can confirm this with "terraform state show azurerm_storage_account_network_rules.lab_st_rules"
  bypass                     = ["AzureServices"]   # set explicitly: intent-in-code + matches the CLI lab
  virtual_network_subnet_ids = [azurerm_subnet.spoke1.id]
}
```

Run: `terraform plan` → predict `1 to add` (rules) `+ 1 to change` (subnet `~`) → apply. The
subnet modified in place (~14s); the rules resource created.

> **`bypass` is Computed, not defaulted-in-schema.** Omitting `bypass` does **not** mean "no
> bypass" — the provider leaves it computed and the Azure API fills in `AzureServices`. That is why
> a bare plan shows `bypass = (known after apply)`. Setting it explicitly is a security control
> made visible; without it, an out-of-band change to `bypass` would not even show as drift.

**Test Lab 4a from the VMs, and record your results.** This verification needs the test rig up
(VMs + Bastion — see [Test rig](#test-rig-scope-addition--vms-bastion-power-script); stand it up
first). Bastion into each VM and run the well-formed probe:

```bash
curl -s "https://stvglabwus01.blob.core.windows.net/?comp=list"   # read the <Code> in the XML body
nslookup stvglabwus01.blob.core.windows.net                        # note the resolved IP
```

Record the `<Code>` (and resolved IP) from **spoke1**, **spoke2**, and **hub** — plus your own
**laptop** if handy. Keep these; you'll line them up against the SE-era column of the
[Topic 5 matrix](#the-se-vs-pe-behavior-matrix-measured-live). Interpreting the code:
`AuthorizationFailure` = blocked at the network; `PublicAccessNotPermitted` = passed the network,
refused only on anonymous auth (the *success* signal for a network test); empty/hang = never
reached storage (routing).

### Q&A

**Q2 — You set the storage firewall `default_action = Deny`, then later access storage through the
PE from spoke1. Does the Deny apply?**
No. PE traffic enters through the private NIC over the VNet/backbone and never touches storage's
**public** endpoint, so the PaaS firewall never sees it. `default_action = Deny` governs the public
door only; the PE is a private door in a different wall. (Proven directly in Topic 3's tests: hub —
firewall-*denied* over the public endpoint — reached storage fine once it used the PE path.)

---

## Topic 3 — Private Endpoint + DNS (Lab 4b)

### Theory

Lab 4b flips the model: instead of gating the public endpoint, you project storage into your
network as a private NIC, then solve DNS.

**The PE resource is the easy part** — `azurerm_private_endpoint` with one
`private_service_connection` pointing at the storage account ID, naming the **subresource**
(`blob` — the group-id, a short token, not the FQDN) and `is_manual_connection = false`
(same-tenant auto-approval). Azure drops a NIC into the PE subnet and assigns `172.22.3.4`
(`.0–.3` are reserved in every subnet). The NIC is **absorbed into the PE** — it is not a separate
`azurerm_network_interface` resource; it surfaces as the PE's computed `network_interface`
attribute.

**DNS is the hard part.** The moment a PE exists, Azure rewrites the public FQDN into a CNAME chain:

```
stvglabwus01.blob.core.windows.net
   └── CNAME → stvglabwus01.privatelink.blob.core.windows.net
                    └── A → ???
```

Publicly, that `privatelink.blob.core.windows.net` name resolves onward — another CNAME to the
storage **public** endpoint's IP. So a client without the private override still resolves an
address and still reaches storage, just over the **public** path — the PE is simply never used.
That is the #1 silent PE failure: nothing errors, the client quietly takes the public endpoint, and
your PE-subnet NSG (which only governs the private path) is bypassed entirely. You fix it by hosting
the **private zone** `privatelink.blob.core.windows.net`, **linking** it to the VNets that must
resolve it, and adding an **A record** `stvglabwus01 → 172.22.3.4`. Now, for clients whose VNet is
linked to the zone, the chain terminates at your private IP instead of falling through to public.

> **The link is what makes it private — proven both ways.** With the VNet linked, the resolver
> answers `privatelink.blob.core.windows.net` from your zone and stops at `172.22.3.4`. Remove the
> link and the resolver falls through to **public** DNS, where Microsoft has published the same
> `privatelink` name as a further CNAME onward to the public endpoint — so every client silently
> reverts to the public IP with no error. (This is exactly what the "links removed" column in the
> Topic 5 matrix shows.)

### Exercise 3 — Private Endpoint (`d05ex03` in `d05ex03ex04ex05-private_endpoint.tf`)

**Objective:** create the Private Endpoint (`azurerm_private_endpoint`) `pe-vg-lab-wus-storage` in
the PE subnet, wired to the storage account's `blob` subresource. DNS is Ex 4.

**Inputs:** name `pe-vg-lab-wus-storage`; subnet the PE subnet; target `azurerm_storage_account.lab`;
subresource `blob`; auto approval.

**Constraints:** reference the PE subnet resource directly (same state); `subresource_names` takes
the group-id (`blob`), not the FQDN; no DNS and no `private_endpoint_network_policies` handling here.

**Predict:** how many resources does `plan` add; is the NIC its own resource or absorbed; what
private IP?

**Solution** — try the exercise above before reading on.

```hcl
resource "azurerm_private_endpoint" "lab_storage" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.hub_pe.id            # PE subnet (post-refactor resource; see the refactor section)
  name                = "${local.pe_name}-storage"
  private_service_connection {
    name                           = "psc-${local.prefix}-storage"
    private_connection_resource_id = azurerm_storage_account.lab.id
    subresource_names              = ["blob"]               # group-id, not the FQDN
    is_manual_connection           = false                  # same tenant → auto-approved
  }
}
```

Run: `plan` → `1 to add` (the NIC is absorbed, not separate) → apply (~49s). Pull the assigned IP —
Ex 4 needs it:

```powershell
terraform state show azurerm_private_endpoint.lab_storage | Select-String "private_ip_address"   # 172.22.3.4
```

Added to `locals.tf` for this exercise:

```hcl
# locals.tf
pe_name = "pe-${local.prefix}"      # → pe-vg-lab-wus
```

At this point `nslookup` from any VM still returns the **public** IP — the PE exists but DNS is
untouched. That gap is Ex 4.

### Exercise 4 — Private DNS zone + links + A record (`d05ex04`)

**Objective:** host the private zone `privatelink.blob.core.windows.net`
(`azurerm_private_dns_zone`), link it to the three VNets
(`azurerm_private_dns_zone_virtual_network_link`), and add the A record
(`azurerm_private_dns_a_record`) → the PE's private IP.

**Inputs:** zone `privatelink.blob.core.windows.net`; 3 links (hub, spoke1, spoke2),
`registration_enabled = false`; A record name `stvglabwus01` → `172.22.3.4`.

**Constraints:** exact zone name (not the storage FQDN, not `internal.lab.com`); global resource
(no location, no `-wus-`); A record `name` is the storage label only (the zone supplies the suffix);
wire the IP from the **PE's computed attribute**, not a literal.

**Predict:** count (zone + 3 links + record); and what `nslookup` returns from a **linked** vs an
**unlinked** network.

**Solution** — try the exercise above before reading on.

```hcl
resource "azurerm_private_dns_zone" "lab_storage_pe" {
  name                = "privatelink.blob.core.windows.net"   # exact zone name — the CNAME target
  resource_group_name = data.azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "lab_vnets" {
  resource_group_name   = data.azurerm_resource_group.main.name
  for_each              = local.vnet_ids                       # {hub, spoke1, spoke2} — data-driven, 3 links
  name                  = "${local.vnetlink_name}-${each.key}"
  virtual_network_id    = each.value
  private_dns_zone_name = azurerm_private_dns_zone.lab_storage_pe.name
  registration_enabled  = false                                # resolution only; VMs don't auto-register
}

resource "azurerm_private_dns_a_record" "lab_storage_pe" {
  name                = local.st_lab_name                      # "stvglabwus01" — label only, zone adds the suffix
  resource_group_name = data.azurerm_resource_group.main.name
  zone_name           = azurerm_private_dns_zone.lab_storage_pe.name
  # IP read from the PE's computed attribute, so the record follows the endpoint (no magic 172.22.3.4 literal):
  records = [azurerm_private_endpoint.lab_storage.private_service_connection[0].private_ip_address]
  ttl     = 300
}
```

`local.vnet_ids` (shared with the Bastion rig; lives under the PE marker in `locals.tf`, not the
test-rig marker — a durable value kept out of a disposable block):

```hcl
###---d05ex03ex04-private_endpoint >>>
# note that this block is used by bastion resources as well in d05-test_bastion
vnet_ids = {
  hub    = azurerm_virtual_network.hub.id
  spoke1 = azurerm_virtual_network.spoke1.id
  spoke2 = azurerm_virtual_network.spoke2.id
}
###---d05ex03ex04-private_endpoint <<<
```

(`local.vnetlink_name` is carried from Day 4 — no new local needed for the link name.)

Run: `plan` → `5 to add` → apply. From a **linked** VNet, `nslookup` now terminates at
`172.22.3.4`; from an unlinked network it would still fall through to the public IP.

**Test Lab 4b from the VMs, and record your results** (test rig required — see
[Test rig](#test-rig-scope-addition--vms-bastion-power-script)). From each VM:

```bash
nslookup stvglabwus01.blob.core.windows.net                        # expect the CNAME chain to end at 172.22.3.4 from a linked VNet
curl -s "https://stvglabwus01.blob.core.windows.net/?comp=list"    # record the <Code>
```

Record the resolved IP and `<Code>` from **spoke1**, **spoke2**, and **hub**. Line them up against
the **PE + links** column of the [Topic 5 matrix](#the-se-vs-pe-behavior-matrix-measured-live) —
and note the twist: with the private path live, hub and spoke2 (which the SE model denied or
blackholed) now reach storage, while spoke1 may *hang* (its Day-4 UDR — see Q3 below). Optionally
remove a VNet link and re-`nslookup` to watch that VNet silently revert to the public IP.

### Q&A

**Q3 — DNS resolves `172.22.3.4` from all three VNets, but a `curl` from spoke1 hangs while hub and
spoke2 succeed. Why does the private path *break* spoke1 specifically?**
spoke1 is the one VNet carrying the Day-4 UDR `172.22.3.0/24 → 172.22.1.4` (the dead firewall
placeholder). Once DNS hands spoke1 the PE's private IP, spoke1 tries to reach `172.22.3.4`, that
destination matches the UDR, and the packet is sent to a firewall that does not exist yet →
blackhole. hub and spoke2 have no such UDR for that prefix, so they reach the PE directly. The fix
is not DNS or the PE — it is that the Day-4 route pre-wires PE inspection through a firewall that
Day 7 has not built. For this lab you can comment out the `spoke1_to_private_endpoint` route to
prove the raw PE path, then restore it before Day 7 (see the design challenge and the handoff open
item).

---

## Topic 4 — NSG enforcement on the PE subnet

### Theory

An NSG on a PE subnet is **silently not enforced** until
`private_endpoint_network_policies = "Enabled"` on the subnet. This is the critical gotcha: you can
attach a perfectly good allow/deny NSG and it does nothing to PE traffic until the flag is set. It
takes the **string** `"Enabled"` / `"Disabled"`.

Two rules are needed, and the second is not optional:
- **Allow** spoke1 (priority 100).
- **Explicit deny-all** (priority 4096) — because the default `AllowVnetInBound` (65000) admits the
  entire VNet address space **plus all peered VNets** (spoke1, spoke2, hub) with no restriction. An
  allow rule alone is meaningless: without the explicit deny, `AllowVnetInBound` lets spoke2 in
  underneath it. Ordering: allow-spoke1 (100) → deny-all (4096) → `AllowVnetInBound` (65000, never
  reached).

An NSG also does nothing until it is **associated** to the subnet — a rule set sitting in the RG
enforces nothing.

### Exercise 5 — PE-subnet NSG (`d05ex05`)

**Objective:** create the NSG (`azurerm_network_security_group`) `nsg-vg-lab-wus-hub-pe` — allow
spoke1 inbound, explicitly deny the rest — set `private_endpoint_network_policies = "Enabled"` on
the PE subnet (`azurerm_subnet`), and attach the NSG
(`azurerm_subnet_network_security_group_association`).

**Inputs:** NSG `nsg-vg-lab-wus-hub-pe`; allow spoke1 `172.22.16.0/24` at 100; deny-all at 4096;
`private_endpoint_network_policies = "Enabled"`; association to the PE subnet.

**Constraints:** the flag is the whole lesson — verify the string form for v3.117.1; scope the
allow source deliberately; standalone NSG with inline `security_rule` blocks (keep it off the Day-3
`has_nsg` factory); **must** include the subnet→NSG association.

**Predict:** total add/change; is the subnet-policy change a `~` or `-/+`?

**Solution** — try the exercise above before reading on.

```hcl
resource "azurerm_network_security_group" "storage_pe" {
  name                = "${local.nsg_name}-hub-pe"      # nsg-vg-lab-wus-hub-pe — standalone, not the has_nsg factory
  resource_group_name = data.azurerm_resource_group.main.name
  location            = azurerm_virtual_network.hub.location
  security_rule {
    name                       = "allow-spoke1-workload"
    description                = "allow spoke1's workload subnet to access PE subnet"
    protocol                   = "Tcp"                  # tightened to TCP/443 — least privilege for blob
    destination_port_range     = "443"
    source_port_range          = "*"
    priority                   = 100
    source_address_prefix      = "172.22.16.0/24"       # spoke1 WORKLOAD /24, not the whole /20
    destination_address_prefix = "*"
    access                     = "Allow"
    direction                  = "Inbound"
  }
  security_rule {
    name                       = "deny-all"             # required to override AllowVnetInBound (65000)
    description                = "explicitely deny all"
    protocol                   = "*"
    priority                   = 4096
    destination_address_prefix = "*"
    source_address_prefix      = "*"
    destination_port_range     = "*"
    source_port_range          = "*"
    access                     = "Deny"
    direction                  = "Inbound"
  }
}

resource "azurerm_subnet" "hub_pe" {
  resource_group_name               = data.azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.hub.name
  name                              = "${local.snet_name}-pe"
  address_prefixes                  = [var.hub.subnets_special.pe.cidr]  # 172.22.3.0/24 (NOT the firewall CIDR)
  private_endpoint_network_policies = "Enabled"        # the flag that makes the NSG actually enforce on the PE NIC
}

resource "azurerm_subnet_network_security_group_association" "hub_pe" {
  network_security_group_id = azurerm_network_security_group.storage_pe.id
  subnet_id                 = azurerm_subnet.hub_pe.id  # without this association the NSG enforces nothing
}
```

The `pe` subnet's data moved into `hub.subnets_special` in `terraform.tfvars` for this exercise
(part of the refactor — see [that section](#the-subnet-refactor-and-the-moved-blocks)); the
`azurerm_subnet.hub_pe` block above reads `var.hub.subnets_special.pe.cidr`:

```hcl
# terraform.tfvars — under hub.subnets_special
"pe" = { cidr = "172.22.3.0/24" }   # moved here from hub.subnets so the PE subnet can be configured individually
```

Run: `plan` → after the subnet refactor + `moved` blocks land (see the refactor section), the only
real changes are `2 to add` (NSG + association), with the subnet-policy set at creation. Apply.

**Re-test the PE from the VMs, and record your results** (test rig required). This time the NSG is
enforced:

```bash
curl -s "https://stvglabwus01.blob.core.windows.net/?comp=list"   # from spoke1, then spoke2
```

spoke1 → PE succeeds (allow at 100); **spoke2 → PE now fails** (deny-all at 4096, with the policy
flag making the NSG bite). Before the flag, spoke2 could reach the PE despite the NSG — the classic
audit finding. Record spoke1 vs spoke2 and compare to the "before vs after the flag" behavior.

### Q&A

**Q4 — You attach the NSG with correct allow/deny rules but spoke2 still reaches the PE. What did
you miss?**
`private_endpoint_network_policies = "Enabled"` on the subnet. Until it is set, NSGs (and UDRs) are
not applied to PE NIC traffic — the rules exist but are inert. It is a classic audit finding
because the config *looks* correct in the portal/state while enforcing nothing.

**Q5 — Why is an explicit deny-all at 4096 required when you have only *allowed* spoke1?**
Because the default `AllowVnetInBound` (65000) admits all VNet-space and peered-VNet traffic. Your
allow rule adds spoke1; it does not remove anyone. Without a higher-priority explicit deny, spoke2
(peered, same address space family) still matches `AllowVnetInBound` and gets in. The deny-all at
4096 sits above 65000 and closes that default hole while staying below your allow at 100.

---

## Topic 5 — SE vs PE comparison + outputs

### Theory

Consolidate what the two models actually enforce, then publish the PE facts Day 6 will read.

### Exercise 6 — Outputs (`d05ex06`)

**Objective:** expose the PE identity/IP, storage account ID, and privatelink zone ID for Day 6's
remote-state read.

**Predict:** does adding outputs change infrastructure? (`plan` should show only output additions,
no resource changes.)

**Solution** — try the exercise above before reading on.

```hcl
###---d05ex06 >>>
output "storage_pe_id" {
  value       = azurerm_private_endpoint.lab_storage.id
  description = "id of storage PE in hub"
}
output "storage_pe_private_ip" {
  # computed PE IP, same attribute the A record consumes — not a literal
  value       = azurerm_private_endpoint.lab_storage.private_service_connection[0].private_ip_address
  description = "ip address of storage PE in hub"
}
output "storage_account_id" {
  value       = azurerm_storage_account.lab.id
  description = "id of lab storage account hub"
}
output "storage_privatelink_zone_id" {
  value       = azurerm_private_dns_zone.lab_storage_pe.id
  description = "id of storage PE's privatelink dns zone"
}
###---d05ex06 <<<
```

Run: `plan` → "You can apply this plan to save these new output values ... without changing any
real infrastructure" → apply. `storage_pe_private_ip = 172.22.3.4`.

### The SE-vs-PE behavior matrix (measured live)

The probe that discriminates cleanly is a **well-formed** request whose error *code* you read —
not the bare-root `curl -I`, which returns `400 InvalidQueryParameterValue` from the storage front
door regardless of the firewall (a malformed-request artifact, not a verdict):

```bash
curl -s "https://stvglabwus01.blob.core.windows.net/?comp=list"
```

Read the `<Code>` in the XML body:
- **`AuthorizationFailure`** → blocked at the **network** (firewall/PE). Never reached the data layer.
- **`PublicAccessNotPermitted`** → **passed** the network; refused only because the request was
  anonymous and the account forbids anonymous access. (This is the *success* signal for a network test.)
- **empty / hang** → never reached storage at all (routing blackhole).

| Source | SE era (public IP) | PE + links (private `172.22.3.4`) | PE, links removed (public again) |
|---|---|---|---|
| **spoke1** (SE + VNet rule) | `PublicAccessNotPermitted` — SE allows, anonymous auth refused | hang — PE IP hits the Day-4 UDR → dead firewall | `PublicAccessNotPermitted` — SE, back on public |
| **hub** (same region, not allow-listed) | `AuthorizationFailure` — firewall denies | `PublicAccessNotPermitted` — private path works | `PublicAccessNotPermitted` — same-region, reached (non-deterministic) |
| **spoke2** (dead `0.0.0.0/0` UDR) | empty — routing blackhole | `PublicAccessNotPermitted` — private path works | empty — routing blackhole |
| **laptop** (public internet, not allow-listed) | — | — | `AuthorizationFailure` — firewall denies public traffic |

The payoff is the middle column: **with the PE + links, hub and spoke2 — which the SE model either
denied or blackholed — both reach storage privately.** The PE is the control that works for every
VNet, not just the allow-listed one. (spoke1's hang in that column is not a PE failure; it is the
Day-4 firewall-placeholder UDR, which Day 7 resolves.)

> **Take the SE column with a grain of salt — SE behaved non-deterministically in testing.** The
> same-region hub result flipped between `AuthorizationFailure` (firewall denied) and
> `PublicAccessNotPermitted` (reached storage) across runs. That could be a lab artifact or the
> documented same-region public-endpoint behavior (where the storage firewall can't reliably
> evaluate same-region private source IPs). We didn't have time to run it down to a concrete root
> cause, so treat the same-region SE cells as "observed, not proven." The PE columns were
> consistent. This inconsistency is itself a mark against relying on the SE/public-endpoint firewall
> for same-region isolation — a point in favor of the PE.

### Q&A

**Q6 — In one sentence each, what blocks spoke2 in the SE model vs the PE model?**
SE model: the **storage firewall** (`default_action = Deny`, spoke2 not allow-listed) blocks spoke2
*at the storage service* — when spoke2 can reach the public endpoint at all. PE model: the
**PE-subnet NSG** (deny-all at 4096, with `private_endpoint_network_policies = Enabled`) blocks
spoke2 *at the network*, before it reaches the PE NIC.

---

## Test rig (scope addition) — VMs, Bastion, power script

This rig is **beyond the passport scope** — added to validate Labs 4a/4b from real VMs. The whole
rig is gated behind `var.enable_test_vms` (default `false`) so it can be planned away without
touching the base, and it is designed to be destroyed at end of training.

**Design principles proven here:**
- Terraform owns the **VMs** (create/destroy). It does **not** manage power state —
  `azurerm_linux_virtual_machine` has no power-state attribute, so an out-of-band `az vm deallocate`
  produces **no drift**. That is why start/stop lives in a PowerShell helper, not in `.tf`.
- Bastion **Developer SKU works on azurerm v3.117.1** via `virtual_network_id` (no `azapi` needed).
  Developer SKU cannot traverse peering, so there is one per VNet.
- VMs use **static** private IPs so a deallocate→start cycle does not churn the address.

```hcl
# d05-test_vms.tf — for_each over var.test_vms, gated by var.enable_test_vms
resource "azurerm_network_interface" "test" {
  for_each            = var.enable_test_vms ? var.test_vms : {}     # empty map when off → zero instances
  name                = "${local.nic_name}-${each.key}-test"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.test_vms_subnet_ids[each.key]  # local joins the data to live subnet refs
    private_ip_address_allocation = "Static"                             # static, per IP schema
    private_ip_address            = each.value.private_ip
  }
}

resource "azurerm_linux_virtual_machine" "test" {
  for_each                        = var.enable_test_vms ? var.test_vms : {}
  name                            = "${local.vm_name}-${each.key}"       # vm-vg-lab-wus-<key> — matches Lab-Power.ps1
  location                        = data.azurerm_resource_group.main.location
  resource_group_name             = data.azurerm_resource_group.main.name
  size                            = "Standard_B1s"
  admin_username                  = "azureuser"
  admin_password                  = var.vm_admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.test[each.key].id]
  os_disk { caching = "ReadWrite"  storage_account_type = "Standard_LRS" }  # inline block, not a separate managed disk
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
  boot_diagnostics {}                                # managed storage — sidesteps the CLI boot-diag bug
  tags = local.lab_tags
  lifecycle {
    # without this, a fresh shell with no TF_VAR_vm_admin_password nulls admin_password → ForceNew → VM destroy.
    # ignoring it means Terraform stops diffing the password after create (fine for throwaway lab VMs).
    ignore_changes = [admin_password]
  }
}
```

```hcl
# d05-test_bastion.tf — one Developer Bastion per VNet, same gate
resource "azurerm_bastion_host" "test" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  for_each            = var.enable_test_vms ? local.vnet_ids : {}
  name                = "${local.bastion_name}-${each.key}"
  sku                 = "Developer"                  # works on v3.117.1; no AzureBastionSubnet / public IP needed
  virtual_network_id  = each.value
}
```

```powershell
# lab-power.ps1 — power state lives OUTSIDE Terraform (no drift). .\lab-power.ps1 -Action Start|Stop
param([Parameter(Mandatory)][ValidateSet('Start','Stop')]$Action)
$rg  = 'rg-vg-lab-wus-01'
$vms = @('vm-vg-lab-wus-spoke1','vm-vg-lab-wus-spoke2','vm-vg-lab-wus-hub')
foreach ($vm in $vms) {
  if ($Action -eq 'Start') { az vm start     --resource-group $rg --name $vm --no-wait }
  else                     { az vm deallocate --resource-group $rg --name $vm --no-wait }  # deallocate: compute billing stops, disk/NIC kept
}
```

Variables added for the rig (`variables.tf`):

```hcl
###---d05-test-vms >>>
variable "test_vms" {
  type = map(object({ private_ip = string }))
}
variable "enable_test_vms" {
  type    = bool
  default = false                    # rig off by default → empty map → zero instances
}
variable "vm_admin_password" {
  type      = string
  sensitive = true
  default   = null                   # supply via: $env:TF_VAR_vm_admin_password = '...'
}
###---d05-test-vms <<<
```

tfvars data (`terraform.tfvars`) — the pure data (IPs); the local below joins each key to its live
subnet reference:

```hcl
###---d05-test-vms >>>
test_vms = {
  "hub"    = { private_ip = "172.22.2.4" }
  "spoke1" = { private_ip = "172.22.16.4" }
  "spoke2" = { private_ip = "172.22.32.4" }
}
enable_test_vms = true
###---d05-test-vms <<<
```

Locals added (`locals.tf`) — the name-chain entries and the data→reference join (`vnet_ids` is
shared with the PE DNS links and lives under the PE marker, shown in Ex 4):

```hcl
# locals.tf
nic_name     = "nic-${local.prefix}"       # d05-test_vms
vm_name      = "vm-${local.prefix}"         # d05-test_vms
bastion_name = "bastion-${local.prefix}"    # d05-test_bastion

###---d05-test_vms >>>
test_vms_subnet_ids = {                     # joins each var.test_vms key to its live subnet ref
  hub    = azurerm_subnet.hub["shared"].id
  spoke1 = azurerm_subnet.spoke1.id
  spoke2 = azurerm_subnet.spoke2.id
}
###---d05-test_vms <<<
```

---

## The subnet refactor and the `moved` blocks

Ex 5 needed the PE subnet configured individually (its own NSG + network-policy flag), which the
Day-3 `subnets_hub` / `subnets_hub_reserved` model did not accommodate — `pe` never fit "reserved"
(reserved subnets carry no config; `pe` carries real config). The variable was restructured into a
single `hub` object with two maps: `subnets` (for-loopable, uniform) and `subnets_special`
(individually defined, each handled by a dedicated resource block):

```hcl
variable "hub" {
  type = object({
    subnets = map(object({
      cidr              = string
      has_nsg           = bool
      service_endpoints = optional(list(string), [])
      delegations = optional(map(object({    # renamed delegation -> delegations (plural: can hold multiple)
        service_name    = string
        service_actions = list(string)
      })), {})
    }))
    subnets_special = map(object({ cidr = string }))
  })
}
```

`GatewaySubnet`, `AzureFirewallSubnet`, and `pe` became standalone `azurerm_subnet` resources
(`hub_gateway`, `hub_azurefirewall`, `hub_pe`), moved out of the old `hub["pe"]` /
`hub_reserved[...]` addresses.

**Why this needed `moved` blocks.** Renaming a resource's Terraform *address* (e.g.
`hub_reserved["GatewaySubnet"]` → `hub_gateway`) without telling Terraform reads as **destroy the
old + create the new** — which for `GatewaySubnet` is an outage risk and for the PE subnet would
destroy the PE inside it. A `moved` block says "the thing formerly tracked at address A is now at
address B": it rewrites the *state address label* on the existing entry, keeping the same real
resource. Pure state bookkeeping, no API calls.

```hcl
# d05-moved.tf — applied during the refactor, then commented out (retired) once the moves were in state.
# moved {
#   from = azurerm_subnet.hub["pe"]
#   to   = azurerm_subnet.hub_pe
# }
# moved {
#   from = azurerm_subnet.hub_reserved["GatewaySubnet"]
#   to   = azurerm_subnet.hub_gateway
# }
# moved {
#   from = azurerm_subnet.hub_reserved["AzureFirewallSubnet"]
#   to   = azurerm_subnet.hub_azurefirewall
# }
```

**Why the moves came out as *no-ops*, not ForceNew — and what the move does and does not protect.**
A `moved` block matches on the resource's real-world **ARM ID**, not its Azure name. After it
relinks the state entry to the new address, Terraform diffs the new config against the existing
resource's real attributes:
- The naming-convention change (`"${local.snet_name}-pe"` in the new block vs the old for_each key)
  changed how the name *string is constructed*, but it still **resolves to the identical**
  `snet-vg-lab-wus-pe`. Terraform compares resolved values, not expressions → no change.
- The CIDR, VNet, and RG also resolved unchanged → the relinked resource is a full no-op.

Had the resolved **name** differed (say `...-priv-endpoint`), the `moved` block would still have
relinked the address, but the diff would then see a changed `name` — a **ForceNew** attribute — and
plan a `-/+` destroy-and-recreate. The move migrates *state addresses*; it never reconciles
*attribute drift*. Two independent things had to be right for the clean result: the move (identity)
**and** the resolved attributes staying unchanged (the CIDR fix that kept the PE subnet on
`172.22.3.0/24`). Lifecycle: `moved` blocks are consumed at **apply**; once the state lives at the
new address they are inert and safe to remove (retired here by commenting out).

---

## Design challenge

**What can stop the UDR blackholing spoke1's PE traffic?** The blackhole exists because
`172.22.3.0/24` routes to `172.22.1.4`, where nothing answers yet. Two things resolve it: (a) stand
up the real Azure Firewall at `172.22.1.4` (Day 7), so the next hop actually forwards; or (b)
remove or repoint that UDR, so spoke1's PE traffic follows the effective routes straight to
`172.22.3.4`. For the purpose of *this* lab — the firewall doesn't exist yet — you can simply
**comment out** the `spoke1_to_private_endpoint` route to prove the raw PE path works, then restore
it before Day 7. (In the zipped end-state that route is commented out — an open item to restore.)

**Post-firewall spoke1 → storage-PE path, and which control filters.** When the PE is created, Azure
auto-injects a **`/32` route to the PE's private IP** (`172.22.3.4/32`) into VNets that can reach it.
That `/32` is more specific than any `172.22.3.0/24` UDR, so longest-prefix-match always picks the
`/32` and sends traffic straight to the PE — **a UDR cannot force PE traffic through a firewall**,
because you cannot out-specific a `/32`. Verdict on the four candidate controls:
- **PE-subnet NSG** — *the* control doing the filtering.
- **`private_endpoint_network_policies = "Enabled"`** — not a filter itself; the switch that makes
  the NSG apply to the PE NIC.
- **storage firewall (`Deny`)** — no-op; PE traffic never hits the public endpoint.
- **spoke1 UDR (`172.22.3.0/24 → fw`)** — no-op; out-specified by the PE `/32`.

**Scoping decision:** allow the spoke1 **workload `/24`** (`172.22.16.0/24`), not the whole `/20` —
least privilege, smaller blast radius, add rules as new subnets legitimately need the PE. Regardless
of scope, the **explicit deny-all at 4096** is mandatory, because `AllowVnetInBound` (65000) admits
all VNet + peered-VNet space by default (so spoke2 would otherwise reach the PE). The PE lives in the
hub and spoke1 reaches it **over peering**, which is precisely why source-prefix scoping — not
"same VNet" — is what matters, and why `AllowVnetInBound` counting peered space is the hole the
deny-all closes.

---

## Corrections & gotchas

| # | Gotcha | Correction |
|---|---|---|
| 1 | `curl -I` to the storage **root** returns `400 InvalidQueryParameterValue` from every source (allowed, denied, same-region) | The bare-root HEAD is malformed and 400s at the front door **independent of the firewall**. It is not a verdict. Use a well-formed request (`/?comp=list`) and read the error **code**, not the HTTP status. |
| 2 | `AuthorizationFailure` vs `PublicAccessNotPermitted` read as two flavors of "denied" | They are a depth gauge: `AuthorizationFailure` = blocked at the **network** (never reached data). `PublicAccessNotPermitted` = **passed** the network, refused only because the request was anonymous. For a network test, `PublicAccessNotPermitted` is the *success* signal. |
| 3 | Assumed hub "leaks through" the storage firewall because it's same-region | Walked back: the "leak" was read off the malformed `400` probe (see #1). With the proper probe, hub returned `AuthorizationFailure` (firewall **denied** it) in the clean run — but SE same-region results flipped across runs, so treat this as *observed, not proven* (lab artifact vs the documented same-region public-endpoint behavior — no time to root-cause). Note the documented "no effect same-region" limitation is specifically about **IP** rules. Either way, the inconsistency argues for PE over SE for same-region isolation. |
| 4 | `admin_password` variable with `default = null` → a fresh shell (no `TF_VAR_vm_admin_password`) nulls it → **ForceNew destroy** of live VMs | `lifecycle { ignore_changes = [admin_password] }` stops Terraform diffing the password after create — removes the whole failure mode for throwaway lab VMs. (Alternative: `random_password` so the value lives in state, not the shell.) |
| 5 | Refactor moved subnets to new resource addresses → plan showed **destroy + recreate** of `GatewaySubnet`, `AzureFirewallSubnet`, and the PE (with its NIC/IP) | Add `moved` blocks: they migrate the **state address** (matched on ARM ID), turning destroy+create into a no-op — provided the resolved attributes (name, CIDR) are unchanged. A move never shields you from real attribute drift. |
| 6 | Copy-paste bug: `hub_pe` addressed with `AzureFirewallSubnet.cidr` (`172.22.1.0/26`) instead of `pe.cidr` (`172.22.3.0/24`) | Fixed to `var.hub.subnets_special.pe.cidr`. A wrong CIDR here would have forced the PE-subnet (and PE) replacement even *with* the `moved` block. |
| 7 | NSG created + `private_endpoint_network_policies = "Enabled"` set, but **no subnet→NSG association** | An unassociated NSG enforces nothing. Added `azurerm_subnet_network_security_group_association.hub_pe`. Separately, the policy flag is what makes the (associated) NSG actually apply to the PE NIC. |
| 8 | Removing the private DNS zone's VNet link silently reverts clients to the **public** endpoint | No error is raised — the resolver falls through to public DNS, which CNAMEs onward to the public IP. The VNet↔zone link is what makes the PE private; treat it as load-bearing. |

---

_Open items carried to Day 6/7 (see `HANDOFFS.md`): the `spoke1_to_private_endpoint` route
(`172.22.3.0/24 → 172.22.1.4`) is commented out in the end-state and must be restored before Day 7
wires the real firewall; the test rig (`enable_test_vms`) is live and should be deallocated between
sessions and destroyed at end of training._