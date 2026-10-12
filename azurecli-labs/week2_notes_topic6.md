# Topic 6 — Azure Firewall

---

## AWS Anchor

| AWS | Azure Equivalent |
|---|---|
| AWS Network Firewall | Azure Firewall |
| AWS Network Firewall Policy | Azure Firewall Policy |
| AWS Network Firewall Rule Groups | Rule Collection Groups |
| Gateway Load Balancer (NVA insertion) | NVA in hub + UDR (Azure Firewall replaces this) |

Key architectural difference: AWS Network Firewall requires Gateway Load Balancer or a dedicated inspection VPC for traffic steering. Azure Firewall sits directly in the hub VNet and traffic is steered via UDRs — simpler insertion model.

---

## Theory

### Azure Firewall vs NSG

| | NSG | Azure Firewall |
|---|---|---|
| Layer | L3/L4 — IP + port | L3/L4/L7 — IP, port, FQDN, protocols |
| Scope | Subnet or NIC level | Centralized hub — all traffic passing through |
| Stateful | ✅ | ✅ |
| FQDN filtering | ❌ | ✅ |
| Threat intelligence | ❌ | ✅ |
| Logging | Flow logs only | Full traffic logs via Azure Monitor |
| Cost | Free | ~$1.25/hour (Standard) |

**When you need both:** NSG for subnet-level micro-segmentation (east-west within a VNet), Azure Firewall for centralized north-south and hub-to-spoke inspection. Complementary, not alternatives.

---

### SKUs — Standard vs Premium

**Standard:**
- Network rules (L4 — IP/port)
- Application rules (L7 — FQDN based, HTTP/HTTPS)
- DNAT rules (inbound NAT)
- Threat intelligence
- SNAT for outbound traffic

**Premium adds:**
- **IDPS** — Intrusion Detection and Prevention System. Signature-based, inspects traffic patterns across L3-L7
- **TLS inspection** — decrypts HTTPS, inspects payload, re-encrypts. Required for true L7 visibility into encrypted traffic. Without this, application rules match on TLS SNI only — not the actual payload.
- **URL filtering** — full URL path filtering, not just FQDN
- **Web categories** — block/allow entire categories (social media, gambling etc.)

**Decision rule:** Standard for most enterprise use cases. Premium when you need DPI on encrypted traffic or signature-based threat detection.

**QUIC (HTTP/3) limitation:** Azure Firewall Premium TLS inspection does NOT support QUIC (UDP-based) traffic decryption — inspection only covers TCP/HTTPS/443. QUIC runs over UDP port 443. Firewall can block UDP/443 via a network rule to force clients to fall back to HTTP/2 over TCP, which Firewall Premium can inspect. If you allow UDP/443, QUIC traffic passes through uninspected.

**TLS 1.3:** Microsoft documentation does not explicitly confirm or deny TLS 1.3 inspection support for Azure Firewall Premium TLS inspection. Treat as unconfirmed — verify against latest docs before designing for TLS 1.3 inspection requirements.

**Inbound TLS inspection:** Azure Firewall Premium supports outbound and east-west TLS inspection only. Inbound TLS inspection (protecting internal servers from inbound HTTPS) is handled by Azure WAF on Application Gateway — not Azure Firewall.

**FQDN rules and TLS inspection nuance:** For Private Endpoint traffic, Azure Firewall Standard matches on private IP (network rules). Although the FQDN is present in the TLS SNI header, Firewall Standard does not inspect it without TLS inspection enabled. FQDN-based filtering for encrypted PE traffic requires Firewall Premium with TLS inspection explicitly configured per application rule.

---

### Rule Types and Evaluation Order

Fixed evaluation order — cannot be changed:

```
1. DNAT rules        — inbound NAT, translate public IP to internal
2. Network rules     — L4, IP + port
3. Application rules — L7, FQDN based (outbound only)
```

**Priority numbers are scoped within each rule type** — DNAT rules have their own priority numbering, network rules have their own, application rules have their own. A network rule at priority 100 and an application rule at priority 100 do not conflict — they're in separate evaluation tiers. The order between tiers (DNAT → Network → Application) is always fixed regardless of priority numbers.

**DNAT rules:** Processed first. Matching traffic is translated and allowed without requiring additional network or application rule matches. Application rules are outbound-only — DNAT handles inbound published traffic and the translated flow is not re-evaluated by network or application rules.

**Within each type:** Rule collections evaluated by priority (lower number = higher priority). First matching rule wins — implicit deny at the end of each collection.

**Network rules vs Application rules:**
- Use **network rules** for non-HTTP traffic (TCP/UDP to specific IPs) or when destination is a static IP
- Use **application rules** for HTTP/HTTPS to FQDNs — they match on TLS SNI or HTTP Host header regardless of what IP the FQDN resolves to. CDN-hosted services like GitHub use constantly rotating IPs — network rules with DNS-based IP matching are unreliable. Application rules are always the correct choice for HTTP/HTTPS destinations.

---

### Firewall Policy

Decoupled management object containing all rules. One policy can be applied to multiple Firewalls (multi-region deployments).

```
Firewall Policy
  └── Rule Collection Group (priority 100-65000)
        ├── DNAT Rule Collection       (own priority namespace)
        ├── Network Rule Collection    (own priority namespace)
        └── Application Rule Collection (own priority namespace)
```

**Policy inheritance:** Child policies inherit from parent policies. Parent policy rules always evaluated first. Used in enterprises where a central security team owns baseline rules and individual teams own workload-specific rules.

---

### SNAT Behavior

- Firewall SNATs outbound internet traffic to its own public IP
- All spokes share the same outbound public IP (the Firewall's)
- Source VM IP is hidden — need Firewall logs to trace which VM originated a connection
- Firewall does **NOT** SNAT traffic to RFC1918 ranges (10/8, 172.16/12, 192.168/16) — private-to-private traffic is never SNATed

---

### Threat Intelligence

Built into Standard and Premium. Azure maintains a feed of known malicious IPs and FQDNs.

Two modes:
- **Alert only** — logs match, allows traffic through
- **Alert and Deny** — logs and blocks

**Evaluated before custom rules** — highest priority in the evaluation chain. Even with an explicit allow rule, threat intelligence deny blocks known malicious traffic first.

---

### AzureFirewallSubnet Requirements

- Must be named exactly `AzureFirewallSubnet`
- Minimum /26 — Firewall deploys multiple instances for availability
- No NSG — Azure manages network policies
- No UDR — Firewall needs direct internet access for management plane

---

### Routing — Forcing Traffic Through Firewall

**Firewall IP is always `172.22.1.4`** — Azure Firewall takes the first usable IP (`.4`) in `AzureFirewallSubnet` (`172.22.1.0/26`).

**Spoke internet traffic:**
```
UDR on spoke subnet: 0.0.0.0/0 → VirtualAppliance → 172.22.1.4
```

**Spoke to hub PE subnet — the LPM problem:**

The peering system route covers the entire hub VNet. Adding an explicit `/24` UDR for the PE subnet beats it via LPM:

| Source | Prefix | Next Hop Type | Next Hop IP | Wins for PE traffic? |
|---|---|---|---|---|
| System (peering) | 172.22.0.0/20 | VNetPeering | — | ❌ More general |
| UDR (you add) | 172.22.3.0/24 | VirtualAppliance | 172.22.1.4 | ✅ More specific |

The `/24` UDR is more specific than the `/20` peering route — LPM selects it for traffic destined to `172.22.3.x`. Traffic to the rest of the hub (`172.22.0.x`, `172.22.1.x`, `172.22.2.x` etc.) still uses the peering route directly.

**GatewaySubnet UDRs** (for on-prem traffic inspection):
```
172.22.16.0/20 → VirtualAppliance → 172.22.1.4  (spoke1)
172.22.32.0/20 → VirtualAppliance → 172.22.1.4  (spoke2)
```

---

### Troubleshooting Firewall Issues

**Traffic not reaching Firewall:**
1. Check UDR is associated to the correct subnet — most common cause. On effective routes, if `0.0.0.0/0` shows `Internet` as next hop, the spoke subnet's route table is not associated OR the UDR is overridden by a more specific route. Note: `Internet` next hop means traffic is going directly to the internet — NOT that internet access is working normally. With Azure Firewall in place, `0.0.0.0/0` should show `VirtualAppliance` not `Internet`.
2. Check UDR next hop IP matches Firewall's actual private IP (`172.22.1.4`)
3. Check BGP propagation disabled on spoke route tables — on-prem routes shouldn't override UDRs

**Traffic hitting Firewall but being denied:**
1. Check Firewall Policy is associated to the Firewall resource — policy can exist with correct rules but if not attached, nothing enforced. Silent failure.
2. Check rule priority — a higher priority deny rule may be blocking before your allow rule is evaluated
3. Check source CIDR in rule matches the spoke subnet sending traffic
4. Check Firewall logs in Azure Monitor — shows exactly which rule matched and why traffic was denied

**Common silent failure:** Firewall Policy exists with correct rules but is not associated to the Firewall resource. Everything looks configured correctly but nothing is enforced.

---

## Exercises

### Exercise 1 — Traffic Path Analysis ✅

**Scenario:** Spoke VM needs to reach `api.github.com` on port 443. Trace the full traffic path and identify the correct rule type.

**Solution:**
```
Spoke VM (172.22.16.4)
  → UDR: 0.0.0.0/0 → VirtualAppliance → 172.22.1.4
  → Azure Firewall receives packet
  → Checks DNAT rules → no match (outbound traffic)
  → Checks Network rules → no match (if no IP-based rule)
  → Checks Application rules → matches allow rule for api.github.com:443
  → Firewall SNATs source IP to its public IP
  → Forwards to api.github.com
```

**Rule type: Application rule** — not network rule. GitHub uses CDN with constantly rotating IPs. A network rule with DNS-based IP matching would be unreliable. Application rules match on TLS SNI regardless of resolved IP.

---

### Exercise 2 — Firewall Policy Design ✅

**Scenario:** 3-tier application:
- Web tier: `172.22.16.0/24` — needs internet access
- App tier: `172.22.32.0/24` — needs Azure SQL Private Endpoint only
- DB tier: `172.22.48.0/24` — no outbound traffic allowed

**Rule collections — priority numbers are per rule type:**

Network rule collection (priority 100 within network rules tier):
| Priority | Name | Source | Destination | Port | Action |
|---|---|---|---|---|---|
| 100 | AllowAppToSQL | 172.22.32.0/24 | 172.22.3.5 (SQL PE) | 1433 | Allow |
| 200 | DenyDBOutbound | 172.22.48.0/24 | * | * | Deny |

Application rule collection (priority 100 within application rules tier):
| Priority | Name | Source | Target FQDN | Protocol | Action |
|---|---|---|---|---|---|
| 100 | AllowWebInternet | 172.22.16.0/24 | * | HTTPS:443 | Allow |

**Note:** Network and application rules have independent priority namespaces. Priority 100 in network rules and priority 100 in application rules do not conflict — they exist in separate evaluation tiers. The DB tier deny rule must be in network rules to ensure it's evaluated (application rules are outbound HTTP/HTTPS only).

---

### Exercise 3 — Spoke Loses Internet After Firewall Enabled ✅

**Scenario:** Hub VNet with Azure Firewall at `172.22.1.4`. Spokes: spoke1 (`172.22.16.0/24`), spoke2 (`172.22.32.0/24`). After enabling Firewall and creating an allow rule, spoke VM loses internet access. Three most likely misconfigurations:

1. **UDR not associated to spoke subnet** — traffic never reaches Firewall. Check effective routes on spoke VM NIC — if `0.0.0.0/0` shows `Internet` as next hop, the route table is not associated to that subnet. Note: `Internet` next hop means traffic is going directly to the internet path (bypassing Firewall), not that internet is working. With Firewall in place and no other controls, direct internet via the `Internet` next hop may still work — but traffic is uninspected and uncontrolled.

2. **Firewall Policy not associated to Firewall resource** — policy exists with correct rules but Firewall is enforcing nothing. Silent failure — traffic hits Firewall and gets implicitly denied by the default deny.

3. **Rule source CIDR incorrect** — rule exists but source doesn't match spoke subnet CIDR. Check exact source address in rule matches `172.22.16.0/24` (or `*` for any source).

---

## Q&A Bank

**Q1.** NSG vs Azure Firewall — colleague says NSGs are enough, no need for Firewall. Concrete scenario proving otherwise?

**A1.** NSGs can't filter based on FQDN — only IP and port. If you need to allow spoke VMs to reach `*.microsoft.com` but block all other internet, NSG can't do it — you'd need to maintain a constantly changing IP allowlist as Microsoft's CDN IPs rotate. Azure Firewall application rules match on the FQDN in the TLS SNI regardless of IP, solving this cleanly. Additionally NSGs have no threat intelligence feed, no centralized logging across all subnets, and no IDPS capability.

---

**Q2.** Rule evaluation order — DNAT vs network vs application rules, which evaluated first?

**A2.** DNAT → Network → Application. Fixed order, cannot be changed. Priority numbers are scoped within each rule type — each type has its own independent priority namespace. DNAT rules match first — matching traffic is translated and allowed without further evaluation. Application rules are outbound-only — they never apply to DNAT traffic. Within each tier, lower priority number = higher priority = evaluated first.

---

**Q3.** What does SNAT at the Firewall mean for spoke VMs' effective source IP on the internet?

**A3.** All internet-bound traffic from all spokes appears to originate from the Firewall's public IP — not the individual VM's private IP. All spokes share the same outbound public IP. To trace which VM originated a connection, you need Firewall logs. SNAT does NOT apply to private-to-private traffic (RFC1918 destinations) — only internet-bound traffic is SNATed.

---

**Q4.** Azure Firewall Premium vs Standard — what specific threat scenarios justify Premium cost?

**A4.** Three scenarios: (1) Need to inspect HTTPS payload — Standard only sees TLS SNI, Premium with TLS inspection decrypts and inspects actual content (TCP/443 only — QUIC/UDP not supported); (2) Signature-based threat detection — IDPS matches known attack patterns in traffic streams, not just IP/domain reputation; (3) Full URL path filtering — Standard matches on FQDN only (`api.github.com`), Premium can match on full URL path (`api.github.com/uploads/*`). If your threat model requires any of these, Premium is justified.

---

**Q5.** Threat intelligence in Azure Firewall — what does "alert and deny" mode do vs "alert only"?

**A5.** Alert only: logs when traffic matches a known malicious IP/FQDN but allows it through. Useful for baselining — see what malicious traffic exists before blocking. Alert and deny: logs AND blocks matching traffic. Threat intelligence rules are evaluated before all custom rules — even an explicit allow rule won't override a threat intelligence deny. Production recommendation is alert and deny.

---

## Key Gotchas

1. **Firewall IP is always `.4`** — first usable IP in `AzureFirewallSubnet`. Azure Firewall always takes this IP. Use `172.22.1.4` as next hop in all UDRs.
2. **Firewall Policy must be associated to the Firewall resource** — policy can exist with correct rules but if not attached to the Firewall, nothing is enforced. Silent failure.
3. **Application rules are outbound only** — DNAT handles inbound. Don't create application rules expecting them to filter inbound traffic.
4. **Use application rules for HTTP/HTTPS FQDNs** — network rules with DNS-based FQDN matching are unreliable for CDN-hosted services with rotating IPs. Application rules match TLS SNI regardless of IP.
5. **Priority numbers are per rule type** — DNAT, network, and application rules each have independent priority namespaces. Priority 100 in network rules doesn't conflict with priority 100 in application rules.
6. **Peering route bypasses Firewall for hub-bound traffic** — `172.22.0.0/20` peering system route is more specific than `/0` UDR. Add explicit UDR for PE subnet (`172.22.3.0/24`) to force PE-bound traffic through Firewall via LPM.
7. **Threat intelligence evaluated before custom rules** — even an explicit allow rule won't override threat intel deny. Can't whitelist known-malicious IPs.
8. **SNAT applies to internet traffic only** — RFC1918 destinations are not SNATed. Private-to-private flows preserve source IP.
9. **AzureFirewallSubnet minimum /26** — Firewall deploys multiple instances. /27 is insufficient.
10. **No NSG on AzureFirewallSubnet** — Azure manages network policies on this subnet. Adding an NSG breaks Firewall management plane traffic.
11. **QUIC (HTTP/3) not inspectable** — Azure Firewall Premium TLS inspection only covers TCP/443. QUIC runs over UDP/443 and cannot be decrypted. Block UDP/443 via network rule to force HTTP/2 fallback if full inspection is required.
12. **TLS 1.3 inspection support unconfirmed** — Microsoft docs don't explicitly confirm or deny TLS 1.3 support for Premium TLS inspection. Verify against latest docs before designing for this requirement.
13. **Inbound TLS inspection not supported** — Azure Firewall handles outbound and east-west TLS inspection only. Use AGW WAF for inbound TLS inspection.
14. **GatewaySubnet needs UDRs for spoke prefixes** — on-prem traffic arriving at VPN Gateway must be steered through Firewall before reaching spokes. Easy to forget.
15. **Tear down Azure Firewall same session** — ~$1.25/hour. Forgetting overnight = ~$30. Always confirm deletion before closing terminal.