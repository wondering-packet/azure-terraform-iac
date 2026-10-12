# Topic 4 — Private Endpoints & Private Link

---

## AWS Anchor

| AWS | Azure Equivalent |
|---|---|
| VPC Endpoint (Interface) | Private Endpoint |
| VPC Endpoint (Gateway) | Service Endpoint (partial — different mechanism) |
| AWS PrivateLink Service | Azure Private Link Service |
| Route 53 PHZ for PrivateLink | Azure Private DNS Zone (`privatelink.*`) |

---

## Theory

### Service Endpoints vs Private Endpoints

| | Service Endpoint | Private Endpoint |
|---|---|---|
| Destination IP | Public IP of PaaS (routed via Azure backbone) | Private IP inside your VNet |
| On-prem access | On-prem traffic can reach the service via ExpressRoute (Microsoft peering), but it is treated as public traffic and cannot use Service Endpoint VNet identity. Must whitelist NAT/public IP on PaaS firewall. | Via ExpressRoute/VPN natively — no firewall whitelist needed |
| DNS change needed | ❌ No — use public FQDN as-is | ✅ Yes — must override DNS |
| Scope | Entire service type (all storage, all KV instances) | Specific resource instance only |
| Cost | Free | Per endpoint/hour + data processing |
| Public endpoint disabled | ❌ Still exists | ✅ Can fully disable |
| Traffic inspection by NVA | ❌ Bypasses NVA/custom routing | ✅ Supports UDR + NVA inspection |
| NSG support | ✅ On source subnet | ✅ On PE subnet (requires `privateEndpointNetworkPolicies` enabled) |

**Key architectural difference:**

**Service Endpoint** does two things when enabled on a subnet:

1. Routing — traffic to that Azure service takes the backbone route instead of the internet. Azure injects routes for the service's entire public IP range into the subnet's effective routing table with next hop VirtualNetworkServiceEndpoint.
2. Subnet identity — establishes a trust claim so the PaaS service's firewall can identify traffic as coming from that specific subnet.

Both are prerequisites for Service Endpoint-based access control to work. Enabling the Service Endpoint on the subnet alone doesn't restrict access — you still need to add the subnet to the PaaS firewall allowlist AND set defaultAction: Deny. Without the Service Endpoint enabled, the subnet-based firewall rule won't work because Azure can't verify the traffic identity.
On-prem traffic can reach the service via ExpressRoute Microsoft peering, but is treated as public IP traffic — no VNet identity, no subnet-based firewall rules. Must whitelist NAT/public IP explicitly on the PaaS firewall instead.

**Private Endpoint** gives the PaaS service a private IP inside your VNet. From a routing perspective it looks like any other VM on your network. DNS override required — without it the service is never reached via the private IP. No subnet identity concept — access control is purely IP-based via NSG and Firewall network rules.

**Scope distinction with real example:**

Service Endpoint on `Microsoft.Storage` enabled on Subnet X — Azure adds routes for ALL Azure Storage public IPs to that subnet, this forces the traffic to route through Azure backbone, not the internet . Your storage account firewall allows Subnet X. But a VM in Subnet X could also reach any other storage account in the tenant unless you add Service Endpoint Policies.

Private Endpoint for `mystorageaccount` — gets IP `10.232.48.100`. That IP maps to that specific storage account only via Private Link. No other storage account is reachable through it.

**When to use Service Endpoint:**
- Azure-only workloads, no on-prem access needed
- Single VNet, single resource, no scope creep concern
- Cost-sensitive — free vs paid
- No need to fully disable public endpoint

**When to use Private Endpoint:**
- On-prem needs to access PaaS service over ExpressRoute/VPN natively
- Compliance requires fully private connectivity — public endpoint disabled entirely
- Multi-VNet or multi-region access needed
- Resource-level granularity required
- Traffic inspection by Azure Firewall required

---

### How Private Link Works

When you create a Private Endpoint for a PaaS service:
1. Azure creates a NIC in your chosen subnet with a private IP
2. That NIC is mapped to the specific resource via Private Link
3. Azure injects a `/32` host route for that IP — `InterfaceEndpoint` next hop type — into the VNet routing table automatically
4. Traffic to that IP stays entirely within Azure's private fabric

---

### The DNS Problem

**Without DNS configuration:**

`mystorageaccount.blob.core.windows.net` publicly resolves to a public IP — e.g. `52.180.x.x`. Private Endpoint gives it `10.232.48.100`. But DNS still returns `52.180.x.x`.

VM uses FQDN → DNS returns public IP → traffic goes to public internet → storage firewall blocks it (if locked down) or traffic bypasses Private Endpoint entirely.

**The silent failure:** If public access is open, everything appears to work but traffic goes the wrong way. No error saying "use the private endpoint." Compliance team thinks traffic is private. It isn't.

**The fix:** Override DNS so the FQDN resolves to the private IP inside your VNet.

---

### CNAME Chain — How DNS Override Works

**Important:** The CNAME to `privatelink.*` is NOT always present on public DNS. It is only inserted into public DNS at the moment you create a Private Endpoint for that specific resource. Before a Private Endpoint exists, the public FQDN resolves directly to a public IP A record — no CNAME indirection at all.

**Before Private Endpoint is created:**
```
mystorageaccount.blob.core.windows.net → A record → 52.180.x.x (public IP directly)
No privatelink.* CNAME exists
```

**After Private Endpoint is created:**

Azure inserts a CNAME into public DNS:
```
mystorageaccount.blob.core.windows.net → CNAME → mystorageaccount.privatelink.blob.core.windows.net
```

And `mystorageaccount.privatelink.blob.core.windows.net` itself has an A record on public DNS pointing to the **public IP** — so internet clients still land on the public IP via the full chain.

---

#### DNS Resolution — Internet User vs Internal VNet User

**Internet user (no private zone, follows public DNS chain):**
```
Client queries: mystorageaccount.blob.core.windows.net
  → Public DNS: finds CNAME → mystorageaccount.privatelink.blob.core.windows.net
  → Public DNS: resolves mystorageaccount.privatelink.blob.core.windows.net → 52.180.x.x (public IP A record)
  → Client connects to 52.180.x.x over internet
```
Internet client follows the full CNAME chain and lands on the public IP. Behavior unchanged from before Private Endpoint existed.

**Internal VNet user (private zone linked, 168.63.129.16 intercepts):**
```
Client queries: mystorageaccount.blob.core.windows.net
  → 168.63.129.16: finds CNAME → mystorageaccount.privatelink.blob.core.windows.net
  → 168.63.129.16: checks private DNS zones linked to this VNet
  → Finds zone privatelink.blob.core.windows.net with A record: mystorageaccount → 10.232.48.100
  → Returns 10.232.48.100 (private IP) — never reaches public DNS for the privatelink lookup
  → Client connects to 10.232.48.100 via Azure fabric
```
The private zone intercepts the CNAME resolution at the `privatelink.*` level and returns the private IP. The public DNS A record for `mystorageaccount.privatelink.blob.core.windows.net` is never consulted.

**Why this design works:**
- Same FQDN — `mystorageaccount.blob.core.windows.net` — for both internet and internal clients
- Application connection strings don't change
- The `privatelink.*` namespace exists on both public DNS (public IP A record) and as an Azure private zone (private IP A record)
- Which answer you get depends entirely on which DNS resolver handles the `privatelink.*` lookup

---

### privatelink.* DNS Zones

Standardised zone names — one per service type:

| Service | Private DNS Zone |
|---|---|
| Azure Blob Storage | `privatelink.blob.core.windows.net` |
| Azure SQL Database | `privatelink.database.windows.net` |
| Azure Key Vault | `privatelink.vaultcore.azure.net` |
| Azure Container Registry | `privatelink.azurecr.io` |

Azure can auto-create the zone, A record, and VNet link during Private Endpoint creation ("Integrate with private DNS zone"). In hub-spoke, use this but verify the zone gets linked to the hub VNet — manage spoke links manually.

**At scale:** Use Azure Policy (*Private Link and DNS integration at scale* pattern) to auto-link zones whenever a new VNet is created or a new Private Endpoint is deployed.

---

### NSG Support for Private Endpoints

NSGs on Private Endpoint subnets are **silently not enforced by default.** The property that must be explicitly enabled on the subnet:

- `privateEndpointNetworkPolicies` → set to `Enabled` (enables NSG + UDR enforcement for PE traffic)

**Note:** `privateLinkServiceNetworkPolicies` is a separate property that applies only to the **Private Link Service provider side** — not to Private Endpoints. For Private Link Service, this property must actually be **disabled** for the service to function. Don't confuse the two.

Until `privateEndpointNetworkPolicies` is enabled, NSG rules attached to the PE subnet are silently not enforced for Private Endpoint traffic. Classic security audit finding — NSG attached, rules look correct, nothing is enforced.

---

### Hub DNS Forwarder Pattern for Hybrid

On-prem clients accessing Private Endpoints over ExpressRoute:
```
On-prem DNS
  → Conditional forwarder: privatelink.blob.core.windows.net → Inbound Endpoint IP
  → Query crosses ExpressRoute
  → Inbound Endpoint resolves in hub VNet context
  → Finds privatelink zone linked to hub → returns private IP
  → On-prem client connects via ExpressRoute → Private Endpoint
```

Requires one conditional forwarder per `privatelink.*` zone on on-prem DNS. Use Azure Policy at scale to manage zone links automatically.

---

### Azure Private Link Service

Flips the consumer/provider model — you become the provider, exposing your own application to other tenants.

**Use case:** Expose an internal app behind an Internal Load Balancer to another company's Azure tenant — without VNet peering, without public internet exposure.

```
Your tenant (Provider):
  Application VMs → Internal Load Balancer → Private Link Service resource

Other company's tenant (Consumer):
  Private Endpoint → points at your Private Link Service resource ID
  Gets private IP in their VNet
  Sends connection request → you approve it
  Accesses your app via that private IP
```

Key properties:
- No VNet peering required
- No public internet exposure
- Explicit connection approval flow — you control who connects
- Consumer has no visibility into your VNet
- Traffic stays on Microsoft backbone end to end
- `privateLinkServiceNetworkPolicies` must be **disabled** on the provider subnet for Private Link Service to function

AWS equivalent: AWS PrivateLink Service for exposing services across account boundaries.

---

### Firewall + NSG Interaction for Private Endpoints

Both operate at different points in the traffic path — complementary, not redundant:

```
Spoke VM
  → UDR → Azure Firewall (central policy, FQDN rules, logging)
  → peering → PE subnet NSG (last line of defense, IP/port filtering)
  → Private Endpoint
```

**Critical routing gotcha:** A spoke UDR of `0.0.0.0/0 → Firewall` does NOT force hub-bound PE traffic through the Firewall. The hub VNet peering system route (e.g. `10.232.0.0/21`) is more specific than `/0` and wins via LPM — traffic bypasses the Firewall and goes directly to the PE subnet.

**Fix:** Add an explicit UDR for the PE subnet CIDR:
```
10.232.48.0/24 → VirtualAppliance → Firewall IP
```
This /24 beats the peering system route via LPM and forces PE-bound traffic through the Firewall.

---

### Azure Firewall Rule Types and Evaluation Order

Evaluated in this fixed order:
1. **DNAT rules** — inbound NAT, not relevant for PE traffic
2. **Network rules** — L4, IP + port based
3. **Application rules** — L7, FQDN based

Priority numbers only apply **within** the same rule type — not across types.

**FQDN rules and Private Endpoint traffic:**

For Private Endpoint traffic, the destination is a private IP. Although the FQDN is present in the TLS SNI header, Azure Firewall does not inspect it unless TLS inspection is explicitly enabled (Premium SKU feature). Therefore, network rules match first and application rules are not evaluated in typical designs.

Expert-level nuance: SNI is technically visible at the TLS handshake layer and could theoretically be matched — but Azure Firewall Standard doesn't use it for application rule matching on private IP destinations. Only Firewall Premium with TLS inspection enabled can match FQDNs in encrypted traffic to private endpoints. In practice, access control for PE traffic is always IP-based — handled by network rules and NSG.

---

### Real World PE Subnet Design

**Centralized (hub-spoke) — all spokes need all PaaS services:**
```
Hub VNet
  └── PrivateEndpointSubnet (10.232.48.0/24)
        ├── PE for Storage   → 10.232.48.100
        ├── PE for SQL       → 10.232.48.101
        └── PE for Key Vault → 10.232.48.102
```
One subnet, one NSG, one route table. Simpler operationally.

**Least privilege — workload-specific PaaS access:**
```
Spoke 1 VNet
  └── PrivateEndpointSubnet → PE for Storage (app1 only)

Spoke 2 VNet
  └── PrivateEndpointSubnet → PE for SQL (app2 only)
```
More granular security, more endpoints to manage.

**Decision rule:** Shared service used by all spokes → PE in hub. Workload-specific PaaS → PE in that spoke.

---

## Exercises

### Exercise 1 — DNS Failure Trace ✅

**Scenario:** Private Endpoint for Storage at `10.232.48.100`. No DNS configured. VM queries `mystorageaccount.blob.core.windows.net`.

**What happens:**
1. DNS — `168.63.129.16` finds CNAME → `mystorageaccount.privatelink.blob.core.windows.net` → no private zone linked → falls through to public DNS → returns public IP `52.180.x.x`
2. Routing — VM sends traffic to `52.180.x.x` → hits `0.0.0.0/0 → Internet` system route → leaves VNet
3. Result — if public access disabled → connection refused. If public access open → succeeds but bypasses Private Endpoint entirely. Silent failure.
4. Private Endpoint used — No. Never in the picture.

**Fix — resources needed:**

For spoke VMs:
1. Private DNS zone `privatelink.blob.core.windows.net`
2. A record: `mystorageaccount → 10.232.48.100`
3. VNet resolution link from zone to spoke VNet

For on-prem clients over ExpressRoute:
4. Private Resolver Inbound Endpoint in hub
5. Private DNS zone linked to hub VNet
6. Conditional forwarder on on-prem DNS: `privatelink.blob.core.windows.net → Inbound Endpoint IP`

---

### Exercise 2 — Service Endpoint vs Private Endpoint Architecture ✅

**Scenario:** Azure SQL DB accessed by 3 spokes, on-prem over ExpressRoute, app tier only.

**Argument for Private Endpoint (Colleague B):**

1. **On-prem access** — Service Endpoint VNet identity doesn't extend to on-prem. On-prem traffic is treated as public IP traffic regardless of whether it comes via ExpressRoute. Must whitelist NAT IP on PaaS firewall. Private Endpoint works natively over ExpressRoute with no extra config.
2. **Granularity** — Service Endpoint allows subnet to reach ANY Azure SQL instance in tenant. Private Endpoint is pinned to one specific DB resource.
3. **Traffic inspection** — Service Endpoint traffic bypasses NVA/custom routing. Cannot put Azure Firewall in path. Private Endpoint supports UDR + Firewall inspection.
4. **Public endpoint** — Service Endpoint keeps public endpoint alive. Private Endpoint allows full public access disablement — defense in depth.

**Design:**
- Private Endpoint for SQL in hub PE subnet
- NSG on PE subnet with `privateEndpointNetworkPolicies` enabled — allow app tier CIDR on 1433 only
- UDRs on spoke subnets: `0.0.0.0/0 → Firewall` + `10.232.48.0/24 → Firewall`
- Private DNS zone `privatelink.database.windows.net` linked to hub + all spokes
- On-prem conditional forwarder: `privatelink.database.windows.net → Inbound Endpoint IP`
- Public access disabled on SQL resource

---

### Exercise 3 — Firewall Bypass via Peering Route ✅

**Scenario:** Spoke UDR `0.0.0.0/0 → Firewall`. PE at `10.232.48.100` in hub PE subnet `10.232.48.0/24`. Engineer claims UDR covers all traffic including PE-bound.

**Engineer is wrong.**

Spoke effective routing table:
```
10.232.0.0/21  → VNet peering (hub)   [system route — more specific]
0.0.0.0/0      → VirtualAppliance → Firewall IP  [UDR]
```

Packet to `10.232.48.100` — LPM picks `10.232.0.0/21` peering route over `/0` UDR. Traffic goes directly to hub via peering, bypassing Firewall entirely.

**Fix:** Add explicit UDR on spoke subnet:
```
10.232.48.0/24 → VirtualAppliance → Firewall IP
```
/24 beats /21 peering route via LPM — forces PE-bound traffic through Firewall.

---

### Exercise 4 — Multi-Tier Production Design ✅

**Topology:**
- Web tier: Spoke 1 `10.232.16.0/24`
- App tier: Spoke 2 `10.232.32.0/24`
- Hub PE subnet: `10.232.48.0/24`
  - Storage PE: `10.232.48.100`
  - SQL PE: `10.232.48.101`
  - Key Vault PE: `10.232.48.102`
- Azure Firewall: `10.232.49.1`
- Inbound Endpoint: `10.232.64.100`

**NSG on PE subnet (`privateEndpointNetworkPolicies` enabled):**
- Allow `10.232.16.0/24` → `10.232.48.100` port 443 (web tier → storage)
- Allow `10.232.32.0/24` → `10.232.48.101` port 1433 (app tier → SQL)
- Allow `10.232.32.0/24` → `10.232.48.102` port 443 (app tier → Key Vault)
- Allow on-prem CIDR → `10.232.48.101` port 1433 (on-prem → SQL)
- Implicit deny all

**Firewall network rules:**

| Priority | Source | Destination | Port | Action |
|---|---|---|---|---|
| 100 | 10.232.32.0/24 | 10.232.48.101 | 1433 | Allow |
| 110 | 10.232.32.0/24 | 10.232.48.102 | 443 | Allow |
| 120 | 10.232.16.0/24 | 10.232.48.100 | 443 | Allow |
| 130 | on-prem CIDR | 10.232.48.101 | 1433 | Allow |
| 65000 | Any | Any | Any | Deny |

**Firewall application rules (requirement #3 — block other storage accounts via public internet):**

| Priority | Source | Target FQDN | Protocol | Action |
|---|---|---|---|---|
| 200 | 10.232.16.0/24 | `mystorageaccount.blob.core.windows.net` | HTTPS:443 | Allow |
| 210 | 10.232.16.0/24 | `*.blob.core.windows.net` | HTTPS:443 | Deny |

Note: Application rules only apply to public endpoint traffic. For PE traffic (private IP destination), the FQDN is present in TLS SNI but Azure Firewall does not inspect it without TLS inspection enabled. Network rules match first — application rules are not evaluated in typical designs. Two threat vectors, two controls:
- PE path → NSG with destination-specific PE IPs
- Public internet path → Firewall application rules blocking other storage accounts

**UDRs (both spoke route tables):**
```
0.0.0.0/0        → VirtualAppliance → 10.232.49.1
10.232.48.0/24   → VirtualAppliance → 10.232.49.1
```

**DNS:**
- 3 private zones: `privatelink.blob.core.windows.net`, `privatelink.database.windows.net`, `privatelink.vaultcore.azure.net`
- All linked to hub VNet + resolution links to both spokes
- On-prem conditional forwarder for `privatelink.database.windows.net` only → `10.232.64.100`

**Public access:** Disabled on all three PaaS resources.

---

## Q&A Bank

**Q1.** VPN user gets certificate error then timeout accessing `mykvault.vault.azure.net`. Office users work fine. What's the root cause and what happens at TLS layer?

**A1.** VPN user's local DNS server has no conditional forwarder for `privatelink.vaultcore.azure.net` — resolves to public IP via public DNS CNAME chain. Public access is disabled on Key Vault. Connection hits public endpoint which rejects it. TLS handshake may complete (cert is valid for the FQDN) but connection is then killed — producing a TLS/connection error before timeout. Fix: add conditional forwarder on corporate VPN DNS for `privatelink.vaultcore.azure.net → Inbound Endpoint IP`.

---

**Q2.** Single spoke, single app, single Azure SQL DB, no on-prem, no hub. Justify Service Endpoint over Private Endpoint.

**A2.** Single resource eliminates scope creep concern. No on-prem removes Private Endpoint's killer feature. No cross-VNet access needed. Service Endpoint is free vs Private Endpoint's per-hour cost. Lock down SQL firewall to allow only that subnet — security posture equivalent for this scenario. Private Endpoint would be unnecessary cost and complexity.

---

**Q3.** NSG attached to PE subnet with deny rules. Security audit finds traffic bypassing NSG. No misconfiguration visible. Root cause?

**A3.** `privateEndpointNetworkPolicies` is `Disabled` on the subnet by default. NSG is attached and rules look correct but are silently not enforced against Private Endpoint traffic until this property is explicitly set to `Enabled`. Note: `privateLinkServiceNetworkPolicies` is a separate property for the Private Link Service provider side — irrelevant for Private Endpoints.

---

**Q4.** Spokes 1-3 resolve `mystorageaccount.blob.core.windows.net` correctly via inbound endpoint. Spoke 4 gets NXDOMAIN despite identical configuration and zone linked to Spoke 4. Root cause?

**A4.** Linking the private DNS zone to Spoke 4 is irrelevant — the inbound endpoint always resolves in hub VNet context regardless of which spoke sent the query. Most likely cause: something blocking UDP/53 from Spoke 4's CIDR to the inbound endpoint — NSG on the DNS subnet missing an allow rule for Spoke 4's source CIDR, or DNS server setting on Spoke 4 not correctly pointing to the inbound endpoint IP.

---

**Q5.** You need to expose an internal app behind an ILB to another company's Azure tenant — no VNet peering, no public internet. What feature enables this?

**A5.** Azure Private Link Service. You create a Private Link Service resource attached to your ILB frontend — requires `privateLinkServiceNetworkPolicies` disabled on the provider subnet. The other company creates a Private Endpoint in their VNet pointing at your Private Link Service resource ID. They send a connection request which you approve. They get a private IP in their VNet mapping to your application. No peering, no public internet, no visibility into each other's networks. Traffic stays on Microsoft backbone. AWS equivalent: AWS PrivateLink Service for cross-account service exposure.

---

## Key Gotchas

1. **CNAME to `privatelink.*` is only created when a Private Endpoint exists** — before PE creation, public FQDN resolves directly to public IP with no CNAME. The indirection is inserted at PE creation time.
2. **`privatelink.*` exists on both public DNS and as a private zone** — public DNS has an A record for it pointing to the public IP. The private zone intercepts that resolution for VNet clients and returns the private IP instead. Same FQDN, different answer depending on resolver context.
3. **DNS is not optional** — without DNS override, Private Endpoint is never used. Traffic goes to public IP silently. No error message.
4. **`privateEndpointNetworkPolicies` defaults to Disabled** — NSG on PE subnet is silently not enforced until explicitly enabled. Only this property matters for Private Endpoints.
5. **`privateLinkServiceNetworkPolicies` is NOT for Private Endpoints** — it applies to the Private Link Service provider side only, and must be **disabled** (not enabled) for Private Link Service to function. Don't confuse the two.
6. **`0.0.0.0/0` UDR doesn't force hub PE traffic through Firewall** — peering system route is more specific and wins via LPM. Always add explicit UDR for PE subnet CIDR.
7. **Zone link to spoke is irrelevant when using inbound endpoint** — inbound endpoint always resolves in hub VNet context. Link zones to hub, not spokes, for centralized DNS.
8. **Auto-created DNS zone may link to wrong VNet** — when PE is in hub, verify auto-created zone links to hub VNet, not spoke. Manage spoke links manually.
9. **FQDN is in SNI but Firewall doesn't use it without TLS inspection** — for PE traffic, Azure Firewall Standard matches on IP only. Application rules are not evaluated. FQDN-based filtering for PE traffic requires Firewall Premium with TLS inspection — rarely used in practice.
10. **Service Endpoint on-prem identity limitation** — on-prem can reach the service via ExpressRoute Microsoft peering, but is treated as public traffic. Cannot use VNet-based firewall rules — must whitelist public/NAT IP explicitly.
11. **Service Endpoint scope is service type, not resource** — allows subnet to reach ALL instances of that service type unless restricted with Service Endpoint Policies.
12. **Private Link Service for cross-tenant exposure** — when you need to expose your own app to another tenant privately, Private Link Service is the answer. Not VPN, not peering, not public internet.
13. **Disable public access on PaaS resource** — don't rely on Firewall implicit deny alone. Disable public network access at the resource level as defense in depth.