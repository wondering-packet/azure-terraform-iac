# Lab 1 — Build the Persistent Foundation

**Topic:** VNet Peering & Hub-Spoke Topology
**Cost:** $0 — VNets, subnets, peering are all free
**Estimated time:** 20-30 minutes
**Persistent:** Yes — this foundation is reused across all 7 topics. Never delete unless nuking everything.

---

## Topology Built

```
172.22.0.0/16 (supernet)
│
├── vnet-vg-lab-wus-hub (172.22.0.0/20)
│     ├── GatewaySubnet                   172.22.0.0/27
│     ├── AzureFirewallSubnet             172.22.1.0/26
│     ├── snet-vg-lab-wus-shared          172.22.2.0/24
│     └── snet-vg-lab-wus-pe              172.22.3.0/24
│
├── vnet-vg-lab-wus-spoke1 (172.22.16.0/20)
│     └── snet-vg-lab-wus-spoke1-workload 172.22.16.0/24
│
└── vnet-vg-lab-wus-spoke2 (172.22.32.0/20)
      └── snet-vg-lab-wus-spoke2-workload 172.22.32.0/24

Peering links:
  vnet-vg-lab-wus-hub ↔ vnet-vg-lab-wus-spoke1
  vnet-vg-lab-wus-hub ↔ vnet-vg-lab-wus-spoke2
```

---

## Naming Convention

**Standard:** `<resource-type>-vg-lab-wus-<purpose>`

| Element | Value | Meaning |
|---|---|---|
| `<resource-type>` | `rg`, `vnet`, `snet`, `nsg`, `rt`, `pe` etc. | Azure resource type abbreviation |
| `vg` | your initials | Owner identifier in shared subscription |
| `lab` | environment | Distinguishes from dev/prod |
| `wus` | West US | Region |
| `<purpose>` | `hub`, `spoke1`, `shared` etc. | What specifically |

Reserved subnet names (cannot be changed):
- `GatewaySubnet` — required by Azure VPN Gateway
- `AzureFirewallSubnet` — required by Azure Firewall

---

## Address Space Planning

| Resource | CIDR | Notes |
|---|---|---|
| Supernet | 172.22.0.0/16 | Overall address space for all labs |
| Hub VNet | 172.22.0.0/20 | Hub — shared services |
| GatewaySubnet | 172.22.0.0/27 | /27 minimum required by Azure |
| AzureFirewallSubnet | 172.22.1.0/26 | /26 minimum required by Azure |
| snet-vg-lab-wus-shared | 172.22.2.0/24 | DNS, Bastion, shared VMs |
| snet-vg-lab-wus-pe | 172.22.3.0/24 | Private Endpoints (Topic 4) |
| Spoke 1 VNet | 172.22.16.0/20 | Workload spoke 1 |
| snet-vg-lab-wus-spoke1-workload | 172.22.16.0/24 | Spoke 1 workload subnet |
| Spoke 2 VNet | 172.22.32.0/20 | Workload spoke 2 |
| snet-vg-lab-wus-spoke2-workload | 172.22.32.0/24 | Spoke 2 workload subnet |

**Reserved for future topics:**
- `172.22.4.0/24` — DNS inbound endpoint subnet (Topic 3)
- `172.22.5.0/24` — DNS outbound endpoint subnet (Topic 3)
- `172.22.48.0/20` — Spoke 3 if needed

---

## Step 0 — Pre-flight Check

```powershell
az --version
az login
az account show --output table
```

If multiple subscriptions:
```powershell
az account list --output table
az account set --subscription "<your-dev-subscription-id-or-name>"
```

---

## Step 1 — Create the Resource Group

```powershell
az group create `
  --name rg-vg-lab-wus-01 `
  --location westus `
  --tags owner=vg env=lab purpose=networking
```

**Verify:**
```powershell
az group show --name rg-vg-lab-wus-01 --output table
```
Expected: `ProvisioningState: Succeeded`

---

## Step 2 — Create the Hub VNet and Subnets

**Create hub VNet with GatewaySubnet:**
```powershell
az network vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-hub `
  --address-prefix 172.22.0.0/20 `
  --subnet-name GatewaySubnet `
  --subnet-prefix 172.22.0.0/27 `
  --tags owner=vg env=lab purpose=networking
```

**Add AzureFirewallSubnet:**
```powershell
az network vnet subnet create `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name AzureFirewallSubnet `
  --address-prefix 172.22.1.0/26
```

**Add SharedServicesSubnet:**
```powershell
az network vnet subnet create `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name snet-vg-lab-wus-shared `
  --address-prefix 172.22.2.0/24
```

**Add PrivateEndpointSubnet:**
```powershell
az network vnet subnet create `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name snet-vg-lab-wus-pe `
  --address-prefix 172.22.3.0/24
```

**Verify:**
```powershell
az network vnet subnet list `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --output table
```
Expected: 4 subnets — GatewaySubnet, AzureFirewallSubnet, snet-vg-lab-wus-shared, snet-vg-lab-wus-pe

---

## Step 3 — Create Spoke VNets

**Spoke 1:**
```powershell
az network vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-spoke1 `
  --address-prefix 172.22.16.0/20 `
  --subnet-name snet-vg-lab-wus-spoke1-workload `
  --subnet-prefix 172.22.16.0/24 `
  --tags owner=vg env=lab purpose=networking
```

**Spoke 2:**
```powershell
az network vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-spoke2 `
  --address-prefix 172.22.32.0/20 `
  --subnet-name snet-vg-lab-wus-spoke2-workload `
  --subnet-prefix 172.22.32.0/24 `
  --tags owner=vg env=lab purpose=networking
```

**Verify:**
```powershell
az network vnet list `
  --resource-group rg-vg-lab-wus-01 `
  --output table
```
Expected: 3 VNets — hub, spoke1, spoke2

---

## Step 4 — Establish VNet Peering

Peering is bidirectional but requires two separate objects — one on each side.

**Hub → Spoke1:**
```powershell
az network vnet peering create `
  --resource-group rg-vg-lab-wus-01 `
  --name peer-vg-lab-wus-hub-to-spoke1 `
  --vnet-name vnet-vg-lab-wus-hub `
  --remote-vnet vnet-vg-lab-wus-spoke1 `
  --allow-vnet-access true
```

**Spoke1 → Hub:**
```powershell
az network vnet peering create `
  --resource-group rg-vg-lab-wus-01 `
  --name peer-vg-lab-wus-spoke1-to-hub `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --remote-vnet vnet-vg-lab-wus-hub `
  --allow-vnet-access true
```

**Hub → Spoke2:**
```powershell
az network vnet peering create `
  --resource-group rg-vg-lab-wus-01 `
  --name peer-vg-lab-wus-hub-to-spoke2 `
  --vnet-name vnet-vg-lab-wus-hub `
  --remote-vnet vnet-vg-lab-wus-spoke2 `
  --allow-vnet-access true
```

**Spoke2 → Hub:**
```powershell
az network vnet peering create `
  --resource-group rg-vg-lab-wus-01 `
  --name peer-vg-lab-wus-spoke2-to-hub `
  --vnet-name vnet-vg-lab-wus-spoke2 `
  --remote-vnet vnet-vg-lab-wus-hub `
  --allow-vnet-access true
```

**Verify:**
```powershell
az network vnet peering list `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --output table
```
Expected: 2 peerings from hub side, both `PeeringState: Connected`

---

## Challenge — Spoke-to-Spoke Direct Peering

Attempt a direct spoke1↔spoke2 peering — it succeeds (no overlapping CIDRs) but is architecturally wrong for hub-spoke:

```powershell
az network vnet peering create `
  --resource-group rg-vg-lab-wus-01 `
  --name peer-vg-lab-wus-spoke1-to-spoke2 `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --remote-vnet vnet-vg-lab-wus-spoke2 `
  --allow-vnet-access true
```

Delete it immediately — we don't want direct spoke-to-spoke peering:

```powershell
az network vnet peering delete `
  --resource-group rg-vg-lab-wus-01 `
  --name peer-vg-lab-wus-spoke1-to-spoke2 `
  --vnet-name vnet-vg-lab-wus-spoke1
```

**Why delete it?** In a hub-spoke topology all inter-spoke traffic must route through the hub Firewall/NVA for central inspection. Direct peering bypasses this entirely.

---

## Key Observations from This Lab

1. **Peering requires two objects** — one on each side. Creating only one side results in `Initiated` state, not `Connected`
2. **Azure rejects overlapping CIDRs at peering creation** — enforcement is at the platform level, not just a best practice
3. **Direct spoke peering is technically possible** — Azure won't stop you. Architecture discipline is on you.
4. **Reserved subnet names are enforced** — `GatewaySubnet` and `AzureFirewallSubnet` must be named exactly — Azure services look for these specific strings

---

## Teardown

**Do not tear down** — this foundation persists across all 7 topics.

If you need to rebuild from scratch:
```powershell
az group delete --name rg-vg-lab-wus-01 --yes --no-wait
```
Then re-run this lab from Step 1. Rebuild takes ~10 minutes.