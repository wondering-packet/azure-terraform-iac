# Lab 3 — Azure DNS (Private Zones & Private Resolver)

**Topic:** Azure DNS — Private Zones, Auto-Registration, Hub-Spoke Resolution, Private Resolver
**Cost:** Lab 3a free. Lab 3b ~$0.50/hour (Private Resolver) — tear down immediately after.
**Estimated time:** 45-60 minutes
**Persistent:** Private DNS zone + VNet links yes. Private Resolver, Forwarding Ruleset, VMs — tear down after lab.

---

## Subscription

**Subscription name:** Infrastructure Networking Dev/Test
**Subscription ID:** `<your-subscription-id>`

Replace this ID with your own subscription ID if running in a different subscription.

---

## Environment Notes

**SSL verification (Zscaler issue):** If you hit SSL errors when installing CLI extensions, temporarily disable connection verification. For lab use only — never in production:

```powershell
$env:AZURE_CLI_DISABLE_CONNECTION_VERIFICATION = "1"
```

Reset after lab:
```powershell
Remove-Item Env:\AZURE_CLI_DISABLE_CONNECTION_VERIFICATION
```

---

## Topology Built

```
private DNS zone: internal.lab.com
  ├── pdnslink-vg-lab-hub     → vnet-vg-lab-wus-hub     (registration enabled)
  ├── pdnslink-vg-lab-spoke1  → vnet-vg-lab-wus-spoke1  (resolution only)
  └── pdnslink-vg-lab-spoke2  → vnet-vg-lab-wus-spoke2  (resolution only)

Hub VNet (Lab 3b additions):
  ├── snet-vg-lab-wus-dns-inbound  172.22.4.0/24  (delegated: Microsoft.Network/dnsResolvers)
  ├── snet-vg-lab-wus-dns-outbound 172.22.5.0/24  (delegated: Microsoft.Network/dnsResolvers)
  └── dnsresolver-vg-lab-wus
        ├── Inbound Endpoint  → 172.22.4.4
        └── Outbound Endpoint → no IP (internal egress only)

Forwarding Ruleset: fwruleset-vg-lab-wus
  └── Rule: fakedomain.internal. → 8.8.8.8:53
  └── VNet link → vnet-vg-lab-wus-hub
```

---

## Prerequisites

Lab 1 and Lab 2 complete. Verify foundation:

```powershell
az network vnet list `
  --resource-group rg-vg-lab-wus-01 `
  --output table
```

Expected: 3 VNets — hub, spoke1, spoke2.

---

## Bastion Setup

**Developer SKU Bastion is free but cannot traverse VNet peering.** Deploy one per VNet where you need VM access.

```powershell
# Bastion for hub VNet
az network bastion create `
  --resource-group rg-vg-lab-wus-01 `
  --name bastion-vg-lab-wus-hub `
  --vnet-name vnet-vg-lab-wus-hub `
  --sku Developer `
  --location westus

# Bastion for spoke1
az network bastion create `
  --resource-group rg-vg-lab-wus-01 `
  --name bastion-vg-lab-wus-spoke1 `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --sku Developer `
  --location westus

# Bastion for spoke2
az network bastion create `
  --resource-group rg-vg-lab-wus-01 `
  --name bastion-vg-lab-wus-spoke2 `
  --vnet-name vnet-vg-lab-wus-spoke2 `
  --sku Developer `
  --location westus
```

**Connect via portal:** VM → Connect → Bastion → enter `azureuser` + password.

**Note:** Bastion Developer SKU only supports username + password authentication — SSH keys are not supported. Always set a password on VMs before connecting.

---

## Lab 3a — Private DNS Zone with Hub-Spoke Resolution

### Step 1 — Create the Private DNS Zone

Private DNS zones are global resources — no `--location` needed.

```powershell
az network private-dns zone create `
  --resource-group rg-vg-lab-wus-01 `
  --name internal.lab.com `
  --tags owner=vg env=lab purpose=networking
```

**Verify:**
```powershell
az network private-dns zone show `
  --resource-group rg-vg-lab-wus-01 `
  --name internal.lab.com `
  --output table
```

Expected: `ProvisioningState: Succeeded`

**Note:** Use `show` for a specific named resource, `list` for all resources of a type:
```powershell
az network private-dns zone list `
  --resource-group rg-vg-lab-wus-01 `
  --output table
```

---

### Step 2 — Create VNet Links

```powershell
# Hub — registration enabled (auto-registers VM hostnames as A records)
az network private-dns link vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name internal.lab.com `
  --name pdnslink-vg-lab-hub `
  --virtual-network vnet-vg-lab-wus-hub `
  --registration-enabled true

# Spoke1 — resolution only
az network private-dns link vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name internal.lab.com `
  --name pdnslink-vg-lab-spoke1 `
  --virtual-network vnet-vg-lab-wus-spoke1 `
  --registration-enabled false

# Spoke2 — resolution only
az network private-dns link vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name internal.lab.com `
  --name pdnslink-vg-lab-spoke2 `
  --virtual-network vnet-vg-lab-wus-spoke2 `
  --registration-enabled false
```

**Verify:**
```powershell
az network private-dns link vnet list `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name internal.lab.com `
  --output table
```

Expected:
```
LinkName                RegistrationEnabled    LinkState
----------------------  ---------------------  -----------
pdnslink-vg-lab-hub     True                   Completed
pdnslink-vg-lab-spoke1  False                  Completed
pdnslink-vg-lab-spoke2  False                  Completed
```

---

### Step 3 — Deploy Test VMs

**No public IP, no default NSG** — access via Bastion only.

```powershell
# Hub VM
az vm create `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-hub `
  --image Ubuntu2204 `
  --size Standard_B1s `
  --vnet-name vnet-vg-lab-wus-hub `
  --subnet snet-vg-lab-wus-shared `
  --admin-username azureuser `
  --generate-ssh-keys `
  --public-ip-address '""' `
  --nsg '""' `
  --no-wait `
  --tags owner=vg env=lab purpose=networking

# Spoke1 VM (start if already exists from Lab 2)
az vm start `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1
```

**Set password for Bastion access (required — Developer SKU does not support SSH keys):**
```powershell
az vm user update `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-hub `
  --username azureuser `
  --password 'YourSecurePassword123!'

az vm user update `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1 `
  --username azureuser `
  --password 'YourSecurePassword123!'
```

**Check hub VM running:**
```powershell
az vm get-instance-view `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-hub `
  --query instanceView.statuses[1].displayStatus `
  --output tsv
```

---

### Step 4 — Verify Auto-Registration

Once hub VM is running, check auto-registered A record:

```powershell
az network private-dns record-set a list `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name internal.lab.com
```

Expected output includes:
```json
{
  "fqdn": "vm-vg-lab-wus-hub.internal.lab.com.",
  "isAutoRegistered": true,
  "aRecords": [{ "ipv4Address": "172.22.2.4" }],
  "ttl": 10
}
```

Key fields:
- `isAutoRegistered: true` — Azure flagging this as auto-created
- `ttl: 10` — low TTL so DNS changes propagate quickly when VM gets new IP

---

### Step 5 — Test Resolution from Spoke

Connect to spoke1 VM via Bastion (portal → VM → Connect → Bastion → enter azureuser + password).

```bash
nslookup vm-vg-lab-wus-hub.internal.lab.com
ping vm-vg-lab-wus-hub.internal.lab.com
```

Expected:
```
Server:         127.0.0.53
Address:        127.0.0.53#53

Name:   vm-vg-lab-wus-hub.internal.lab.com
Address: 172.22.2.4
```

**What this proves:**
- `127.0.0.53` — systemd-resolved on Ubuntu, forwards to `168.63.129.16`
- `168.63.129.16` checks zones linked to spoke1 VNet — finds `internal.lab.com` resolution link
- Returns hub VM's auto-registered A record
- Resolution link working without registration link

**2ms RTT on ping** — pure Azure fabric delivery via VNet peering.

---

### Step 6 — Challenge: Manual A Record for Spoke VM

Spoke1 cannot auto-register (hub holds the registration slot). Manually create its A record:

```powershell
az network private-dns record-set a add-record `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name internal.lab.com `
  --record-set-name vm-vg-lab-wus-spoke1 `
  --ipv4-address 172.22.16.4
```

Verify from hub VM via Bastion:
```bash
nslookup vm-vg-lab-wus-spoke1.internal.lab.com
```

Expected: `172.22.16.4` returned — manual registration working as auto-registration substitute.

---

## Lab 3b — Private Resolver

**Cost:** ~$0.50/hour. Deploy, test, tear down in one session.

### Step 1 — Create Delegated Subnets

```powershell
az network vnet subnet create `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name snet-vg-lab-wus-dns-inbound `
  --address-prefix 172.22.4.0/24 `
  --delegations Microsoft.Network/dnsResolvers

az network vnet subnet create `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name snet-vg-lab-wus-dns-outbound `
  --address-prefix 172.22.5.0/24 `
  --delegations Microsoft.Network/dnsResolvers
```

**What delegation means:** Subnet exclusively reserved for Private Resolver. No VMs or other resources can be deployed into it. Visible in portal as `Delegated to: Microsoft.Network/dnsRe...`

---

### Step 2 — Create the Private Resolver

Install extension first if not already installed:
```powershell
# If Zscaler SSL issues:
$env:AZURE_CLI_DISABLE_CONNECTION_VERIFICATION = "1"

az extension add --name dns-resolver
```

```powershell
$vnetId = az network vnet show `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-hub `
  --query id `
  --output tsv

az dns-resolver create `
  --resource-group rg-vg-lab-wus-01 `
  --name dnsresolver-vg-lab-wus `
  --location westus `
  --id $vnetId `
  --tags owner=vg env=lab purpose=networking
```

Expected: `dnsResolverState: Connected`, `provisioningState: Succeeded`

---

### Step 3 — Create Inbound Endpoint

```powershell
az dns-resolver inbound-endpoint create `
  --resource-group rg-vg-lab-wus-01 `
  --dns-resolver-name dnsresolver-vg-lab-wus `
  --name inbound-vg-lab-wus `
  --location westus `
  --ip-configurations "[{privateIpAllocationMethod:'Dynamic',id:'/subscriptions/<your-subscription-id>/resourceGroups/rg-vg-lab-wus-01/providers/Microsoft.Network/virtualNetworks/vnet-vg-lab-wus-hub/subnets/snet-vg-lab-wus-dns-inbound'}]" `
  --tags owner=vg env=lab purpose=networking
```

Expected: Inbound endpoint assigned `172.22.4.4` (first usable IP in inbound subnet).

**Note this IP** — spoke VMs and on-prem DNS servers forward queries here.

---

### Step 4 — Create Outbound Endpoint

```powershell
az dns-resolver outbound-endpoint create `
  --resource-group rg-vg-lab-wus-01 `
  --dns-resolver-name dnsresolver-vg-lab-wus `
  --name outbound-vg-lab-wus `
  --location westus `
  --id "/subscriptions/<your-subscription-id>/resourceGroups/rg-vg-lab-wus-01/providers/Microsoft.Network/virtualNetworks/vnet-vg-lab-wus-hub/subnets/snet-vg-lab-wus-dns-outbound" `
  --tags owner=vg env=lab purpose=networking
```

**Note:** Outbound endpoint has no IP address — it's an internal egress mechanism only. Never referenced directly by clients.

---

### Step 5 — Configure Spoke VNets to Use Inbound Endpoint

**Architecture note — Resolution links vs Inbound Endpoint:**

These are two alternative approaches for spoke VMs to resolve private DNS zones. You don't need both:

| Approach | How it works | When to use |
|---|---|---|
| Resolution links | Each spoke VNet linked directly to the zone. `168.63.129.16` in spoke context resolves natively. | Cloud-only, simple environments, no hybrid DNS needed |
| Inbound Endpoint (this step) | Spokes point DNS at inbound endpoint IP. Endpoint resolves in hub context where zones are linked. | Hybrid environments, centralized DNS control, on-prem forwarding needed |

With the inbound endpoint approach, **resolution links on spokes are redundant** — spokes don't use `168.63.129.16` in their own VNet context anymore. All queries go to `172.22.4.4` which resolves in hub context. Only the hub VNet needs zone links.

In Lab 3a we added resolution links to spokes — that was to demonstrate the native resolution pattern. In Lab 3b (this step), those links become unnecessary once spokes are pointed at the inbound endpoint.

```powershell
az network vnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-spoke1 `
  --dns-servers 172.22.4.4

az network vnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-spoke2 `
  --dns-servers 172.22.4.4
```

Restart spoke1 VM to pick up new DNS server (DHCP lease refresh):
```powershell
az vm restart `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1 `
  --no-wait
```

Verify from spoke1 via Bastion:
```bash
resolvectl status | grep "DNS"
```

Expected: `Current DNS Server: 172.22.4.4`

---

### Step 6 — Create Forwarding Ruleset

```powershell
az dns-resolver forwarding-ruleset create `
  --resource-group rg-vg-lab-wus-01 `
  --name fwruleset-vg-lab-wus `
  --location westus `
  --outbound-endpoints "[{id:'/subscriptions/<your-subscription-id>/resourceGroups/rg-vg-lab-wus-01/providers/Microsoft.Network/dnsResolvers/dnsresolver-vg-lab-wus/outboundEndpoints/outbound-vg-lab-wus'}]" `
  --tags owner=vg env=lab purpose=networking
```

---

### Step 7 — Add Forwarding Rule

```powershell
az dns-resolver forwarding-rule create `
  --resource-group rg-vg-lab-wus-01 `
  --ruleset-name fwruleset-vg-lab-wus `
  --name fwrule-vg-lab-test `
  --domain-name "fakedomain.internal." `
  --forwarding-rule-state Enabled `
  --target-dns-servers "[{ipAddress:'8.8.8.8',port:53}]"
```

**Note:** Domain names in forwarding rules require a trailing dot — `fakedomain.internal.` not `fakedomain.internal`.

---

### Step 8 — Associate Ruleset to Hub VNet

```powershell
az dns-resolver vnet-link create `
  --resource-group rg-vg-lab-wus-01 `
  --ruleset-name fwruleset-vg-lab-wus `
  --name vnetlink-vg-lab-hub `
  --id "/subscriptions/<your-subscription-id>/resourceGroups/rg-vg-lab-wus-01/providers/Microsoft.Network/virtualNetworks/vnet-vg-lab-wus-hub"
```

**Critical:** Without this link `168.63.129.16` in hub VNet context won't consult the forwarding rules. Ruleset exists but is never evaluated.

---

### Step 9 — Test Forwarding Rule

From spoke1 via Bastion:

```bash
nslookup fakedomain.internal
```

Expected output:
```
Server:         127.0.0.53
Address:        127.0.0.53#53

** server can't find fakedomain.internal: NXDOMAIN
```

**Important — what this output does and doesn't tell you:**

The client always sees `127.0.0.53` (systemd-resolved) as the resolver regardless of what happens upstream. The inbound endpoint acts as a recursive resolver proxy — the client never sees `8.8.8.8` in the response. DNS is a recursive query — the client doesn't know which upstream server ultimately answered.

`NXDOMAIN` here means the name doesn't exist somewhere upstream — but it doesn't definitively prove the forwarding rule fired. The only way to confirm the rule was actually matched and the query was forwarded via the outbound endpoint is **Azure Monitor DNS query logs** on the resolver. Without Log Analytics, you're inferring from behavior.

---

### Step 10 — Tear Down Private Resolver

**Deletion order is strictly enforced — Azure rejects out-of-order deletion with `BadRequest`.**

```
Required order:
1. Forwarding rules
2. Ruleset VNet links
3. Forwarding ruleset
4. Outbound endpoint
5. Inbound endpoint
6. Resolver
```

```powershell
# 1. Delete forwarding rules
az dns-resolver forwarding-rule delete `
  --resource-group rg-vg-lab-wus-01 `
  --ruleset-name fwruleset-vg-lab-wus `
  --name fwrule-vg-lab-test `
  --yes

# 2. Delete VNet link
az dns-resolver vnet-link delete `
  --resource-group rg-vg-lab-wus-01 `
  --ruleset-name fwruleset-vg-lab-wus `
  --name vnetlink-vg-lab-hub `
  --yes

# 3. Delete forwarding ruleset
az dns-resolver forwarding-ruleset delete `
  --resource-group rg-vg-lab-wus-01 `
  --name fwruleset-vg-lab-wus `
  --yes

# 4. Delete outbound endpoint
az dns-resolver outbound-endpoint delete `
  --resource-group rg-vg-lab-wus-01 `
  --dns-resolver-name dnsresolver-vg-lab-wus `
  --name outbound-vg-lab-wus `
  --yes

# 5. Delete inbound endpoint
az dns-resolver inbound-endpoint delete `
  --resource-group rg-vg-lab-wus-01 `
  --dns-resolver-name dnsresolver-vg-lab-wus `
  --name inbound-vg-lab-wus `
  --yes

# 6. Delete resolver
az dns-resolver delete `
  --resource-group rg-vg-lab-wus-01 `
  --name dnsresolver-vg-lab-wus `
  --yes
```

**Revert spoke DNS back to Azure default:**
```powershell
az network vnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-spoke1 `
  --dns-servers null

az network vnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-spoke2 `
  --dns-servers null
```

**Use `null` not empty string** — `--dns-servers ""` fails with `NetcfgInvalidIPAddress`.

**Deallocate VMs:**
```powershell
az vm deallocate `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1 `
  --no-wait

az vm deallocate `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-hub `
  --no-wait
```

---

## Key Observations from This Lab

1. **Auto-registration fires immediately on VM provisioning** — A record created as soon as NIC gets an IP, `isAutoRegistered: true` in the record
2. **TTL 10 seconds on auto-registered records** — low TTL so DNS changes propagate quickly when VM gets new IP
3. **Resolution link on spoke is sufficient** — spoke VMs don't need registration link to resolve records from the zone
4. **Auto-registered records disappear when VM is deallocated** — Azure cleans up DNS records for unreachable VMs automatically. Use manual A records for stable service discovery. Keep hub VM allocated if spoke VMs need to resolve hub records.
5. **Resolver deletion order strictly enforced** — must delete rules → links → ruleset → outbound endpoint → inbound endpoint → resolver. Out-of-order deletion returns `BadRequest`.
6. **DNS server reset requires `null` not empty string** — `--dns-servers null` works, `--dns-servers ""` fails
7. **Forwarding rule domain names need trailing dot** — `fakedomain.internal.` not `fakedomain.internal`
8. **Ruleset must be associated to hub VNet** — without `vnet-link`, `168.63.129.16` never consults the forwarding rules. Silent failure.
9. **Outbound endpoint has no IP** — internal egress only. Never referenced directly by clients or rules.
10. **Resolution links are redundant when using inbound endpoint** — once spoke VNets point DNS at the inbound endpoint, they resolve in hub context. Spoke resolution links become unnecessary. Two valid architectures: (1) resolution links per spoke — simple, cloud-only, no resolver needed; (2) inbound endpoint in hub, spokes point at it — better for hybrid and centralized DNS control. Pick one, don't mix both unnecessarily.
11. **Client never sees upstream DNS server** — DNS resolution is recursive. The inbound endpoint proxies queries on behalf of the client. `nslookup` always shows `127.0.0.53` regardless of where the query was forwarded. Only Azure Monitor DNS query logs can confirm which rule matched and where the query went.
12. **No public IP, no default NSG on VMs** — use `--public-ip-address '""' --nsg '""'` at VM creation. Access via Bastion Developer SKU.
13. **Bastion Developer SKU does not support SSH keys** — password authentication only. Always run `az vm user update` to set a password before connecting via Bastion.

---

## Teardown Summary

| Resource | Keep | Action |
|---|---|---|
| Private DNS zone `internal.lab.com` | ✅ | Keep — free, used in Topic 4 |
| VNet links (hub + spokes) | ✅ | Keep — free |
| Manual A records | ✅ | Keep — free |
| Delegated DNS subnets | ✅ | Keep — free, needed if resolver redeployed |
| Bastion instances | ✅ | Keep — free (Developer SKU) |
| Private Resolver | ❌ | Delete — ~$0.50/hour |
| Forwarding Ruleset | ❌ | Delete before resolver |
| VMs | ❌ | Deallocate — ~$0.20/day each |