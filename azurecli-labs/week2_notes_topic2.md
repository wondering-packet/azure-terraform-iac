# Topic 2 — User Defined Routes & Forced Tunneling

---

## AWS Anchor

| AWS | Azure Equivalent |
|---|---|
| Subnet route table | Route Table object (per-subnet association) |
| Blackhole route | Next hop type `None` |
| Static route to ENI | Next hop type `VirtualAppliance` |
| VGW route propagation | BGP route propagation (per route table setting) |

Key difference: In AWS, the route table is one object. In Azure, there are **two layers** — system routes (automatic) and UDRs (custom) — that merge at runtime into an effective routing table per NIC.

---

## Theory

### Route Layers & Priority

Azure builds the effective routing table for each NIC by merging three sources in priority order:

| Priority | Source | Description |
|---|---|---|
| 1 (highest) | UDRs | Custom routes you create in a Route Table object |
| 2 | BGP-learned routes | Routes propagated from VPN/ExpressRoute Gateway |
| 3 (lowest) | System routes | Automatically created by Azure |

**Tiebreaker within same priority: longest prefix match wins.**

At equal prefix length, UDR beats BGP-learned beats system route. But a more specific system route always beats a less specific UDR — longest prefix match is the final arbiter.

**No ECMP** — Azure route tables support one next hop per prefix. For NVA scale-out, put an Azure Load Balancer in front of multiple NVAs and point the UDR at the LB frontend IP.

---

### System Routes

Automatically created by Azure — you cannot delete them, only override with more specific UDRs.

| Prefix | Next Hop | Reason |
|---|---|---|
| VNet address space | Virtual network | Local VNet traffic stays local |
| Peered VNet prefixes | VNet peering | Auto-injected when peering is created |
| 0.0.0.0/0 | Internet | Default internet egress |
| 127.0.0.0/8 | None | Loopback — blackholed |
| 100.64.0.0/10 | None | CGNAT — used by Azure fabric internally |
| 169.254.0.0/16 | None | APIPA — blackholed |
| 25.x.x.x ranges | None | Microsoft internal infrastructure ranges |

Azure blackholes reserved/internal ranges to prevent VM traffic from accidentally hitting Azure's internal fabric via the default internet route.

---

### Next Hop Types

| Type | AWS Equivalent | Behaviour |
|---|---|---|
| `VirtualAppliance` | ENI of EC2 | Forward to specific private IP (NVA/Firewall) |
| `Internet` | IGW | Send to public internet via Azure edge |
| `VnetLocal` | Local (implicit) | Keep within VNet |
| `VirtualNetworkGateway` | VGW | Send toward VPN/ExpressRoute Gateway |
| `None` | Blackhole | **Silent drop** — no ICMP unreachable, no RST |

#### Why Some Next Hops Have No IP
`VNet peering`, `Virtual network`, and `InterfaceEndpoint` have no next hop IP because they are **fabric-level directives** — Azure's SDN delivers the packet directly at the hypervisor layer without traversing a router. No intermediate IP needed, no ARP, no hop.

`VirtualAppliance` requires an explicit IP because you're intentionally breaking out of the fabric to a specific VM that will make its own forwarding decision.

---

### BGP Route Propagation

A setting on each **Route Table object** (not on the gateway).

| Setting | Effect |
|---|---|
| **Enabled** (default) | Routes learned by VPN/ExpressRoute Gateway are automatically injected into associated subnets |
| **Disabled** | Gateway-learned routes are suppressed — only system routes and UDRs apply |

When to disable: spoke WorkloadSubnets where you want explicit UDR control and don't want BGP-learned on-prem routes appearing automatically.

When to leave enabled: GatewaySubnet (needs full route awareness), SharedServicesSubnet (DNS/Bastion need on-prem reachability).

---

### Forced Tunneling

Overriding the default `0.0.0.0/0 → Internet` system route to redirect traffic elsewhere.

**Common scenarios:**
- Force internet through Azure Firewall: `0.0.0.0/0 → VirtualAppliance → Firewall IP` on spoke subnets
- Force all traffic on-prem (hairpin): `0.0.0.0/0 → VirtualNetworkGateway` — internet traffic hairpins through on-prem edge

---

### Effective Routes

The primary troubleshooting tool for any Azure routing problem. Located on the NIC object in the portal — shows the fully merged routing table for that specific NIC after all sources are combined.

#### What It Shows
| Column | What to look for |
|---|---|
| Source | `User` = UDR, `Default` = system route, `VirtualNetworkGateway` = BGP-learned |
| State | `Active` = working, `Invalid` = conflict or misconfiguration |
| Next Hop Type | What's actually handling the traffic |
| Next Hop IP | For VirtualAppliance — verify the IP is correct and not a typo |

#### Special Route Types You'll See in Production
- `InterfaceEndpoint` /32 host routes = Private Endpoints deployed in the VNet (auto-injected by Azure)
- Large blob of prefixes → `VirtualNetworkServiceEndpoint` = Service Endpoint injecting entire Azure service IP ranges into the route table automatically
- Missing UDR entirely = route table not associated to that subnet

---

## Exercises

### Exercise 1 — UDR Design for Hub-Spoke with Azure Firewall ✅

**Topology:**
- Hub VNet `10.232.0.0/21` with GatewaySubnet, AzureFirewallSubnet (Firewall IP `10.232.1.4`), SharedServicesSubnet
- Spoke 1 `10.232.16.0/20` with WorkloadSubnet
- Spoke 2 `10.232.32.0/20` with WorkloadSubnet

**Requirements:** All internet and inter-spoke traffic through Firewall. On-prem BGP routes not auto-propagated to spokes. Local VNet traffic stays local.

**Solution:**

| Route Table | Prefix | Next Hop Type | Next Hop IP | BGP Propagation |
|---|---|---|---|---|
| GatewaySubnet | 10.232.16.0/20 | VirtualAppliance | 10.232.1.4 | On |
| GatewaySubnet | 10.232.32.0/20 | VirtualAppliance | 10.232.1.4 | On |
| Spoke1-WorkloadSubnet | 0.0.0.0/0 | VirtualAppliance | 10.232.1.4 | **Off** |
| Spoke2-WorkloadSubnet | 0.0.0.0/0 | VirtualAppliance | 10.232.1.4 | **Off** |
| SharedServicesSubnet | — | — | — | On |

**Note:** `AzureFirewallSubnet` gets no route table — Azure prohibits it. The Firewall needs a direct internet path.

**Key reasoning:**
- Local VNet traffic unaffected — VNet address space system route is more specific than /0, wins via LPM
- GatewaySubnet UDRs needed so on-prem traffic arriving at the Gateway gets steered through the Firewall before reaching spokes
- SharedServicesSubnet BGP propagation left on — DNS/Bastion need on-prem reachability

---

### Exercise 2 — Troubleshooting UDR Misconfiguration ✅

*(Completed via live production effective routes table analysis)*

**Troubleshooting flow:**
1. Determine scope — is it one VM or multiple? Widespread = routing layer. Isolated = VM level.
2. Pull Effective Routes on the affected VM's NIC
3. Check: is your UDR present? If not → route table not associated to the subnet
4. Check: is the next hop IP correct? Typo in VirtualAppliance IP is a common failure
5. Check: is a more specific system or BGP-learned route overriding your UDR?
6. Check: is any route showing `Invalid` state?
7. Correlate with recent changes — UDR misconfigs are almost always change-related

**Note:** Traceroute is unreliable in Azure — ICMP TTL expiry is often suppressed through Firewall/NVA. Use Effective Routes as primary diagnostic, not traceroute.

---

### Exercise 3 — Blackhole Route ✅

**Requirement:** Silently drop all traffic to `192.168.100.0/24` from WorkloadSubnet. No ICMP unreachable, no RST.

**Solution:** Single UDR on WorkloadSubnet — `192.168.100.0/24 → None`

`None` next hop = Azure SDN drops the packet at the fabric level. No forwarding attempt, no error response. Using a non-existent IP instead would be broken routing, not a controlled blackhole.

---

## Q&A Bank

**Q1.** AWS and Azure both have per-subnet route tables. What's the key operational difference in how they're associated?

**A1.** Functionally similar — one route table associated to a subnet. The key Azure difference is the two-layer model: system routes always exist underneath your UDRs, and the effective routing table is a merge of both. In AWS, what you put in the route table is what you get. In Azure, system routes are always present and can interact with your UDRs via LPM.

---

**Q2.** You want all internet-bound spoke traffic through Azure Firewall in the hub. What UDR, what prefix, what next hop, applied where?

**A2.** `0.0.0.0/0 → VirtualAppliance → Firewall private IP`, applied to spoke WorkloadSubnets. Local VNet traffic is unaffected because the VNet address space system route is more specific and wins via LPM.

---

**Q3.** What is BGP route propagation on a route table and when would you disable it?

**A3.** A per-route-table setting that controls whether routes learned by the VPN/ExpressRoute Gateway are automatically injected into associated subnets. Disable it on spoke WorkloadSubnets when you want explicit UDR control and don't want on-prem BGP routes appearing automatically and potentially conflicting with your UDRs.

---

**Q4.** Next hop type `None` — what does this do to traffic hitting that route?

**A4.** Silent drop at the Azure SDN fabric level. No ICMP unreachable, no RST, no forwarding attempt. Use it for intentional blackholes — never use a non-existent IP as a substitute, that's broken routing not a controlled drop.

---

**Q5.** A UDR and a BGP-learned route exist for the same prefix. Which wins?

**A5.** UDR wins — it has higher priority in Azure's fixed hierarchy (UDR > BGP-learned > system routes). If prefix lengths differ, longest prefix match overrides priority order.

---

## Key Gotchas

1. **No ECMP** — one next hop per prefix. Use Azure Load Balancer in front of NVA pool for scale-out
2. **BGP propagation is a route table setting, not a gateway setting** — common mistake to look in the wrong place
3. **`None` next hop = silent drop** — use it for intentional blackholes, never a non-existent IP
4. **`AzureFirewallSubnet` cannot have a UDR** — Azure enforces this, the Firewall needs direct internet
5. **Traceroute is unreliable in Azure** — ICMP TTL expiry often suppressed through Firewall/NVA. Use Effective Routes instead
6. **uRPF is not an exposed knob in Azure** — don't try to tune it
7. **Always cover all three RFC1918 ranges** in your UDR set — 10/8, 172.16/12, and 192.168/16. Missing 192.168/16 is a common gap
8. **GatewaySubnet needs UDRs too** — on-prem traffic arrives at the Gateway and needs to be steered through the Firewall before reaching spokes. Easy to forget.
9. **`InterfaceEndpoint` /32 routes are auto-injected** — Private Endpoints create host routes automatically. These will always win over broader UDRs via LPM.
10. **GatewaySubnet** or **AzureFirewallSubnet** names - these names are reserved. the moment we name a subnet e.g. **GatewaySubnet**, Azure treats it specially.