# Lab 4 — Private Endpoints & Private Link

**Topic:** Service Endpoints, Private Endpoints, DNS integration, NSG enforcement
**Cost:** ~$0.25/day (PE + storage account) — keep for Topic 6 lab, tear down after.
**Estimated time:** 45-60 minutes
**Persistent:** Private DNS zones, NSG, storage account, Private Endpoint — keep for Topic 6.

---

## Subscription

**Subscription name:** Infrastructure Networking Dev/Test
**Subscription ID:** `<your-subscription-id>`

Replace this ID with your own if running in a different subscription.

---

## Environment Notes

**SSL verification (Zscaler issue):** If you hit SSL errors, temporarily disable for lab use only:
```powershell
$env:AZURE_CLI_DISABLE_CONNECTION_VERIFICATION = "1"
```

**Azure Policy enforcement:** This subscription enforces `Storage account public access should be disallowed`. Always include `--allow-blob-public-access false` when creating storage accounts or the deployment will be rejected.

---

## Topology Built

```
Hub VNet
  └── snet-vg-lab-wus-pe (172.22.3.0/24)
        ├── pe-vg-lab-wus-storage → 172.22.3.4
        └── nsg-vg-lab-wus-hub-pe
              ├── AllowSpoke1 (priority 100) — 172.22.16.0/24 → * port * Allow
              └── DenyAll     (priority 4096) — * → * port * Deny

Spoke1 workload subnet:
  └── Service Endpoint: Microsoft.Storage (Lab 4a only)

Private DNS zone: privatelink.blob.core.windows.net
  ├── pdnslink-vg-lab-blob-hub    → vnet-vg-lab-wus-hub    (resolution)
  ├── pdnslink-vg-lab-blob-spoke1 → vnet-vg-lab-wus-spoke1 (resolution)
  └── pdnslink-vg-lab-blob-spoke2 → vnet-vg-lab-wus-spoke2 (resolution)
  └── A record: stvglabwus01 → 172.22.3.4

Storage account: stvglabwus01
  └── Public access: disabled
  └── Network default action: Deny
  └── Service Endpoint rule: spoke1 workload subnet allowed (Lab 4a)
```

---

## Prerequisites

Labs 1-3 complete. Verify foundation:
```powershell
az network vnet list `
  --resource-group rg-vg-lab-wus-01 `
  --output table
```

**VMs and Bastion:** Deploy VMs and Bastion Developer SKU instances as needed. Set VM passwords for Bastion access. See Lab 3 for detailed instructions.

---

## Lab 4a — Service Endpoint

### Step 1 — Enable Service Endpoint on Spoke1 Workload Subnet

```powershell
az network vnet subnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name snet-vg-lab-wus-spoke1-workload `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --service-endpoints Microsoft.Storage
```

**What this does:**
1. **Routing** — Azure injects routes for all Microsoft.Storage public IP ranges into the subnet's effective routing table with next hop `VirtualNetworkServiceEndpoint`. Traffic takes the Azure backbone instead of the internet.
2. **Subnet identity** — establishes a trust claim so the storage firewall can identify traffic as coming from this specific subnet.

Both are required for Service Endpoint-based access control to work. Enabling the endpoint alone doesn't restrict access — firewall rules are still needed.

**Verify:**
```powershell
az network vnet subnet show `
  --resource-group rg-vg-lab-wus-01 `
  --name snet-vg-lab-wus-spoke1-workload `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --query serviceEndpoints `
  --output table
```

Expected: `Microsoft.Storage` with `ProvisioningState: Succeeded`

---

### Step 2 — Create Storage Account

**Must include `--allow-blob-public-access false`** — enforced by subscription policy.

```powershell
az storage account create `
  --resource-group rg-vg-lab-wus-01 `
  --name stvglabwus01 `
  --location westus `
  --sku Standard_LRS `
  --kind StorageV2 `
  --allow-blob-public-access false `
  --tags owner=vg env=lab purpose=networking
```

---

### Step 3 — Lock Storage Firewall to Spoke1 Subnet

```powershell
# Add spoke1 subnet as allowed source
az storage account network-rule add `
  --resource-group rg-vg-lab-wus-01 `
  --account-name stvglabwus01 `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --subnet snet-vg-lab-wus-spoke1-workload

# Set default action to Deny
az storage account update `
  --resource-group rg-vg-lab-wus-01 `
  --name stvglabwus01 `
  --default-action Deny
```

**Verify:**
```powershell
az storage account show `
  --resource-group rg-vg-lab-wus-01 `
  --name stvglabwus01 `
  --query networkRuleSet `
  --output json
```

Expected: `defaultAction: Deny`, spoke1 subnet in `virtualNetworkRules`.

---

### Step 4 — Test Access

**From spoke1 via Bastion:**
```bash
curl -I https://stvglabwus01.blob.core.windows.net
nslookup stvglabwus01.blob.core.windows.net
```

Expected:
- `curl` → HTTP 400 (network allowed, request syntax invalid — expected)
- `nslookup` → public IP (e.g. `20.60.168.x`) — **Service Endpoint does not change DNS**

**From spoke2 via Bastion:**
```bash
curl -I https://stvglabwus01.blob.core.windows.net
```

Expected: timeout — storage firewall `defaultAction: Deny` blocks spoke2.

---

## Lab 4b — Private Endpoint

### Step 1 — Create the Private Endpoint

```powershell
az network private-endpoint create `
  --resource-group rg-vg-lab-wus-01 `
  --name pe-vg-lab-wus-storage `
  --location westus `
  --vnet-name vnet-vg-lab-wus-hub `
  --subnet snet-vg-lab-wus-pe `
  --private-connection-resource-id "/subscriptions/<your-subscription-id>/resourceGroups/rg-vg-lab-wus-01/providers/Microsoft.Storage/storageAccounts/stvglabwus01" `
  --group-id blob `
  --connection-name conn-vg-lab-wus-storage `
  --tags owner=vg env=lab purpose=networking
```

`--group-id blob` — scopes PE to blob service only. Storage has multiple sub-resources (blob, file, queue, table) — each needs its own PE.

**Verify and note the private IP:**
```powershell
az network private-endpoint show `
  --resource-group rg-vg-lab-wus-01 `
  --name pe-vg-lab-wus-storage `
  --query customDnsConfigs `
  --output json
```

Expected: `172.22.3.4` — first usable IP in `snet-vg-lab-wus-pe`.

Key output fields:
- `customDnsConfigs.ipAddresses` — private IP assigned
- `privateLinkServiceConnectionState.status: Approved` — auto-approved (same tenant/owner)
- `groupIds: blob` — PE scoped to blob only

---

### Step 2 — Create Private DNS Zone

```powershell
az network private-dns zone create `
  --resource-group rg-vg-lab-wus-01 `
  --name privatelink.blob.core.windows.net `
  --tags owner=vg env=lab purpose=networking
```

---

### Step 3 — Link Zone to Hub VNet

```powershell
az network private-dns link vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name privatelink.blob.core.windows.net `
  --name pdnslink-vg-lab-blob-hub `
  --virtual-network vnet-vg-lab-wus-hub `
  --registration-enabled false
```

---

### Step 4 — Create A Record

```powershell
az network private-dns record-set a add-record `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name privatelink.blob.core.windows.net `
  --record-set-name stvglabwus01 `
  --ipv4-address 172.22.3.4
```

---

### Step 5 — Link Zone to Spoke VNets

```powershell
az network private-dns link vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name privatelink.blob.core.windows.net `
  --name pdnslink-vg-lab-blob-spoke1 `
  --virtual-network vnet-vg-lab-wus-spoke1 `
  --registration-enabled false

az network private-dns link vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name privatelink.blob.core.windows.net `
  --name pdnslink-vg-lab-blob-spoke2 `
  --virtual-network vnet-vg-lab-wus-spoke2 `
  --registration-enabled false
```

---

### Step 6 — Test DNS Resolution

From spoke1 via Bastion:
```bash
nslookup stvglabwus01.blob.core.windows.net
```

Expected:
```
stvglabwus01.blob.core.windows.net  canonical name = stvglabwus01.privatelink.blob.core.windows.net
stvglabwus01.privatelink.blob.core.windows.net  Address: 172.22.3.4
```

**DNS propagation note:** Immediately after creating zone links, the first query may still return the public IP. Run nslookup a second time — it resolves correctly once `168.63.129.16` picks up the new zone link. Normal behavior.

**Both spokes now get HTTP 400** from curl — this is the critical production gotcha:

**PaaS firewall rules only apply to internet-originated traffic.** Internal VNet traffic (including traffic from peered spokes via a Private Endpoint) is not subject to the storage firewall rules — it is allowed by default. The `defaultAction: Deny` rule you set in Lab 4a is completely irrelevant for PE traffic. NSG on the PE subnet is the only effective control for internal traffic.

---

### Step 7 — Enable NSG on PE Subnet

#### Create NSG

```powershell
az network nsg create `
  --resource-group rg-vg-lab-wus-01 `
  --name nsg-vg-lab-wus-hub-pe `
  --location westus `
  --tags owner=vg env=lab purpose=networking
```

#### Add Allow Rule for Spoke1

```powershell
az network nsg rule create `
  --resource-group rg-vg-lab-wus-01 `
  --nsg-name nsg-vg-lab-wus-hub-pe `
  --name AllowSpoke1 `
  --priority 100 `
  --source-address-prefixes 172.22.16.0/24 `
  --destination-port-ranges * `
  --protocol * `
  --access Allow `
  --direction Inbound `
  --description "Allow spoke1 workload subnet to storage PE"
```

#### Add Explicit Deny All

```powershell
az network nsg rule create `
  --resource-group rg-vg-lab-wus-01 `
  --nsg-name nsg-vg-lab-wus-hub-pe `
  --name DenyAll `
  --priority 4096 `
  --source-address-prefixes * `
  --destination-port-ranges * `
  --protocol * `
  --access Deny `
  --direction Inbound `
  --description "Block everything not explicitly allowed"
```

**Why explicit deny at 4096?**
Azure NSGs have a default `AllowVnetInBound` rule at priority 65000 that allows all traffic from peered VNets. Without the explicit deny at 4096, spoke2 (a peered VNet) still gets through via that default rule. The explicit deny at 4096 overrides `AllowVnetInBound` for all sources not matched by higher priority rules.

**Warning from Azure:** Azure warns that this deny rule blocks `AzureLoadBalancer` and `VirtualNetwork` tags. For a PE subnet these warnings are irrelevant — no VMs or Load Balancers in this subnet, only a NIC representing the storage account.

#### Enable `privateEndpointNetworkPolicies` + Attach NSG

```powershell
az network vnet subnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name snet-vg-lab-wus-pe `
  --vnet-name vnet-vg-lab-wus-hub `
  --private-endpoint-network-policies Enabled `
  --network-security-group nsg-vg-lab-wus-hub-pe
```

**Critical:** `privateEndpointNetworkPolicies` defaults to `Disabled`. NSG is silently not enforced until this is explicitly set to `Enabled`. Classic security audit finding — NSG attached, rules look correct, nothing enforced.

---

### Step 8 — Verify NSG Enforcement

**From spoke1 via Bastion:**
```bash
curl -I https://stvglabwus01.blob.core.windows.net
```
Expected: HTTP 400 — NSG allows spoke1 through.

**From spoke2 via Bastion:**
```bash
curl -I https://stvglabwus01.blob.core.windows.net
```
Expected: timeout — explicit deny at 4096 blocks spoke2.

---

## Lab 4a vs 4b — Final Comparison

| | Service Endpoint | Private Endpoint |
|---|---|---|
| DNS resolution | Public IP throughout | Private IP `172.22.3.4` |
| Spoke2 blocked by | Storage firewall `defaultAction: Deny` | NSG explicit deny rule |
| Storage firewall effective | Yes — internet traffic goes through it | No — PE traffic bypasses it entirely |
| Access control for internal traffic | Not applicable — SE traffic goes to public endpoint | NSG + `privateEndpointNetworkPolicies` |
| `privateEndpointNetworkPolicies` needed | No | Yes — must be Enabled |

---

## Key Observations from This Lab

1. **Service Endpoint does two things** — routing (backbone path) + subnet identity (trust claim for PaaS firewall). Both needed for access control to work. Enabling SE on subnet alone doesn't restrict access.
2. **Service Endpoint doesn't change DNS** — public IP returned throughout. Traffic goes to public IP via backbone, not via a private IP.
3. **PaaS firewall rules only apply to internet-originated traffic** — internal VNet and peered VNet traffic via Private Endpoint completely bypasses the PaaS service firewall. `defaultAction: Deny` is irrelevant for PE traffic. NSG on the PE subnet is the only effective control for internal traffic.
4. **`privateEndpointNetworkPolicies` defaults to Disabled** — NSG silently not enforced until explicitly enabled. Always verify this on PE subnets.
5. **Default `AllowVnetInBound` rule allows peered VNets** — must add explicit deny at priority < 65000 to block peered spoke traffic. Without it, all peered VNets get through regardless of your custom allow rules.
6. **DNS propagation delay** — immediately after creating zone links, first query may return public IP. Second query resolves correctly. Normal behavior.
7. **PE connection auto-approved within same tenant** — cross-tenant connections require manual approval. `privateLinkServiceConnectionState.status: Approved` confirms this.
8. **`--group-id` scopes PE to specific sub-resource** — storage has blob, file, queue, table. Each needs its own PE and its own `privatelink.*` DNS zone.
9. **Azure Policy can block resource creation** — subscription-level policies enforce security standards. Always check policy compliance when deployments fail with `RequestDisallowedByPolicy`.
10. **PE subnet NSG warnings about AzureLoadBalancer and VirtualNetwork** — irrelevant for PE subnets. No VMs or LBs in PE subnet, only PE NICs.

---

## Teardown

**Keep for Topic 6 (Azure Firewall lab):**
- Storage account `stvglabwus01` — needed for Firewall rule testing
- Private Endpoint `pe-vg-lab-wus-storage` — needed for PE traffic inspection testing
- NSG `nsg-vg-lab-wus-hub-pe` — reuse for Topic 6
- Private DNS zones + links — free, keep

**⚠️ Tear down after Topic 6:**
```powershell
az network private-endpoint delete `
  --resource-group rg-vg-lab-wus-01 `
  --name pe-vg-lab-wus-storage `
  --yes

az storage account delete `
  --resource-group rg-vg-lab-wus-01 `
  --name stvglabwus01 `
  --yes
```

**Deallocate VMs now:**
```powershell
az vm deallocate --resource-group rg-vg-lab-wus-01 --name vm-vg-lab-wus-spoke1 --no-wait
az vm deallocate --resource-group rg-vg-lab-wus-01 --name vm-vg-lab-wus-hub --no-wait
az vm deallocate --resource-group rg-vg-lab-wus-01 --name vm-vg-lab-wus-spoke2 --no-wait
```