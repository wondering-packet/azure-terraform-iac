# Topic 7 — Azure Load Balancing Services

---

## AWS Anchor & Service Overview

| Azure Service | Layer | Scope | Protocol | AWS Equivalent |
|---|---|---|---|---|
| Azure Load Balancer | L4 | Regional | TCP/UDP | NLB |
| Application Gateway | L7 | Regional | HTTP/HTTPS | ALB |
| Azure Front Door | L7 | Global | HTTP/HTTPS | CloudFront + Global Accelerator |
| Traffic Manager | DNS only | Global | Any (DNS level) | Route 53 latency/failover routing |

The mapping isn't perfect — Azure has 4 distinct services vs AWS's more fluid model. Each has very specific positioning. Know which one to reach for before the interview question finishes.

---

## Theory

### 1. Azure Load Balancer

**What it is:** L4 TCP/UDP load balancer. No HTTP awareness, no WAF, no SSL termination. Pure connection distribution.

**SKUs:** Basic (deprecated — never use) and Standard. Always use Standard.

**Two modes:**
- **Public** — internet-facing, public frontend IP
- **Internal (ILB)** — private frontend IP, traffic stays inside VNet

**Distribution modes:**
- **5-tuple hash (default)** — src IP, dst IP, src port, dst port, protocol. Provides stickiness within a transport session only. New session from same client may land on different backend.
- **2-tuple (session persistence)** — src IP + dst IP hash. Successive requests from same client IP go to same backend regardless of port changes.
- **3-tuple (session persistence)** — src IP + dst IP + protocol hash.

**Health probes:** TCP or HTTP, default 15-second interval. Detects backend failure quickly — no DNS TTL involved, failover in seconds.

**HA Ports rule:** Special ILB-only rule that forwards ALL ports and ALL protocols (`0/0`) to the backend pool. Not available on public Load Balancer. Designed exclusively for NVA scale-out scenarios — when multiple Firewall/NVA instances need to load balance all traffic types without knowing ports in advance.

```
Spoke UDR: 0.0.0.0/0 → ILB frontend IP (172.22.2.10)
ILB HA Ports rule → distributes across NVA 1, 2, 3
Each NVA inspects and forwards
```

**ILB vs NLB terminology:** There is no separate "NLB" product in Azure. Azure Load Balancer Standard covers both public L4 and Internal (ILB) use cases — same resource, configured differently. "ILB" = Azure Load Balancer with private frontend IP.

**When to use:** Ultra-low latency TCP/UDP workloads, non-HTTP protocols, NVA scale-out with HA Ports, financial trading platforms, gaming backends, DNS load balancing.

---

### 2. Application Gateway

**What it is:** L7 HTTP/HTTPS load balancer with WAF, URL routing, SSL termination, and session affinity. Regional only.

**SKUs:** v1 (deprecated) and v2. Always use v2.

**Key features:**
- **URL-based routing** — route `/api/*` to backend pool A, `/static/*` to backend pool B. Useful for microservices.
- **SSL termination** — decrypts HTTPS at the AGW frontend
- **SSL re-encryption** — re-encrypts after inspection and forwards HTTPS to backends (end-to-end SSL). Production recommendation — preserves inspection capability while encrypting transit.
- **Cookie affinity** — AGW inserts a cookie on first response, subsequent requests from same client go to same backend. Useful for stateful apps storing session on server.
- **WAF** — Web Application Firewall, OWASP rule sets, regional protection
- **WebSocket and HTTP/2** support

**Requires dedicated subnet** — convention is `ApplicationGatewaySubnet`. Minimum /28, recommended /24 for scale-out.

**SSL termination security consideration:**
- Terminate at AGW, send plain HTTP to backend → traffic between AGW and backend is unencrypted. Acceptable on private VNet, violates most compliance frameworks (PCI-DSS, HIPAA).
- Fix option 1: SSL re-encryption — keep termination at AGW, re-encrypt to backends. Preserves WAF + URL routing + full inspection.
- Fix option 2: SSL passthrough — disable termination, forward encrypted traffic to backends directly. AGW loses L7 inspection capability (no WAF, no URL routing). Rarely used.

**When to use:** Regional HTTP/HTTPS workloads needing WAF, URL routing, SSL termination, or session affinity.

---

### 3. Azure Front Door

**What it is:** Global L7 load balancer using Microsoft's anycast edge network (150+ PoPs worldwide). CDN + WAF + global routing in one service.

**How anycast works:**
- Client DNS resolves to nearest Front Door PoP IP (not a backend IP)
- TCP connection terminates at that PoP — low latency first hop
- Traffic rides Microsoft's private backbone from PoP to origin
- Lower latency than DNS-based routing because TCP handshake terminates at the edge

**Comparison to Traffic Manager:**

| | Traffic Manager | Azure Front Door |
|---|---|---|
| DNS response | Backend IP directly | Nearest PoP IP |
| Data path | Client → public internet → backend | Client → PoP → Microsoft backbone → backend |
| Edge caching | ❌ | ✅ |
| Edge WAF | ❌ | ✅ |
| SSL termination | ❌ | ✅ (at PoP) |
| Failover speed | DNS TTL limited (~150s worst case) | Seconds (probe-based, no TTL constraint) |

**Origin groups** — equivalent to AGW backend pools. Multiple origins per group with health probes and load balancing.

**Health probes:** Front Door probes from multiple edge locations. Failover requires multiple consecutive failed probes (default 3) before marking origin unhealthy. Total worst-case failover = (3 × probe interval) + DNS TTL of last response. With default 30s probe interval and 20s TTL: ~110 seconds worst case.

**When to use:** Global HTTP/HTTPS apps needing WAF at edge, CDN, low latency for global users, multi-region failover, SSL termination at PoP.

**Does Front Door replace AGW?** For many architectures yes — Front Door handles SSL termination, WAF, URL routing, caching, and global failover. AGW adds value when you need: inbound TLS inspection (AGW WAF), WebSocket, complex regional routing logic, or private backend access without Front Door Premium Private Link.

---

### 4. Traffic Manager

**What it is:** DNS-based routing only. No data plane, no proxying, no WAF, no SSL. It simply returns different DNS answers based on routing policy and health probe results.

**It's just DNS** — Traffic Manager never sees actual traffic. Clients receive a DNS response pointing at an endpoint IP and connect directly to it over the public internet.

**Routing methods:**
| Method | Behavior |
|---|---|
| Priority | Primary/secondary failover — all traffic to endpoint 1, fail over to endpoint 2 if unhealthy |
| Weighted | Distribute by percentage — 80% to endpoint 1, 20% to endpoint 2 |
| Performance | Route to lowest latency endpoint for the client (based on Internet Latency Table) |
| Geographic | Route based on client's geographic location |
| Subnet | Route based on client's IP subnet |

**Health probes:** Traffic Manager probes from multiple distributed locations globally — not a single regional probe agent. Each location independently tracks consecutive failures. Endpoints receive probes at higher frequency than the configured interval because multiple probe locations each follow the configured interval independently.

**Failover speed — the DNS TTL problem:**
- Health probe detects failure: up to `probe_interval × tolerated_failures` seconds
- DNS TTL: clients who already resolved the name won't re-query until TTL expires
- **Total worst-case failover = (probe_interval × consecutive_failures) + DNS TTL**
- Default: (30s × 3) + 60s TTL = **150 seconds worst case**
- Minimum TTL is 0 but DNS resolver caching means instant failover is never guaranteed

**Nested profiles** — Traffic Manager profiles can be nested. Outer profile does geographic routing, inner profiles do performance routing within each region. Powerful for complex global routing without Front Door.

**When to use:** Non-HTTP global routing, DNS-only routing is acceptable, cost-sensitive global routing, scenarios where you don't need edge presence.

---

### Decision Framework

```
Is traffic HTTP/HTTPS?
├── No (TCP/UDP, non-HTTP)
│   └── Azure Load Balancer (regional) or Traffic Manager (global DNS)
└── Yes (HTTP/HTTPS)
    ├── Regional only?
    │   └── Application Gateway (+ WAF if needed)
    └── Global?
        ├── Need edge PoP, CDN, WAF at edge, low latency → Azure Front Door
        └── DNS-only routing acceptable, cost-sensitive → Traffic Manager
```

**WAF placement:**
- **AGW WAF** — regional protection, inbound TLS inspection, close to the app
- **Front Door WAF** — global edge protection, stops attacks before they enter your region
- **Both** — defense in depth. Front Door WAF at edge + AGW WAF at regional layer for compliance requirements

---

### Why Traffic Manager + AGW Fails for Global SaaS

Three specific problems:

1. **Slow failover** — DNS TTL-based. Minimum ~90-150 seconds failover. Unacceptable for SaaS.
2. **No edge presence** — no WAF at edge, no SSL termination at PoP, no CDN. DDoS and application attacks hit AGW directly. AGW is not designed to absorb edge-scale attacks.
3. **No anycast/backbone optimization** — global users (e.g. Singapore) receive DNS pointing at a regional AGW (e.g. West Europe). Traffic traverses public internet with variable latency. No Microsoft backbone optimization. With Front Door, Singapore user connects to nearest PoP and rides backbone to origin.

---

## Exercises

### Exercise 1 — Decision Flowchart ✅

Build a decision flowchart for selecting among the 4 Azure load balancing services.

**Solution:** See Decision Framework section above.

Key decision points:
1. HTTP/HTTPS vs TCP/UDP
2. Regional vs global scope
3. Edge presence needed vs DNS-only acceptable
4. WAF requirement and where (edge vs regional)

---

### Exercise 2 — Global SaaS Architecture ✅

**Requirements:** WAF, SSL termination, URL-based routing to 3 backends, global failover, caching for static assets.

**Solution:**
```
Client
  → Azure Front Door (global anycast)
      ├── WAF at edge (Front Door WAF policy)
      ├── SSL termination at nearest PoP
      ├── Static asset caching at PoP
      ├── URL-based routing to 3 origin groups
      └── Health probes → /health endpoint on each backend
            ↓
  Backend (App Service, AKS, or VMs per region)
```

**Why Front Door alone (no AGW needed for this scenario):**
- Front Door handles SSL termination ✅
- Front Door WAF covers edge protection ✅
- Front Door URL routing to origin groups ✅
- Front Door caching for static assets ✅
- Front Door health probes detect downstream failures ✅

AGW would only be added if: compliance requires regional WAF layer, WebSocket needed, private backend access without Front Door Premium, or complex session affinity required.

**Why Traffic Manager + AGW fails:**
- No edge PoP — attacks hit AGW directly
- No CDN/caching
- DNS-based failover too slow for SaaS (90-150 seconds)
- No anycast — global users traverse public internet to regional AGW

---

### Exercise 3 — Traffic Manager Failover Timing ✅

**Scenario:** Traffic Manager with 30-second probe interval, 3 tolerated failures, 60-second DNS TTL. Primary region fails at 12:00:00.

**Worst case failover calculation:**
- Time to detect failure: 30s × 3 = 90 seconds → origin marked unhealthy at 12:01:30
- Last DNS response with primary IP sent just before detection: TTL = 60 seconds → expires at 12:02:30
- **Last possible client fails over at ~12:02:30 — 150 seconds after failure**

**Limiting factor:** Combination of consecutive probe failures AND DNS TTL. Neither alone determines failover speed — both must be accounted for.

---

## Q&A Bank

**Q1.** Customer needs global HTTP load balancing with WAF. Application Gateway or Front Door — and why not the other?

**A1.** Front Door. Application Gateway is regional — deploying it globally would require one AGW per region plus Traffic Manager on top for global routing, which adds DNS-based failover delay and no edge presence. Front Door is purpose-built for global HTTP/HTTPS with built-in WAF, anycast edge network, SSL termination at PoP, and CDN. Single service handles the entire requirement. AGW would only add value as a second layer for regional WAF or inbound TLS inspection — not needed for the basic requirement stated.

---

**Q2.** Traffic Manager doesn't proxy traffic. What does it actually do and what's the implication for failover speed?

**A2.** Traffic Manager only answers DNS queries — it returns different endpoint IPs based on routing policy and health probe results. It never sees actual application traffic. Implication for failover: even after Traffic Manager detects a failed endpoint and stops returning its IP, clients who already resolved the DNS name have the old IP cached until their TTL expires. Total failover = probe detection time + DNS TTL. With defaults: up to 150 seconds worst case. This is why Traffic Manager is unsuitable for latency-sensitive applications requiring sub-30-second failover.

---

**Q3.** When would you put both Application Gateway AND Azure Load Balancer in the same architecture?

**A3.** Multi-tier application pattern: internet-facing AGW for L7 (WAF, SSL termination, URL routing) as the entry point, then Internal Load Balancer behind it distributing traffic across backend VMs for each tier. Example: AGW handles public HTTPS → ILB distributes to app tier VMs → another ILB distributes to data tier VMs. Each tier gets independent health probing and scale-out without the overhead of L7 inspection on internal hops.

---

## Key Gotchas

1. **No separate NLB in Azure** — Azure Load Balancer Standard covers both public L4 and Internal (ILB) use cases. Same resource, different frontend IP type.
2. **2-tuple = src IP + dst IP** — not src IP only. 3-tuple adds protocol. 5-tuple is default (adds src port + dst port).
3. **HA Ports is ILB-only** — not available on public Load Balancer. Exclusively for NVA/Firewall scale-out behind an internal frontend.
4. **AGW requires dedicated subnet** — minimum /28, recommended /24. Can't share with other resources.
5. **AGW v1 deprecated** — always use v2 for new deployments.
6. **SSL termination exposes backend traffic** — always configure SSL re-encryption for compliance workloads. Plain HTTP to backends fails PCI-DSS and HIPAA audits.
7. **Front Door failover worst case ~110 seconds** — 3 consecutive failed probes (30s each) + 20s DNS TTL. Not instant despite being faster than Traffic Manager.
8. **Traffic Manager worst case ~150 seconds** — 3 × 30s probe + 60s TTL. DNS caching in resolvers means you can never guarantee faster failover regardless of TTL setting.
9. **Traffic Manager probes from multiple global locations** — not a single regional probe agent. Each location independently tracks consecutive failures — endpoints receive more probes than the configured interval suggests.
10. **Front Door handles SSL, WAF, URL routing, caching** — for many global SaaS architectures AGW is not needed. Don't add AGW by default — only when you need inbound TLS inspection, WebSocket, or complex regional routing.
11. **Traffic Manager + AGW for global SaaS = three specific failures** — slow DNS failover, no edge WAF/CDN, no anycast backbone optimization. Front Door solves all three.
12. **Basic Load Balancer SKU deprecated** — always use Standard for new deployments.
13. **Front Door health probes probe the actual app endpoint** — configure probes to hit `/health` on the application, not just the AGW. This detects downstream failures even when AGW itself is healthy.