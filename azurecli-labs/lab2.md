# Lab 2 — UDRs & Forced Tunneling

**Topic:** User Defined Routes & Forced Tunneling
**Cost:** ~$0.05 — one B1s VM for connectivity testing, deallocated after
**Estimated time:** 30-40 minutes
**Persistent:** Route tables yes. VM no — deallocated after lab.

---

## Topology Built

```
rt-vg-lab-wus-spoke1 → snet-vg-lab-wus-spoke1-workload
  0.0.0.0/0        → VirtualAppliance → 172.22.1.4  (BGP propagation: off)
  192.168.100.0/24 → None (blackhole)

rt-vg-lab-wus-spoke2 → snet-vg-lab-wus-spoke2-workload
  0.0.0.0/0        → VirtualAppliance → 172.22.1.4  (BGP propagation: off)

rt-vg-lab-wus-gw → GatewaySubnet
  172.22.16.0/20   → VirtualAppliance → 172.22.1.4  (BGP propagation: on)
  172.22.32.0/20   → VirtualAppliance → 172.22.1.4
```

**NVA placeholder IP:** `172.22.1.4` — first usable IP in `AzureFirewallSubnet` (`172.22.1.0/26`). Azure Firewall always takes `.4` in its subnet. Routes point here now, actual Firewall deployed in Topic 6.

---

## Prerequisites

Lab 1 complete — hub + spokes + peering must exist.

Quick state check:
```powershell
az network vnet list `
  --resource-group rg-vg-lab-wus-01 `
  --output table
```
Expected: 3 VNets — hub, spoke1, spoke2.

---

## Step 1 — Create Route Tables

```powershell
az network route-table create `
  --resource-group rg-vg-lab-wus-01 `
  --name rt-vg-lab-wus-spoke1 `
  --location westus `
  --disable-bgp-route-propagation true `
  --tags owner=vg env=lab purpose=networking

az network route-table create `
  --resource-group rg-vg-lab-wus-01 `
  --name rt-vg-lab-wus-spoke2 `
  --location westus `
  --disable-bgp-route-propagation true `
  --tags owner=vg env=lab purpose=networking

az network route-table create `
  --resource-group rg-vg-lab-wus-01 `
  --name rt-vg-lab-wus-gw `
  --location westus `
  --disable-bgp-route-propagation false `
  --tags owner=vg env=lab purpose=networking
```

**Why BGP propagation off on spokes?**
- You want explicit UDR control — no surprises from BGP-learned routes
- A BGP-learned on-prem route could be more specific than your UDR and silently win via LPM, bypassing the Firewall without you knowing

**Why BGP propagation on for GatewaySubnet?**
- The gateway needs full route awareness to advertise spoke prefixes back to on-prem correctly when VPN Gateway is deployed in Topic 5

**Verify:**
```powershell
az network route-table list `
  --resource-group rg-vg-lab-wus-01 `
  --output table
```
Expected: 3 route tables listed.

---

## Step 2 — Add Routes

**Spoke1 default route:**
```powershell
az network route-table route create `
  --resource-group rg-vg-lab-wus-01 `
  --route-table-name rt-vg-lab-wus-spoke1 `
  --name route-vg-lab-default `
  --address-prefix 0.0.0.0/0 `
  --next-hop-type VirtualAppliance `
  --next-hop-ip-address 172.22.1.4
```

**Spoke2 default route:**
```powershell
az network route-table route create `
  --resource-group rg-vg-lab-wus-01 `
  --route-table-name rt-vg-lab-wus-spoke2 `
  --name route-vg-lab-default `
  --address-prefix 0.0.0.0/0 `
  --next-hop-type VirtualAppliance `
  --next-hop-ip-address 172.22.1.4
```

**GatewaySubnet spoke1 route:**
```powershell
az network route-table route create `
  --resource-group rg-vg-lab-wus-01 `
  --route-table-name rt-vg-lab-wus-gw `
  --name route-vg-lab-spoke1 `
  --address-prefix 172.22.16.0/20 `
  --next-hop-type VirtualAppliance `
  --next-hop-ip-address 172.22.1.4
```

**GatewaySubnet spoke2 route:**
```powershell
az network route-table route create `
  --resource-group rg-vg-lab-wus-01 `
  --route-table-name rt-vg-lab-wus-gw `
  --name route-vg-lab-spoke2 `
  --address-prefix 172.22.32.0/20 `
  --next-hop-type VirtualAppliance `
  --next-hop-ip-address 172.22.1.4
```

**Verify all routes:**
```powershell
az network route-table route list `
  --resource-group rg-vg-lab-wus-01 `
  --route-table-name rt-vg-lab-wus-spoke1 `
  --output table

az network route-table route list `
  --resource-group rg-vg-lab-wus-01 `
  --route-table-name rt-vg-lab-wus-spoke2 `
  --output table

az network route-table route list `
  --resource-group rg-vg-lab-wus-01 `
  --route-table-name rt-vg-lab-wus-gw `
  --output table
```

---

## Step 3 — Associate Route Tables to Subnets

```powershell
az network vnet subnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name snet-vg-lab-wus-spoke1-workload `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --route-table rt-vg-lab-wus-spoke1

az network vnet subnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name snet-vg-lab-wus-spoke2-workload `
  --vnet-name vnet-vg-lab-wus-spoke2 `
  --route-table rt-vg-lab-wus-spoke2

az network vnet subnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name GatewaySubnet `
  --vnet-name vnet-vg-lab-wus-hub `
  --route-table rt-vg-lab-wus-gw
```

**Verify association** — look for `routeTable` object in output:
```powershell
az network vnet subnet show `
  --resource-group rg-vg-lab-wus-01 `
  --name snet-vg-lab-wus-spoke1-workload `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --query routeTable
```

**Note from lab output:** You'll also see `privateEndpointNetworkPolicies: Disabled` on every subnet by default — NSGs not enforced on PE traffic until explicitly enabled (covered in Topic 4).

---

## Step 4 — Deploy Test VM

```powershell
az vm create `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1 `
  --image Ubuntu2204 `
  --size Standard_B1s `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --subnet snet-vg-lab-wus-spoke1-workload `
  --public-ip-address '""' `
  --nsg '""' `
  --admin-username azureuser `
  --generate-ssh-keys `
  --no-wait `
  --tags owner=vg env=lab purpose=networking
```

**Check provisioning state:**
```powershell
az vm get-instance-view `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1 `
  --query instanceView.statuses[1].displayStatus `
  --output tsv
```
Wait for `VM running` before proceeding.

---

## Step 5 — View Effective Routes

**Get NIC name:**
```powershell
az vm show `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1 `
  --query networkProfile.networkInterfaces[0].id `
  --output tsv
```
NIC name is the last segment after the final `/`.

**View effective routes:**
```powershell
az network nic show-effective-route-table `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1VMNic `
  --output table
```

**Expected output:**
```
Source    State    Address Prefix    Next Hop Type      Next Hop IP
--------  -------  ----------------  -----------------  -------------
Default   Active   172.22.16.0/20    VnetLocal
Default   Active   172.22.0.0/20     VNetPeering
Default   Invalid  0.0.0.0/0         Internet
User      Active   0.0.0.0/0         VirtualAppliance   172.22.1.4
```

**Row by row analysis:**
- `172.22.16.0/20 → VnetLocal` — spoke1's own address space. Local traffic stays local.
- `172.22.0.0/20 → VNetPeering` — hub prefix auto-injected by Azure when peering was created.
- `0.0.0.0/0 → Internet (Invalid)` — system default internet route superseded by UDR. Azure keeps it visible but marks it Invalid.
- `0.0.0.0/0 → VirtualAppliance → 172.22.1.4` — your UDR. Active and winning.

**Why is spoke2's prefix (`172.22.32.0/20`) absent?**
Spoke1 only peers with the hub — it has no direct knowledge of spoke2's address space. Only the hub VNet prefix is injected as a peering route. Traffic to spoke2 matches `0.0.0.0/0` and goes to the NVA — correct hub-spoke behavior.

---

## Step 6 — Challenge: Blackhole Route

Add a route to silently drop all traffic to `192.168.100.0/24` from spoke1:

```powershell
az network route-table route create `
  --resource-group rg-vg-lab-wus-01 `
  --route-table-name rt-vg-lab-wus-spoke1 `
  --name route-vg-lab-drop `
  --address-prefix 192.168.100.0/24 `
  --next-hop-type None
```

**Verify in effective routes:**
```powershell
az network nic show-effective-route-table `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1VMNic `
  --output table
```

**Expected — 5 rows now:**
```
Source    State    Address Prefix    Next Hop Type      Next Hop IP
--------  -------  ----------------  -----------------  -------------
Default   Active   172.22.16.0/20    VnetLocal
Default   Active   172.22.0.0/20     VNetPeering
Default   Invalid  0.0.0.0/0         Internet
User      Active   192.168.100.0/24  None
User      Active   0.0.0.0/0         VirtualAppliance   172.22.1.4
```

`192.168.100.0/24 → None` — no Next Hop IP, silent drop confirmed. Note it appears before `0.0.0.0/0` because it is more specific — LPM ordering.

---

## Step 7 — Deallocate the VM

```powershell
az vm deallocate `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1 `
  --no-wait
```

**Verify deallocated:**
```powershell
az vm get-instance-view `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1 `
  --query instanceView.statuses[1].displayStatus `
  --output tsv
```
Expected: `VM deallocated`

**Why deallocate instead of delete?**
Deallocated = compute billing stops, disk and NIC preserved. We can start it again in Topic 6 for Firewall testing without recreating it.

---

## Key Observations from This Lab

1. **System route `Invalid` state** — when a UDR overrides a system route at equal prefix length, Azure marks the system route `Invalid` in effective routes. It stays visible for troubleshooting clarity.
2. **Spoke2 absent from spoke1 effective routes** — non-transitivity confirmed. Spoke1 only knows about hub via peering. Spoke2-bound traffic falls through to `0.0.0.0/0 → NVA`.
3. **`None` next hop = silent drop** — no Next Hop IP in output, no ICMP unreachable generated. Traffic disappears at fabric level.
4. **BGP propagation matters** — disabled on spokes (explicit UDR control), enabled on GatewaySubnet (full route awareness for VPN Gateway in Topic 5).
5. **Route tables are inert until associated** — creating a route table has zero effect until associated to a subnet via `az network vnet subnet update`.

---

## Teardown

**Keep:** Route tables and subnet associations — persistent across all topics.
**Deallocate:** VM — done in Step 7.
**Delete VM entirely** (optional, saves ~$0.10/day disk cost):
```powershell
az vm delete `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1 `
  --yes
```
If deleted, recreate in Topic 6 when needed for Firewall testing.