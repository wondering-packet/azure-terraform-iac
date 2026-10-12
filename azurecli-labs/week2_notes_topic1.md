# Topic 1 — VNet Peering & Hub-Spoke Topology

---

## AWS Anchor

| AWS | Azure Equivalent |
|---|---|
| VPC Peering | VNet Peering |
| Transit Gateway | Azure Virtual WAN (managed) or DIY hub-spoke with NVA/Firewall |

---

## Theory

### VNet Peering Fundamentals
- **Bilateral, non-transitive** — same as AWS VPC Peering
- If A↔B and B↔C, A cannot reach C through B without additional machinery
- **Not a router** — VNet is an L3 address space but the Azure SDN fabric explicitly refuses to forward traffic between two peering links on the same VNet. This is an explicit platform policy, not a routing table limitation.
- Each peering link is its own bilateral agreement — no hierarchy, no parent VNet concept

### Local vs Global Peering
| Type | Scope | Cost |
|---|---|---|
| Local peering | Both VNets in same region | No data transfer cost |
| Global peering | VNets in different regions | Data transfer cost applies |

Both use Microsoft's private backbone — traffic never traverses the public internet.

### Why Non-Transitivity Matters
Even if VNet B has peering links to both A and C, the Azure SDN fabric will not forward a packet that *enters* via one peering link *out* through another.

**Fix:** Deploy an NVA or Azure Firewall *inside* VNet B with a real IP. Traffic flows:
```
A → peering → NVA/Firewall in B → peering → C
```
The appliance provides transitivity because it's a VM making real forwarding decisions — the platform restriction only applies to peering links themselves.

### Address Space Rules
- Overlapping CIDRs are **rejected at peering creation time** — Azure enforces this immediately
- Adding a **non-overlapping** address space to a peered VNet → peering stays up but requires a manual **resync** for the remote side to learn the new prefix
- Adding an **overlapping** address space to a peered VNet → peering enters **Disconnected** state — requires **delete and recreate** on both sides

### Peering States
| State | Cause | Fix |
|---|---|---|
| Connected | Normal | — |
| Disconnected | Overlapping address space added after peering creation | Delete and recreate both peering objects |
| Initiated | Only one side of the peering created | Create the other side |

---

### Hub-Spoke Topology

#### What Lives Where

**Hub VNet** — shared, centrally accessed infrastructure:
- Azure Firewall or NVA (provides transitivity + central inspection)
- VPN Gateway / ExpressRoute Gateway
- DNS infrastructure (Private Resolver or custom DNS VMs)
- Azure Bastion

**Spoke VNets** — workload isolation:
- Application VMs, AKS clusters, PaaS resources
- Each spoke peers **only to the hub** — never directly to other spokes

#### Inter-Spoke Traffic Flow
```
Spoke A VM → peering → Hub NVA/Firewall → peering → Spoke B VM
```
The NVA/Firewall is not optional — without it, inter-spoke traffic is blocked by the platform's non-transitivity rule. UDRs in each spoke force traffic toward the hub appliance.

#### Full Mesh vs Hub-Spoke

For n spokes, full mesh requires **n(n-1)/2** peering links:
- 10 spokes = 45 links
- 50 spokes = 1,225 links

Each new spoke in full mesh requires n new peering links. In hub-spoke, each new spoke requires **exactly 1** peering link to the hub.

Full mesh problems at scale:
- Compounding operational overhead per new spoke
- Address space conflict auditing across every pair
- No central inspection point — security policy sprawl
- No single choke point for routing control

---

### Azure Virtual WAN (vWAN)

The managed alternative to DIY hub-spoke. Microsoft manages the hub VNet, routing infrastructure, and peering.

| | DIY Hub-Spoke | Azure Virtual WAN |
|---|---|---|
| Routing control | Full — you own UDRs, NVAs, everything | Opinionated — Microsoft manages the hub |
| NVA flexibility | Any appliance, full config control | Limited — custom NVA integration constrained |
| Scale | Manual effort per spoke | Designed for scale — dozens of spokes, multi-region |
| DPI / custom inspection | Full flexibility | Constrained — third-party NVA DPI not fully supported |
| SD-WAN integration | Manual | Native |

**Decision rule:** If you need deep packet inspection, custom NVA, or fine-grained routing control → DIY hub-spoke. If you need scale across many spokes and regions with standard connectivity → vWAN.

---

## Exercises

### Exercise 1 — Hub-Spoke Design

**Objective:** Draw a hub-spoke topology with 3 spokes. Label what resources live in the hub vs spokes. Identify every peering link needed and its direction.

**Solution:**

```
                        ┌─────────────────────┐
                        │       Hub VNet       │
                        │  - Azure Firewall    │
                        │  - VPN/ER Gateway    │
                        │  - DNS / Bastion     │
                        └──────────┬──────────┘
               ┌──────────────────┼──────────────────┐
               ↕                  ↕                  ↕
        ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
        │   Spoke 1   │   │   Spoke 2   │   │   Spoke 3   │
        │  Workloads  │   │  Workloads  │   │  Workloads  │
        └─────────────┘   └─────────────┘   └─────────────┘
```

**Peering links required:** 3 total — one per spoke, each bidirectional (Hub↔Spoke1, Hub↔Spoke2, Hub↔Spoke3). Spokes never peer directly to each other.

**Hub resources:** Azure Firewall or NVA, VPN/ExpressRoute Gateway, DNS infrastructure, Azure Bastion, shared services VMs.

**Spoke resources:** Workload VMs, AKS clusters, PaaS integrations, subnet-level NSGs. Nothing shared — all spoke-to-spoke traffic routes via the hub.

---

### Exercise 2 — Inter-Spoke Traffic Path

**Objective:** Trace the full traffic path for Spoke 1 VM communicating with Spoke 2 VM through the hub. What needs to exist at the hub?

**Solution:**

**Traffic path:**
```
Spoke 1 VM → UDR (0.0.0.0/0 → Firewall) → peering to Hub → Azure Firewall → peering to Spoke 2 → Spoke 2 VM
```

**What must exist at the hub:**
1. **Azure Firewall or NVA** with a private IP in the hub — this is the actual routing device that provides transitivity
2. **UDRs on both spoke WorkloadSubnets** — `0.0.0.0/0 → VirtualAppliance → Firewall IP` to force all traffic through the hub
3. **Firewall rules** — allow rules permitting Spoke 1 → Spoke 2 traffic (and return)
4. **Both peering links** — Hub↔Spoke1 and Hub↔Spoke2, both in Connected state

Without the Firewall/NVA, Azure's SDN fabric refuses to transit traffic between the two peering links — the platform policy blocks it regardless of routing.

---

### Exercise 3 — Full Mesh Argument

**Objective:** A colleague proposes peering all spokes directly to each other instead of using a hub. Counter the argument architecturally at scale.

**Solution:**

**The scaling math alone:**
- 10 spokes today = 45 peering links
- 50 spokes tomorrow = 1,225 peering links
- Each new spoke added requires n additional peering links where n = current spoke count — it compounds

**But the number isn't even the real problem:**

1. **Operational overhead compounds** — every new spoke requires touching every existing spoke. In hub-spoke, adding spoke #51 is one operation.
2. **Address space management** — every pair needs non-overlapping CIDRs audited against each other. At 50 spokes that's 1,225 pairs to validate.
3. **No central inspection point** — without a hub Firewall, you have no single place to enforce security policy. You'd need NSG rules on every spoke for every other spoke — a maintenance nightmare.
4. **No shared services** — DNS, Bastion, VPN Gateway would need to exist in every spoke or be accessible via a complex web of peering links.
5. **Azure peering limits** — Azure enforces a maximum number of peering links per VNet (default 500). Full mesh breaks this limit well before you hit enterprise scale.

Hub-spoke trades direct spoke-to-spoke paths for operational simplicity, central inspection, and a single shared services plane. The architecture scales linearly — hub-spoke adds one link per new spoke, full mesh adds n.

---

## Q&A Bank

**Q1.** VPC Peering in AWS is non-transitive. Is Azure VNet peering also non-transitive? What's the workaround?

**A1.** Yes — non-transitive. Workaround is deploying an NVA or Azure Firewall inside the hub VNet. The appliance receives traffic from one peering link and forwards it out another — the platform restriction applies to peering links themselves, not to VMs/appliances.

---

**Q2.** Two peered VNets — can they have overlapping address spaces?

**A2.** No. Azure rejects the peering at creation time if address spaces overlap. If overlap is introduced after peering exists, the peering enters Disconnected state and must be deleted and recreated on both sides.

---

**Q3.** What's the Azure equivalent of AWS Transit Gateway?

**A3.** Azure Virtual WAN (managed, less flexible) or DIY hub-spoke with NVA/Azure Firewall (manual, fully flexible). No single native equivalent — the right answer depends on requirements.

---

**Q4.** In a hub-spoke, why does all inter-spoke traffic route through the hub rather than directly?

**A4.** Two reasons: (1) Azure's SDN fabric refuses to transit traffic between two peering links on the same VNet — platform policy. (2) By design — the hub NVA/Firewall provides central inspection, logging, and policy enforcement for all inter-spoke flows.

---

**Q5.** What happens to peering if you add a new address space to a VNet?

**A5.** Depends on whether the new space overlaps. Non-overlapping → peering stays up, manual resync needed. Overlapping → peering goes Disconnected, delete and recreate required.

---

## Key Gotchas

1. VNet peering is **not transitive** — the fix requires an actual routing device inside the hub, not just routes
2. Adding an overlapping CIDR to a peered VNet = **full peering outage** — delete/recreate both sides required
3. Adding a non-overlapping CIDR = **manual resync** required — remote side won't auto-learn it
4. Full mesh doesn't scale — hub-spoke is the standard enterprise pattern for a reason
5. vWAN looks attractive at scale but sacrifices flexibility — DPI requirements typically force DIY hub-spoke
6. NVA in hub requires **IP forwarding enabled** on its NIC — Azure blocks forwarding by default on VM NICs. Azure Firewall handles this automatically.
7. **Azure peering limit is 500 per VNet** — full mesh hits this ceiling well before enterprise scale