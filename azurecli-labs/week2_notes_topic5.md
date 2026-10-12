# Topic 5 — VPN Gateway & Hybrid Connectivity

---

## AWS Anchor

| AWS | Azure Equivalent |
|---|---|
| Virtual Private Gateway (VGW) | VPN Gateway |
| Customer Gateway | Local Network Gateway |
| Site-to-Site VPN Connection | Connection object |
| Direct Connect | ExpressRoute |
| Transit Gateway | Virtual WAN or hub-spoke with VPN Gateway |
| Direct Connect Gateway | ExpressRoute Global Reach |

---

## Theory

### Site-to-Site VPN — Required Components

Unlike AWS where VGW is somewhat abstracted, Azure VPN Gateway is a proper resource deployed into a dedicated subnet. Four components required:

**1. GatewaySubnet**
- Dedicated subnet named exactly `GatewaySubnet` — Azure looks for this string
- Minimum /27 — leaves room for both VPN + ER gateways plus Azure reserved IPs
- No NSG, no UDR pointing to NVA (see constraints section)

**2. VPN Gateway**
- Azure-side endpoint, deployed into GatewaySubnet
- Gets one (Active-Passive) or two (Active-Active) public IPs
- Provisioning takes 25-45 minutes — slowest resource in Azure networking

**3. Local Network Gateway**
- Represents the on-prem side
- Contains on-prem public IP and on-prem address space
- AWS equivalent: Customer Gateway

**4. Connection object**
- Joins VPN Gateway and Local Network Gateway
- Where you set: shared key (PSK), connection type (IPsec), BGP settings

---

### VPN Gateway SKUs

**As of November 1, 2025, only AZ SKUs can be created for new deployments.** Non-AZ SKUs (VpnGw1-5) are deprecated and being migrated to their AZ equivalents by September 2026.

| SKU | Max Throughput | Max S2S Tunnels | BGP | Zone Redundant |
|---|---|---|---|---|
| VpnGw1AZ | 650 Mbps | 30 | ✅ | ✅ |
| VpnGw2AZ | 1 Gbps | 30 | ✅ | ✅ |
| VpnGw3AZ | 1.25 Gbps | 30 | ✅ | ✅ |
| VpnGw4AZ | 5 Gbps | 100 | ✅ | ✅ |
| VpnGw5AZ | 10 Gbps | 100 | ✅ | ✅ |

**AZ SKU vs Active-Active — two independent concepts:**

| Config | What it protects against |
|---|---|
| AZ SKU only | Zone failure — datacenter goes down |
| Active-Active only | Gateway instance failure |
| AZ SKU + Active-Active | Both — maximum resilience, production recommendation |

AZ SKU = infrastructure redundancy (gateway instances spread across availability zones).
Active-Active = connection redundancy (both instances maintain simultaneous tunnels to on-prem).
They complement each other — use both for production.

**Basic SKU is deprecated** — never use for new deployments.

---

### Active-Passive vs Active-Active

**Active-Passive (default):**
```
On-prem ← tunnel → VPN Gateway (active instance)
                    VPN Gateway (standby instance) ← takes over on failure
```
- One public IP, one tunnel
- Failover = DPD timeout + IKE re-establishment + BGP reconvergence (~90 seconds typical)
- Simpler, lower cost

**Active-Active:**
```
On-prem ← tunnel 1 → VPN Gateway instance 1 (public IP 1)
On-prem ← tunnel 2 → VPN Gateway instance 2 (public IP 2)
```
- Two public IPs, two simultaneous tunnels from on-prem
- Both tunnels always active — BGP detects failure and reconverges in seconds
- Requires BGP — BGP keepalives detect failure without waiting for IKE DPD
- Higher cost, production recommendation for critical connectivity

**Key difference from AWS:** AWS VGW always presents two tunnel endpoints per connection by default. Azure Active-Active requires explicit configuration and a second public IP.

**Failover time breakdown (Active-Passive):**
- IKE Dead Peer Detection (DPD) timeout: 30-90 seconds (on-prem vendor dependent)
- IKE re-negotiation + IPsec SA establishment: ~5 seconds
- BGP reconvergence: depends on keepalive/dead timers

To reduce failover time: switch to Active-Active (removes IKE re-establishment entirely) + tune BGP timers (keepalive 10s, dead timer 30s).

---

### BGP on VPN Gateway

**Why BGP over static routing in multi-site scenarios:**
- New spoke VNet added → routes propagate to on-prem automatically
- On-prem adds new subnet → VPN Gateway learns it and propagates to Azure
- Faster failover detection via BGP keepalives vs static route timeout
- No manual route maintenance across all sites

**Azure BGP configuration:**
- VPN Gateway gets an ASN (default 65515, configurable)
- BGP peer IP auto-assigned from GatewaySubnet
- On-prem router peers with Gateway's BGP peer IP over the IPsec tunnel
- Default BGP keepalive: 60 seconds, dead timer: 180 seconds (tunable)

---

### GatewaySubnet Hard Constraints

| Constraint | Reason |
|---|---|
| Name must be exactly `GatewaySubnet` | Azure identifies gateway subnet by this string |
| Minimum /27 | Room for VPN + ER gateways + Azure reserved IPs. /28 breaks coexistence scenarios |
| No NSG | IKE (UDP 500/4500), ESP (protocol 50), BGP (TCP 179), and Azure health probes (`168.63.129.16`) must flow unrestricted. Any of these blocked = silent failure |
| No UDR pointing to NVA | Routes gateway control plane traffic through NVA — breaks connectivity |

**Why no NSG specifically:**
- IKE/IPsec peers can be any IP across hundreds of on-prem sites — allowlist is unmanageable
- BGP TCP 179 blocked = session never establishes, tunnel up but no routes exchanged
- `168.63.129.16` health probes blocked = Azure can't monitor gateway instances

---

### ExpressRoute

Private dedicated connectivity from on-prem to Azure — no internet involved. Traffic traverses a connectivity provider's MPLS/WDM network.

#### Components

**Circuit** — physical/logical connectivity purchased from a provider (Equinix, AT&T, etc.). Has a bandwidth tier (50Mbps to 100Gbps).

**ExpressRoute Gateway** — deployed in GatewaySubnet, connects VNet to the ER circuit. Different resource from VPN Gateway but same subnet.

**Two peering types:**

| Peering | Traffic | AWS Equivalent |
|---|---|---|
| Private peering | Azure VNet resources (VMs, PEs, internal services) | Direct Connect Private VIF |
| Microsoft peering | Microsoft 365, Azure public services (Storage, SQL public endpoints) | Direct Connect Public VIF |

#### ExpressRoute vs VPN Gateway

| | VPN Gateway | ExpressRoute |
|---|---|---|
| Path | Internet (encrypted IPsec) | Private provider network |
| Latency | Variable | Consistent, low |
| Bandwidth | Up to 10Gbps (VpnGw5) | Up to 100Gbps |
| SLA | 99.9% | 99.95% |
| Cost | Lower | Higher |
| Setup time | Hours | Weeks (provider provisioning) |

---

### ExpressRoute + VPN Coexistence

Both gateways can coexist in the same VNet simultaneously — ER as primary, VPN as failover.

**How routing preference works:**
- ER-learned routes automatically have higher weight than VPN-learned routes in Azure — no manual tuning needed for basic failover
- To make VPN routes less attractive: AS path prepending on the VPN side
- When ER circuit goes down → BGP session over ER drops → ER Gateway withdraws routes → VPN Gateway's path becomes the only path → traffic fails over automatically

**Failover mechanics:**
1. ER circuit goes down
2. BGP keepalives over ER fail → BGP session drops
3. ER Gateway withdraws all routes learned via that session
4. Azure route table loses ER path for on-prem prefixes
5. VPN Gateway's path still active → becomes sole path → traffic reconverges

**Important nuance:** Physical circuit failure = both directions fail simultaneously = symmetric failover. Soft BGP failure on Azure side only = Azure stops sending via ER but on-prem still has ER path = asymmetric routing risk. On-prem must also detect and withdraw routes for symmetric failover.

**GatewaySubnet /27 requirement:** Both gateways live in the same subnet — /28 leaves insufficient IPs for both gateway instances plus Azure reserved addresses.

---

### Hub-Spoke VPN Architecture

Centralizing VPN Gateway in the hub is the standard enterprise pattern:

```
On-prem site 1 ─┐
On-prem site 2 ─┼─ VPN Gateway (hub) ─ Hub VNet ─ peering ─ Spoke 1-N
On-prem site 3 ─┘
```

**Tunnel count:**
- Minimum: 1 tunnel per on-prem site = 3 tunnels for 3 sites
- Active-Active HA: 2 tunnels per site = 6 tunnels for 3 sites
- Spoke VNets connect via peering — zero additional tunnels regardless of spoke count

**Traffic path spoke → on-prem:**
```
Spoke VM → VNet peering → Hub → VPN Gateway → IPsec tunnel → on-prem
```

**Anti-pattern:** VPN Gateway per spoke = n_spokes × n_sites tunnels + gateway cost per spoke. For 10 spokes + 3 sites = 30 tunnels, 10 gateways. Never do this.

---

## Exercises

### Exercise 1 — S2S VPN Architecture Design ✅

**Objective:** Draw a complete Site-to-Site VPN between Azure and a fictional on-prem site. Label every component on both sides.

**Solution:**

```
Azure side:
  Hub VNet
    └── GatewaySubnet (172.22.0.0/27)
          └── VPN Gateway (vgw-hub)
                └── Public IP: 20.x.x.x
                └── BGP ASN: 65515
                └── BGP peer IP: 172.22.0.x (from GatewaySubnet)

  Local Network Gateway (lng-onprem)
    └── On-prem public IP: 203.0.113.1
    └── On-prem address space: 10.100.0.0/16

  Connection object (conn-hub-to-onprem)
    └── VPN Gateway ↔ Local Network Gateway
    └── Shared key (PSK)
    └── BGP enabled

On-prem side:
  VPN device (router/firewall)
    └── Public IP: 203.0.113.1
    └── BGP ASN: 65000
    └── BGP peer: 172.22.0.x (Azure Gateway BGP IP) over tunnel
```

---

### Exercise 2 — GatewaySubnet /27 vs /28 ✅

**Scenario:** Colleague says /28 will work fine. Make the argument for /27.

**Solution:**

A /28 gives 16 IPs — minus 5 Azure reserved = 11 usable. Sounds like enough for "just a gateway."

The problem is coexistence. If you later add an ExpressRoute Gateway alongside the VPN Gateway:
- VPN Gateway consumes IPs for its instances (Active-Active = 2 instances + management)
- ER Gateway consumes its own IPs
- Azure reserves additional IPs for internal management

With /28 you risk running out of IPs mid-deployment — and you cannot resize GatewaySubnet without deleting the gateways first, which means a full outage. Microsoft explicitly documents /27 as minimum for coexistence scenarios.

The /27 recommendation isn't conservative padding — it's the documented minimum for a production-ready GatewaySubnet that supports both gateway types.

---

### Exercise 3 — ExpressRoute Failover to VPN ✅

**Scenario:** ER circuit going down for maintenance. VPN as automatic failover. What needs to be true?

**Solution:**

1. **Both gateways deployed in same GatewaySubnet** — ER Gateway + VPN Gateway coexisting
2. **Same prefixes advertised on both paths** — on-prem advertises `10.100.0.0/16` via both ER BGP session and VPN BGP session to Azure
3. **ER routes preferred by default** — Azure automatically weights ER routes higher than VPN routes for same prefix. No manual config needed for basic failover.
4. **BGP timers tuned** — lower keepalive/dead timers on VPN path for faster reconvergence when ER goes down
5. **On-prem router also advertises Azure prefixes via both paths** — ensures return traffic also fails over symmetrically

When ER goes down: BGP session drops → ER Gateway withdraws routes → VPN path becomes sole route → traffic reconverges automatically. Return path also reconverges if on-prem is advertising Azure prefixes via VPN BGP.

---

## Q&A Bank

**Q1.** Why can't you put an NSG on GatewaySubnet?

**A1.** Three specific traffic types would break: (1) IKE/IPsec — UDP 500, UDP 4500, ESP protocol 50 must flow from any on-prem peer IP, maintaining an allowlist across hundreds of sites is unmanageable; (2) BGP TCP 179 — blocked BGP means tunnel comes up but no routes exchanged, silent failure; (3) Azure health probes from `168.63.129.16` — blocked probes break Azure's internal gateway monitoring. Any one of these being blocked causes non-obvious failures.

---

**Q2.** Active-Active VPN Gateway — how does failover work vs Active-Passive?

**A2.** Active-Passive: standby instance takes over on failure, requires IKE DPD to detect dead peer (30-90s) + IKE re-establishment + BGP reconvergence = ~90 second failover typical. Active-Active: both tunnels always up and active, BGP runs on both simultaneously. On failure, BGP detects the dead path via keepalive failure (seconds) and reconverges to the surviving tunnel. No IKE re-establishment needed. Failover time drops from ~90 seconds to seconds.

---

**Q3.** You have both ExpressRoute and VPN in the same VNet. Which path does traffic prefer and can you influence this?

**A3.** ER is preferred by default — Azure automatically assigns higher weight to ER-learned routes over VPN-learned routes for the same prefix. To influence: AS path prepending on the VPN side makes VPN routes less attractive (useful if you want to force all traffic via ER). You cannot set BGP local preference directly on Azure VPN Gateway — on-prem side manipulation is the lever.

---

**Q4.** What's the AWS Direct Connect equivalent in Azure and where do they architecturally differ?

**A4.** ExpressRoute is the equivalent. Key architectural differences: (1) ExpressRoute uses a connectivity provider model — you don't connect directly to Microsoft, you go through a partner (Equinix, AT&T etc.); Direct Connect has both partner and dedicated connection models. (2) ExpressRoute has two peering types (private + Microsoft) — Direct Connect has Private VIF, Public VIF, and Transit VIF. (3) ExpressRoute Global Reach connects on-prem sites to each other via Microsoft backbone — similar to Direct Connect Gateway but different implementation.

---

**Q5.** BGP on VPN Gateway — what specific problem does it solve vs static routing in multi-site?

**A5.** Three specific problems: (1) Route maintenance — static routing requires manual entries on every device for every site's prefixes. Add a new VNet or on-prem subnet → update routes everywhere. BGP propagates changes automatically. (2) Failover detection — static routes have no built-in failure detection. BGP keepalives detect link failure in seconds and withdraw routes. (3) Scale — 10 sites × 10 VNets = 100 static route entries to maintain. BGP handles this dynamically regardless of scale.

---

**Q6.** What are the two ExpressRoute peering types and what traffic does each carry?

**A6.** Private peering — carries traffic to/from Azure VNet resources: VMs, Private Endpoints, internal services. Equivalent to Direct Connect Private VIF. Microsoft peering — carries traffic to Microsoft 365 services and Azure public endpoints (Storage public endpoint, SQL public endpoint, etc.). Equivalent to Direct Connect Public VIF. Private peering is what most enterprises use for hybrid connectivity to their Azure workloads.

---

## Key Gotchas

1. **VPN Gateway takes 25-45 minutes to provision** — plan lab time accordingly. Don't deploy it and expect immediate results.
2. **Non-AZ SKUs deprecated as of Nov 2025** — always use AZ SKUs (VpnGw1AZ or higher) for new deployments. VpnGw1-5 without AZ can no longer be created.
3. **AZ SKU ≠ Active-Active** — they are independent features. AZ SKU = zone redundancy. Active-Active = connection redundancy. Use both for production.
4. **Active-Passive failover is ~90 seconds** — dominated by IKE DPD timeout, not BGP. Switch to Active-Active for production
5. **GatewaySubnet /27 is the minimum** — /28 breaks ER + VPN coexistence. Can't resize without deleting gateways = outage
6. **No NSG on GatewaySubnet** — IKE, BGP, and Azure health probes all break silently
7. **No UDR pointing to NVA on GatewaySubnet** — routes control plane traffic through NVA, breaks connectivity
8. **ER preferred over VPN by default** — no manual config needed for basic failover preference
9. **Soft BGP failure ≠ physical failure** — physical circuit down = symmetric failover. BGP-only failure on Azure side = asymmetric routing risk if on-prem doesn't also detect and withdraw routes
10. **Active-Active requires BGP** — cannot run Active-Active without BGP enabled
11. **Local Network Gateway represents on-prem** — if on-prem public IP changes, update the LNG. Forgetting this is a common cause of tunnel failures after ISP changes.