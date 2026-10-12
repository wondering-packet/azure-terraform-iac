# Topic 3 — Azure DNS (Private & Public Zones)

---

## AWS Anchor

| AWS | Azure Equivalent |
|---|---|
| Route 53 Public Hosted Zone | Azure DNS Public Zone |
| Route 53 Private Hosted Zone (PHZ) | Azure DNS Private Zone |
| Route 53 Resolver Inbound Endpoint | Azure DNS Private Resolver — Inbound Endpoint |
| Route 53 Resolver Outbound Endpoint | Azure DNS Private Resolver — Outbound Endpoint |
| Resolver Rules (forwarding) | DNS Forwarding Rulesets |

Key difference: In AWS, associating a PHZ to a VPC is a single step and VMs can immediately resolve records. In Azure, the linking model is more explicit — registration vs resolution links are separate concepts, and the Private Resolver architecture has more moving parts.

---

## Theory

### Public vs Private Zones

**Public zones** — same as Route 53 public hosted zones. You own a domain, delegate it to Azure DNS name servers, records are resolvable from anywhere on the internet.

**Private zones** — resolvable only from VNets you explicitly link them to. Equivalent to Route 53 PHZ but the linking mechanism is more explicit and has more operational surface area.

---

### 168.63.129.16 — The Azure Magic DNS IP

This IP underpins everything in Azure DNS.

- **What it is:** A virtual public IP — not a VM, not a physical device. A fabric-level anycast address present in every Azure VNet on every subnet
- **Cannot be blocked** — NSGs cannot filter it, Azure enforces this at platform level
- **Two purposes:**
  1. Default DNS resolver for all Azure VMs unless overridden at VNet level
  2. Source IP for Azure Load Balancer health probes

**DNS resolution context:** When a VM queries `168.63.129.16`, the fabric resolves in the context of that VM's VNet. It checks:
1. Private DNS zones linked to that VNet
2. DNS Forwarding Rulesets associated to that VNet
3. Falls back to public DNS for everything else

**Critical implication:** If you configure a custom DNS server at the VNet level (e.g. pointing to Private Resolver Inbound Endpoint), `168.63.129.16` is bypassed for VM queries. But your custom server itself still uses `168.63.129.16` to resolve Azure private zones — which is why the Inbound Endpoint must be in a VNet that has the relevant zone links.

---

### Auto-Registration

When a private DNS zone is linked to a VNet with **registration enabled**, Azure automatically:
- Creates an A record for each VM: `<vm-hostname>.<zone-name>`
- Points the A record at the VM's private IP
- Creates corresponding PTR records automatically
- Deletes records when the VM's NIC is removed

**Hard limits:**
- **Only one VNet can have registration enabled per private zone** — this is enforced by the platform
- Auto-registration is **IPv4 only** — no AAAA record auto-registration
- PTR records are auto-created in the corresponding `in-addr.arpa` zone

---

### VNet Links — Registration vs Resolution

| Link Type | Auto-Registration | Resolution | Limit |
|---|---|---|---|
| Registration link | ✅ Yes | ✅ Yes (implied) | 1 per zone |
| Resolution link | ❌ No | ✅ Yes | No limit |

**Registration is a superset of resolution** — a registration link gives you both. A resolution link gives you resolution only.

**Key implication:** A private zone linked to VNet A is invisible to VNet B unless VNet B is explicitly added as a resolution link. This is the most common DNS misconfiguration in hub-spoke — zone linked to hub only, spokes can't resolve.

---

### DNS Resolution Flow in Hub-Spoke

Private zone `internal.contoso.com` linked to hub only, no spoke links:

```
Spoke VM queries server1.internal.contoso.com
  → 168.63.129.16 in spoke VNet context
  → Checks zones linked to spoke VNet
  → No link found → NXDOMAIN
```

**Fix:** Link the private zone to every VNet that needs to resolve it — hub AND all spokes.

**At scale:** Every new spoke needs to be linked to every relevant private zone. This is operational overhead — teams that don't plan for it end up with DNS failures every time a new spoke is added.

---

### Azure DNS Private Resolver

Managed replacement for custom DNS server VMs. Deployed inside your VNet via **delegated subnets** — each endpoint type needs its own dedicated subnet delegated to `Microsoft.Network/dnsResolvers`.

#### Subnet delegation
Delegation means the subnet is exclusively reserved for that Azure service. No VMs, no other resources. You own the subnet and define its CIDR, but Azure controls what runs inside it. Minimum subnet size: /28.

#### Inbound Endpoint
- Gets a **private IP** from its delegated subnet (static or dynamic)
- On-prem DNS servers and spoke VMs forward queries to this IP
- Resolution happens in the context of the hub VNet — sees all private zones linked to hub
- Zone-redundant by default — Microsoft manages HA within a region
- For cross-region HA: deploy a resolver per region, use Traffic Manager or on-prem DNS round-robin

#### Outbound Endpoint
- **Does not expose a usable frontend IP** — Outbound endpoint doesn’t expose a client-facing IP, but uses IPs from its subnet for egress.
- Internal egress mechanism only — used by the resolver to send queries out to on-prem or external DNS
- Cannot be directly addressed by clients
- Source IP for outbound queries comes from the outbound endpoint's subnet CIDR — not predictable as a single IP
- **On-prem firewall implication:** Allow the entire outbound endpoint subnet CIDR for UDP/53 inbound on your on-prem firewall

#### When to deploy what

| Scenario | Deploy |
|---|---|
| Cloud-only, just need private zone resolution | Nothing — 168.63.129.16 + zone links handles it natively |
| On-prem needs to resolve Azure private DNS | Inbound Endpoint only |
| Azure VMs need to resolve on-prem DNS | Outbound Endpoint + Forwarding Ruleset |
| Full hybrid — both directions | Both endpoints |

---

### DNS Forwarding Rulesets

A group of DNS forwarding rules attached to an Outbound Endpoint and linked to VNets.

**Rule properties:** Domain name, destination IP:Port, enabled/disabled state

**Rule evaluation:** Longest prefix match — same principle as route tables. `eu.corp.contoso.local` beats `corp.contoso.local` for a query against `fileserver.eu.corp.contoso.local`.

**Ruleset association:** Must be linked to VNets for `168.63.129.16` in those VNets to consult the rules. In centralized hub-spoke architecture, link to hub VNet — all spoke traffic funnels through the inbound endpoint anyway.

**Critical warning — DNS resolution loop:** Never create a ruleset rule pointing at your own inbound endpoint IP AND link that ruleset to the same VNet where the inbound endpoint lives. This creates an infinite forwarding loop:
```
168.63.129.16 → matches rule → forwards to inbound endpoint
→ inbound endpoint → 168.63.129.16 → matches rule again → loop
```

---

### Conditional Forwarding — Full Hybrid DNS

Two directions to solve independently:

#### Direction 1 — On-prem → Azure
```
On-prem DNS server
  → Conditional forwarder: internal.contoso.com → Inbound Endpoint IP
  → Query crosses ExpressRoute/VPN
  → Inbound Endpoint receives query
  → Forwards to 168.63.129.16 in hub VNet context
  → Resolves against linked private zone
  → Response back to on-prem client
```

**Config required:**
- Conditional forwarder on on-prem DNS server pointing to Inbound Endpoint IP
- Private zone linked to hub VNet

#### Direction 2 — Azure → On-prem (Pattern A: ruleset VNet link)

This is the baseline pattern. The VM uses **default Azure DNS (`168.63.129.16`)** — no custom DNS setting, no inbound endpoint. The ruleset is linked to the VM's own VNet, which is what makes `168.63.129.16` consult the forwarding rules.

```
Spoke VM (uses default DNS 168.63.129.16)
  → 168.63.129.16 resolves in the VM's own VNet context
  → 168.63.129.16 checks:
      1. Private zones linked to this VNet → no match for corp.contoso.local
      2. Forwarding Ruleset linked to this VNet → matches corp.contoso.local → 192.168.1.10
  → Query exits via Outbound Endpoint → ExpressRoute → on-prem DNS 192.168.1.10
  → On-prem resolves → response back to Spoke VM
```

**Config required:**
- Outbound Endpoint deployed (the ruleset must reference one; this is the egress mechanism)
- DNS Forwarding Ruleset with rule for on-prem domain → on-prem DNS IP
- Ruleset **linked to the VM's VNet**
- **No inbound endpoint required** for this direction

**Note — when Pattern B applies instead:** If an inbound endpoint is already deployed and the design routes *all* spoke DNS through it (spoke VMs set custom DNS = inbound endpoint IP, e.g. for centralized DNS or on-prem→Azure resolution), then queries hit the inbound endpoint first and resolve in the **hub** VNet context. In that case the ruleset must be linked to the **hub** VNet, and the flow becomes:

```
Spoke VM (custom DNS = inbound endpoint IP 10.232.1.10)
  → UDP/53 to Inbound Endpoint in hub → resolves in HUB VNet context
  → Ruleset linked to HUB VNet matches → Outbound Endpoint → on-prem DNS
```

Both patterns forward correctly. Pattern A keeps VMs on default DNS and links the ruleset per-VNet; Pattern B centralizes through the inbound endpoint and links the ruleset to the hub. Pick Pattern B only when you already need the inbound endpoint for another reason.

#### Complete hybrid config checklist

| Resource | Purpose |
|---|---|
| Private Resolver — Inbound Endpoint | On-prem and spoke VMs send queries here |
| Private Resolver — Outbound Endpoint | Queries exit Azure toward on-prem via this |
| DNS Forwarding Ruleset | Rules mapping on-prem domains to on-prem DNS IPs |
| Ruleset associated to hub VNet | Makes 168.63.129.16 consult forwarding rules |
| On-prem conditional forwarder | Points Azure private domain queries at Inbound Endpoint IP |
| Private zone linked to hub VNet | Zone resolvable by 168.63.129.16 in hub context |

This checklist is for **full hybrid** (both directions). The Inbound Endpoint here is required for **Direction 1 (on-prem → Azure)** and for centralized spoke DNS — it is *not* what makes Direction 2 forwarding work. Direction 2 forwarding is driven by the ruleset VNet link + Outbound Endpoint (Pattern A). If you don't need on-prem to resolve Azure zones, you can drop the Inbound Endpoint entirely and still forward Azure → on-prem.

---

### Scaling: Pattern A vs Pattern B at 100 Spokes

The choice between Pattern A and Pattern B stops being cosmetic once spoke count grows.

**Pattern A (default DNS + per-VNet links) does not scale cleanly.** Every private zone and every ruleset must be linked to every VNet that needs it. At 100 spokes that's ~100 resolution links per zone plus ~100 ruleset links, and every new spoke repeats the whole linking exercise across all zones and rulesets. The forwarding logic is correct — it's the operational overhead that grows linearly and eventually becomes unmanageable.

**Pattern B (centralized inbound endpoint) is the scalable design.** Point all 100 spokes' custom DNS at the single inbound endpoint in the hub, and link each private zone and the forwarding ruleset **once** to the hub VNet. Spoke queries resolve in the hub's context — they inherit every zone and ruleset linked to the hub without needing their own links. Adding spoke #101 requires only its DNS setting pointed at the inbound endpoint IP plus peering — **zero new zone/ruleset links.**

**Correct wording for the design:** a ruleset is a standalone resource that references an **Outbound Endpoint** and is **linked** to one or more VNets. In Pattern B you *link* the ruleset to the hub VNet — you don't "create it on" the VNet. The link is its own object (in Terraform, `azurerm_private_dns_resolver_virtual_network_link`), separate from the ruleset resource.

**The 100-spoke design in one line:**
> Point all spokes' DNS at the hub's inbound endpoint; link the private zones **and** the forwarding ruleset **once** to the hub VNet; ruleset rules target **on-prem DNS IPs only**.

**Loop hazard to respect in this exact design:** because the ruleset is linked to the hub VNet (the resolver's own VNet), never add a rule that forwards an Azure private zone the hub already resolves natively to the inbound endpoint IP — that's the infinite forwarding loop described under DNS Forwarding Rulesets above. Ruleset rules in Pattern B should point only at on-prem/external DNS.

**The trade-off you're signing up for:** Pattern B trades link-sprawl for a single DNS choke point. Usually the right trade — and it gives centralized query logging for free (diagnostic settings on the inbound endpoint) — but the resolver is now in the blast radius for all spokes. The Private Resolver is zone-redundant by default within a region, which covers intra-region HA; for cross-region resilience, deploy a resolver per region. Not a reason to avoid Pattern B, just the cost of centralizing.

---

### Production Auto-Registration Pattern for Multi-Spoke

Since only one VNet can hold the registration link per zone, spokes cannot auto-register. Production workaround:

**Event Grid + Azure Function automation:**
1. Event Grid watches for VM creation events in spoke subscriptions
2. Triggers an Azure Function
3. Function extracts VM's private IP and hostname
4. Function calls Azure DNS API to create A record in the private zone

Spoke VNets get resolution links only. Hub holds the single registration link. Spoke VMs are registered via automation.

---

## Exercises

### Exercise 1 — Three DNS Failures ✅

**Scenario:** Hub-spoke with 3 spokes. Private zone `internal.contoso.com` linked to hub only with registration enabled. No other links. VM `appvm01` in Spoke 1 fails to auto-register. Spoke 2 VM fails to resolve `appvm01.internal.contoso.com`. Hub VM also fails to resolve it.

**Solutions:**

**Failure 1 — Spoke 1 VM fails to auto-register:**
Hub VNet already holds the single registration link for `internal.contoso.com`. The platform enforces a hard limit of one registration link per zone. Spoke 1 cannot auto-register regardless of how its VNet link is configured.

**Failure 2 — Spoke 2 VM fails to resolve:**
No A record exists for `appvm01` — auto-registration failed (Failure 1). No record = nothing to resolve regardless of zone links.

**Failure 3 — Hub VM fails to resolve:**
Same root cause as Failure 2. The zone is linked to the hub with registration enabled (which implies resolution). But the A record for `appvm01` was never created because Spoke 1 couldn't auto-register. Registration link ≠ records exist. No record = NXDOMAIN for everyone including the hub.

**Single root cause for all three failures:** The A record was never created.

**Fix:** Either manually create the A record for `appvm01` in the zone, or use automation (Event Grid + Azure Function) to handle spoke VM registration.

---

### Exercise 2 — Hybrid DNS Architecture ✅

**Scenario:** On-prem domain `corp.contoso.local` at `192.168.1.10`. Azure private zone `internal.contoso.com` linked to hub. ExpressRoute connecting on-prem to hub. Private Resolver in hub with Inbound Endpoint `10.232.1.10` and Outbound Endpoint (no IP — subnet only). All spokes DNS set to `10.232.1.10`.

**Direction 1 — On-prem resolving `server1.internal.contoso.com`:**

Resolution path:
```
On-prem client
  → On-prem DNS checks conditional forwarder for internal.contoso.com
  → Forwards UDP/53 to 10.232.1.10 via ExpressRoute
  → SDN delivers to Inbound Endpoint
  → Inbound Endpoint → 168.63.129.16 (Azure DNS) → Private zone resolution
  → 168.63.129.16 finds internal.contoso.com linked to hub VNet → resolves record
  → Response back via Inbound Endpoint → ExpressRoute → on-prem client
```

Config required:
- Conditional forwarder on on-prem DNS: `internal.contoso.com → 10.232.1.10`
- Private zone `internal.contoso.com` linked to hub VNet

**Direction 2 — Azure Spoke VM resolving `fileserver.corp.contoso.local`:**

> This scenario is **Pattern B** by design — the scenario states all spokes are configured with DNS = `10.232.1.10` (the inbound endpoint), so every spoke query routes through the inbound endpoint and resolves in hub context. The ruleset is therefore linked to the hub VNet. (Pattern A — VMs on default `168.63.129.16` with the ruleset linked per-VNet, no inbound endpoint — is the alternative when you're not centralizing DNS through the inbound endpoint.)

Resolution path:
```
Spoke VM
  → UDP/53 to Inbound Endpoint 10.232.1.10 (Routed over VNet peering to the inbound endpoint IP)
  → Inbound Endpoint receives query, resolves in hub VNet context
  → 168.63.129.16 checks private zones linked to hub → no match for corp.contoso.local
  → 168.63.129.16 checks Forwarding Ruleset associated to hub VNet
  → Matches rule: corp.contoso.local → 192.168.1.10
  → Query exits via Outbound Endpoint → ExpressRoute → on-prem DNS 192.168.1.10
  → On-prem resolves → response back to Spoke VM via Inbound Endpoint
```

Config required:
- Outbound Endpoint deployed in hub
- DNS Forwarding Ruleset with rule: `corp.contoso.local → 192.168.1.10`
- Ruleset associated to hub VNet

**Remember this model**
```
VM → DNS setting decides:
    → 168.63.129.16 (default path)
    OR
    → Inbound Endpoint (custom DNS)

Inbound Endpoint:
    → Azure DNS (private zones)
    → Ruleset → Outbound Endpoint → external DNS
```
---

### Exercise 3 — Scale & Logging Requirements ✅

**Requirement A — New Spoke 4 needs auto-registration into `internal.contoso.com`:**

Cannot be fulfilled as stated. The registration link slot is already held by the hub VNet. Azure enforces one registration link per zone — hard platform limit.

**Best alternative:**
- Add Spoke 4 as a resolution link to `internal.contoso.com` — VMs can resolve the zone
- Deploy automation (Event Grid + Azure Function) to register Spoke 4 VM IPs and hostnames as A records in the zone on VM creation
- Spoke 4 VMs use `10.232.1.10` as DNS — resolution works immediately via the inbound endpoint

**Requirement B — Centralized DNS query logging:**

Use **Azure Monitor Diagnostic Settings** on the Private Resolver resource:
- Enable DNS query log category on the Inbound Endpoint
- Ship logs to a **Log Analytics Workspace**
- Every DNS query hitting the inbound endpoint is logged — source IP, queried FQDN, response, timestamp

Since all spoke VMs funnel DNS through the inbound endpoint, this gives centralized visibility across every VM in every spoke without touching individual VMs. Standard Azure-native logging pattern used across all managed services.

---

## Q&A Bank

**Q1.** You have a hub-spoke with 5 spokes. You need all VMs across all spokes resolvable by each other. One private zone, minimal operational overhead. Design the zone linking strategy and explain what happens when a new VM spins up in a non-registration spoke.

**A1.** 1 registration link on hub VNet (implies resolution for hub). 5 resolution links on each spoke. Total 6 links. When a new VM spins up in a non-registration spoke, no auto-registration occurs — an automated workflow (Event Grid + Azure Function) must create the A record in the zone via the Azure DNS API. Without automation, the VM is unreachable by name from other spokes.

---

**Q2.** A spoke VM resolves `server1.internal.contoso.com` successfully. An on-prem client gets NXDOMAIN for the same record. ExpressRoute is up, ping to the inbound endpoint works. Name three distinct configuration mistakes that could cause this.

**A2.**
1. Missing conditional forwarder on on-prem DNS server for `internal.contoso.com` — queries never get sent to the inbound endpoint
2. NSG on the inbound endpoint subnet blocking UDP/53 inbound — ICMP (ping) passes but DNS queries are dropped
3. On-prem firewall blocking UDP/53 outbound toward the inbound endpoint IP

---

**Q3.** A cloud-only startup with hub-spoke and 4 spokes wants VMs to resolve each other's names. Junior engineer proposes deploying Private Resolver with both endpoints. What's wrong with this and what's the correct architecture?

**A3.** Over-engineering. No hybrid connectivity means no need for Private Resolver at all. `168.63.129.16` handles private zone resolution natively. Correct architecture: one private zone, 1 registration link on hub, 4 resolution links on spokes, automated workflow for spoke VM registration. Zero resolver endpoints, zero custom DNS server settings.

---

**Q4.** You have a hub VNet with a Private Resolver inbound endpoint at `10.232.1.10`, a private zone `internal.contoso.com` linked to hub, and a DNS Forwarding Ruleset linked to hub with rule `internal.contoso.com → 10.232.1.10`. A hub VM queries `server1.internal.contoso.com`. What happens?

**A4.** Infinite DNS resolution loop. `168.63.129.16` checks the ruleset, matches the rule, forwards to `10.232.1.10` (inbound endpoint), inbound endpoint forwards back to `168.63.129.16`, which matches the rule again, and so on until timeout. Fix: never create a ruleset rule pointing at your own inbound endpoint and link that ruleset to the same VNet where the inbound endpoint lives. The hub VNet resolves `internal.contoso.com` natively via the zone link — no ruleset rule needed for it.

---

**Q5.** Existing hybrid DNS works perfectly for `corp.contoso.local → 192.168.1.10`. You add a new rule to the existing ruleset: `eu.corp.contoso.local → 192.168.2.10`. Azure VMs cannot resolve `fileserver.eu.corp.contoso.local`. Network connectivity to site 2 is confirmed. Two possible DNS/ruleset-specific causes?

**A5.**
1. **Newly added rule is in Disabled state** — rules default to disabled when added. The rule exists and looks correct but is not being evaluated. Fix: explicitly enable the rule.
2. **Typo in the domain name** — `eu.corp.contoso.local` vs `eu.corp.contoso.local.` (trailing dot) or any subtle typo. The query doesn't match the rule, falls through to public DNS, returns NXDOMAIN. Silent failure with no obvious error message.

---

## Key Gotchas

1. **One registration link per private zone** — hard platform limit. Spokes cannot auto-register. Use automation instead.
2. **Registration implies resolution** — a registration link gives you both. Resolution-only link gives you resolution only.
3. **Zone links are per-VNet** — a zone linked to hub only is invisible to spokes. Link to every VNet that needs to resolve it.
4. **Outbound endpoint has no IP** — it's an internal egress mechanism only. On-prem firewalls should allow the outbound endpoint's entire subnet CIDR for UDP/53 inbound.
5. **Private Resolver is zone-redundant by default** — no need to deploy two inbound endpoints for HA within a region.
6. **Ruleset association is mandatory** — ruleset can exist with correct rules but if not associated to the hub VNet, `168.63.129.16` never consults it. Silent failure.
7. **Newly added ruleset rules default to Disabled** — always explicitly enable after creating.
8. **DNS resolution loop** — never point a ruleset rule at your own inbound endpoint IP and link that ruleset to the same VNet. Classic misconfiguration.
9. **Auto-registration is IPv4 only** — no AAAA record auto-registration. PTR records are auto-created.
10. **Cloud-only = no Private Resolver needed** — `168.63.129.16` + zone links handles everything natively. Don't over-engineer.
11. **Ping ≠ DNS working** — ICMP and UDP/53 are different protocols. A working ping to the inbound endpoint does not confirm DNS will work. Always test with nslookup/dig.