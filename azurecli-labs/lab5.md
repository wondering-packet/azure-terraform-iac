# Lab 5 — VPN Gateway & Hybrid Connectivity

**Topic:** VPN Gateway, Site-to-Site VPN, BGP, Local Network Gateways
**Cost:** ~$5 for two VpnGw1AZ gateways for ~2 hours — tear down same session.
**Estimated time:** ~1.5 hours (mostly waiting for gateway provisioning)
**Persistent:** vnet-vg-lab-wus-onprem VNet — free, keep. Everything else torn down.

---

## Subscription

**Subscription name:** Infrastructure Networking Dev/Test
**Subscription ID:** `<your-subscription-id>`

---

## Topology Built

```
Hub VNet (172.22.0.0/20)
  └── GatewaySubnet (172.22.0.0/27)
        └── vpngw-vg-lab-wus-hub
              ├── Public IP: 13.83.221.39
              ├── ASN: 65010
              └── BGP Peer IP: 172.22.0.30

"On-prem" VNet (172.22.64.0/20) — simulates on-prem
  └── GatewaySubnet (172.22.64.0/27)
        └── vpngw-vg-lab-wus-onprem
              ├── Public IP: 52.241.6.137
              ├── ASN: 65000
              └── BGP Peer IP: 172.22.64.30

Local Network Gateways:
  lng-vg-lab-wus-onprem — in hub context, represents on-prem
  lng-vg-lab-wus-hub    — in on-prem context, represents hub

Connections:
  conn-vg-lab-wus-hub-to-onprem — hub → on-prem (BGP enabled)
  conn-vg-lab-wus-onprem-to-hub — on-prem → hub (BGP enabled)

BGP learned routes (on-prem gateway):
  172.22.0.0/20  — hub VNet (eBGP from 172.22.0.30, AS 65010)
  172.22.16.0/20 — spoke1  (eBGP from 172.22.0.30, AS 65010)
  172.22.32.0/20 — spoke2  (eBGP from 172.22.0.30, AS 65010)
```

---

## Prerequisites

Labs 1-4 complete. Verify foundation:
```powershell
az network vnet list `
  --resource-group rg-vg-lab-wus-01 `
  --output table
```

GatewaySubnet must exist in hub VNet — verify:
```powershell
az network vnet subnet show `
  --resource-group rg-vg-lab-wus-01 `
  --name GatewaySubnet `
  --vnet-name vnet-vg-lab-wus-hub `
  --query "{prefix:addressPrefix, routeTable:routeTable.id}" `
  --output json
```

VMs and Bastion: see Lab 3 for detailed instructions.

---

## Step 1 — Create Public IPs

Standard SKU required for VpnGw AZ SKUs.

```powershell
# Hub gateway public IP
az network public-ip create `
  --resource-group rg-vg-lab-wus-01 `
  --name pip-vg-lab-wus-vpngw `
  --location westus `
  --sku Standard `
  --allocation-method Static `
  --tags owner=vg env=lab purpose=networking

# On-prem gateway public IP
az network public-ip create `
  --resource-group rg-vg-lab-wus-01 `
  --name pip-vg-lab-wus-vpngw-onprem `
  --location westus `
  --sku Standard `
  --allocation-method Static `
  --tags owner=vg env=lab purpose=networking
```

Note both IPs — needed for LNG creation later:
```powershell
az network public-ip show -g rg-vg-lab-wus-01 --name pip-vg-lab-wus-vpngw --query ipAddress --output tsv
az network public-ip show -g rg-vg-lab-wus-01 --name pip-vg-lab-wus-vpngw-onprem --query ipAddress --output tsv
```

---

## Step 2 — Create "On-Prem" VNet

Using a second Azure VNet to simulate on-prem — gives a real IKE/IPsec negotiation and BGP session for testing. In production you'd never VPN between two Azure VNets in the same region — use peering instead.

```powershell
az network vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-onprem `
  --address-prefix 172.22.64.0/20 `
  --subnet-name GatewaySubnet `
  --subnet-prefix 172.22.64.0/27 `
  --location westus `
  --tags owner=vg env=lab purpose=networking

az network vnet subnet create `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-onprem `
  --name snet-vg-lab-wus-onprem-workload `
  --address-prefix 172.22.65.0/24
```

---

## Step 3 — Deploy Both VPN Gateways

**Fire both off simultaneously — provisioning takes 25-45 minutes.**

**Hub gateway:**
```powershell
az network vnet-gateway create `
  --resource-group rg-vg-lab-wus-01 `
  --name vpngw-vg-lab-wus-hub `
  --location westus `
  --vnet vnet-vg-lab-wus-hub `
  --gateway-type Vpn `
  --vpn-type RouteBased `
  --sku VpnGw1AZ `
  --public-ip-addresses pip-vg-lab-wus-vpngw `
  --asn 65010 `
  --no-wait `
  --tags owner=vg env=lab purpose=networking
```

**On-prem gateway:**
```powershell
az network vnet-gateway create `
  --resource-group rg-vg-lab-wus-01 `
  --name vpngw-vg-lab-wus-onprem `
  --location westus `
  --vnet vnet-vg-lab-wus-onprem `
  --gateway-type Vpn `
  --vpn-type RouteBased `
  --sku VpnGw1AZ `
  --public-ip-addresses pip-vg-lab-wus-vpngw-onprem `
  --asn 65000 `
  --no-wait `
  --tags owner=vg env=lab purpose=networking
```

**Important notes:**
- `--vpn-type RouteBased` — required for BGP and modern VPN configs. Policy-based is legacy.
- `--sku VpnGw1AZ` — AZ SKU mandatory as of Nov 2025. Non-AZ SKUs can no longer be created.
- Hub uses ASN `65010`, on-prem uses `65000` — **must be different**. ASN `65515` is reserved by Azure and cannot be used in Local Network Gateways.

**Check provisioning status (poll every few minutes):**
```powershell
az network vnet-gateway show `
  --resource-group rg-vg-lab-wus-01 `
  --name vpngw-vg-lab-wus-hub `
  --query "{state:provisioningState, bgpAsn:bgpSettings.asn, bgpPeeringAddress:bgpSettings.bgpPeeringAddress}" `
  --output json

az network vnet-gateway show `
  --resource-group rg-vg-lab-wus-01 `
  --name vpngw-vg-lab-wus-onprem `
  --query "{state:provisioningState, bgpAsn:bgpSettings.asn, bgpPeeringAddress:bgpSettings.bgpPeeringAddress}" `
  --output json
```

Wait for both to show `Succeeded` and `bgpPeeringAddress` populated before proceeding. Note both BGP peering addresses — needed for LNG creation.

---

## Step 4 — Create Local Network Gateways

**Only create after both gateways show `Succeeded`** — LNGs need the actual BGP peering addresses which are only assigned after provisioning.

**Why BGP peering addresses and not public IPs:**
BGP runs inside the IPsec tunnel using private IPs — not over the public IPs. Public IPs are used only for IKE/IPsec tunnel establishment. Azure VPN Gateway initiates BGP sessions to the peer's private BGP peering address, not the public IP. Common misconfiguration: pointing BGP at the public IP instead of the BGP peer IP from GatewaySubnet.

**Why `/32` in `--local-address-prefixes`:**
With BGP enabled, you only need the BGP peer IP as a `/32` host route to bootstrap the BGP session. Once BGP is up it dynamically advertises all real prefixes. Without BGP you'd need to list all on-prem CIDRs here as static routes.

**⚠️ Replace the IPs below with the actual values from your deployment:**
- `13.83.221.39` → hub gateway public IP (from Step 1)
- `52.241.6.137` → on-prem gateway public IP (from Step 1)
- `172.22.0.30` → hub BGP peering address (from Step 3)
- `172.22.64.30` → on-prem BGP peering address (from Step 3)

**LNG for hub (created for on-prem gateway — represents hub):**
```powershell
az network local-gateway create `
  --resource-group rg-vg-lab-wus-01 `
  --name lng-vg-lab-wus-hub `
  --location westus `
  --gateway-ip-address 13.83.221.39 `
  --local-address-prefixes 172.22.0.30/32 `
  --asn 65010 `
  --bgp-peering-address 172.22.0.30 `
  --tags owner=vg env=lab purpose=networking
```

**LNG for on-prem (created for hub gateway — represents on-prem):**
```powershell
az network local-gateway create `
  --resource-group rg-vg-lab-wus-01 `
  --name lng-vg-lab-wus-onprem `
  --location westus `
  --gateway-ip-address 52.241.6.137 `
  --local-address-prefixes 172.22.64.30/32 `
  --asn 65000 `
  --bgp-peering-address 172.22.64.30 `
  --tags owner=vg env=lab purpose=networking
```

---

## Step 5 — Create Connection Objects

```powershell
# Hub → on-prem
az network vpn-connection create `
  --resource-group rg-vg-lab-wus-01 `
  --name conn-vg-lab-wus-hub-to-onprem `
  --vnet-gateway1 vpngw-vg-lab-wus-hub `
  --local-gateway2 lng-vg-lab-wus-onprem `
  --shared-key Azure123! `
  --enable-bgp `
  --location westus `
  --tags owner=vg env=lab purpose=networking

# On-prem → hub
az network vpn-connection create `
  --resource-group rg-vg-lab-wus-01 `
  --name conn-vg-lab-wus-onprem-to-hub `
  --vnet-gateway1 vpngw-vg-lab-wus-onprem `
  --local-gateway2 lng-vg-lab-wus-hub `
  --shared-key Azure123! `
  --enable-bgp `
  --location westus `
  --tags owner=vg env=lab purpose=networking
```

**Check connection status (wait 2-3 minutes):**
```powershell
az network vpn-connection list `
  --resource-group rg-vg-lab-wus-01 `
  --query "[].{name:name, status:connectionStatus, bgp:enableBgp}" `
  --output table
```

Note: `connectionStatus` may not render in table output — verify via portal if needed. Look for `Connected` status in portal under each connection.

---

## Step 6 — Enable Gateway Transit for Spoke Advertising

By default Azure VPN Gateway only advertises directly connected VNet prefixes. Peered spoke prefixes are not advertised unless gateway transit is enabled.

**Enable Allow Gateway Transit on hub peerings:**
```powershell
az network vnet peering update `
  --resource-group rg-vg-lab-wus-01 `
  --name peer-vg-lab-wus-hub-to-spoke1 `
  --vnet-name vnet-vg-lab-wus-hub `
  --set allowGatewayTransit=true

az network vnet peering update `
  --resource-group rg-vg-lab-wus-01 `
  --name peer-vg-lab-wus-hub-to-spoke2 `
  --vnet-name vnet-vg-lab-wus-hub `
  --set allowGatewayTransit=true
```

**Enable Use Remote Gateways on spoke peerings:**
```powershell
az network vnet peering update `
  --resource-group rg-vg-lab-wus-01 `
  --name peer-vg-lab-wus-spoke1-to-hub `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --set useRemoteGateways=true

az network vnet peering update `
  --resource-group rg-vg-lab-wus-01 `
  --name peer-vg-lab-wus-spoke2-to-hub `
  --vnet-name vnet-vg-lab-wus-spoke2 `
  --set useRemoteGateways=true
```

---

## Step 7 — Verify BGP Route Exchange

**Routes hub gateway is advertising to on-prem:**
```powershell
az network vnet-gateway list-advertised-routes `
  --resource-group rg-vg-lab-wus-01 `
  --name vpngw-vg-lab-wus-hub `
  --peer 172.22.64.30 `
  --output table
```

Expected after enabling gateway transit:
```
Network         NextHop      Origin    AsPath
--------------  -----------  --------  ------
172.22.0.0/20   172.22.0.30  Igp       65010
172.22.16.0/20  172.22.0.30  Igp       65010
172.22.32.0/20  172.22.0.30  Igp       65010
```

**Routes hub gateway has learned from on-prem:**
```powershell
az network vnet-gateway list-learned-routes `
  --resource-group rg-vg-lab-wus-01 `
  --name vpngw-vg-lab-wus-hub `
  --output table
```

Expected:
```
Network          NextHop       Origin    SourcePeer    AsPath
---------------  ------------  --------  ------------  ------
172.22.0.0/20                  Network   172.22.0.30
172.22.64.30/32                Network   172.22.0.30
172.22.64.0/20   172.22.64.30  EBgp      172.22.64.30  65000
172.22.16.0/20                 Network   172.22.0.30
172.22.32.0/20                 Network   172.22.0.30
```

**Verify BGP propagation to hub VM:**

**Note: hub VM must be running for this command to return usable output.**

```powershell
az vm start --resource-group rg-vg-lab-wus-01 --name vm-vg-lab-wus-hub

az network nic show-effective-route-table `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-hubVMNic `
  --output table
```

Expected: `172.22.64.0/20` with source `VirtualNetworkGateway` and next hop = hub gateway public IP.

**Why spoke VMs don't see on-prem routes:**
BGP propagation is disabled on spoke route tables (`--disable-bgp-route-propagation true` set in Lab 2). By design — spoke traffic to on-prem goes via UDR → Firewall → hub → VPN Gateway, not directly. This keeps inspection in the path.

**Note:** BGP-learned routes are NOT visible in the route table's static routes view in the portal. They only appear in effective routes on a NIC. The portal route table view shows only manually created UDRs.

---

## Teardown

**Delete in strict order — connections → gateways → LNGs → public IPs.**

**Gateway deletion takes 15-20 minutes** — wait for gateways to fully delete before running LNG and public IP deletes.

```powershell
# 1. Delete connections
az network vpn-connection delete `
  --resource-group rg-vg-lab-wus-01 `
  --name conn-vg-lab-wus-hub-to-onprem

az network vpn-connection delete `
  --resource-group rg-vg-lab-wus-01 `
  --name conn-vg-lab-wus-onprem-to-hub

# 2. Delete gateways
az network vnet-gateway delete `
  --resource-group rg-vg-lab-wus-01 `
  --name vpngw-vg-lab-wus-hub `
  --no-wait

az network vnet-gateway delete `
  --resource-group rg-vg-lab-wus-01 `
  --name vpngw-vg-lab-wus-onprem `
  --no-wait

# Verify gateways deleted before proceeding (wait 15-20 minutes):
az network vnet-gateway list `
  --resource-group rg-vg-lab-wus-01 `
  --query "[].{name:name, state:provisioningState}" `
  --output table

# 3. Delete LNGs
az network local-gateway delete `
  --resource-group rg-vg-lab-wus-01 `
  --name lng-vg-lab-wus-hub

az network local-gateway delete `
  --resource-group rg-vg-lab-wus-01 `
  --name lng-vg-lab-wus-onprem

# 4. Delete public IPs
az network public-ip delete `
  --resource-group rg-vg-lab-wus-01 `
  --name pip-vg-lab-wus-vpngw

az network public-ip delete `
  --resource-group rg-vg-lab-wus-01 `
  --name pip-vg-lab-wus-vpngw-onprem
```

**Keep:** `vnet-vg-lab-wus-onprem` VNet + subnets — free, useful for future labs.

---

## Key Observations from This Lab

1. **VPN Gateway provisioning takes 25-45 minutes** — AZ SKUs take slightly longer than non-AZ. Fire off `--no-wait` and do other things while waiting.
2. **VPN Gateway deletion takes 15-20 minutes** — must fully delete before LNGs and public IPs can be removed.
3. **ASN 65515 is reserved by Azure** — cannot be used in Local Network Gateways. Use any other private ASN (64512-65534).
4. **BGP peer IPs are private, not public** — BGP session runs inside the IPsec tunnel using GatewaySubnet IPs. Common misconfiguration: pointing BGP at the public IP. LNG needs the private BGP peering address.
5. **LNG public IPs and BGP addresses must match actual deployed values** — note them after each gateway provisions, don't hardcode expected values.
6. **`/32` in LNG address prefixes with BGP** — only need the BGP peer IP as a host route to bootstrap the session. BGP dynamically advertises everything else.
7. **Gateway transit must be explicitly enabled** — peered spoke prefixes not advertised via BGP until `allowGatewayTransit=true` on hub peering AND `useRemoteGateways=true` on spoke peering.
8. **BGP-learned routes not visible in route table portal view** — portal shows only static UDRs. BGP-learned routes only visible in effective routes on a NIC.
9. **Hub VM must be running** for `show-effective-route-table` to return usable output.
10. **Hub VM (no route table) sees BGP routes** — `snet-vg-lab-wus-shared` has no route table so BGP propagation defaults to enabled. Spoke VMs don't see BGP routes because `rt-vg-lab-wus-spoke1/2` has BGP propagation disabled by design.
11. **VNet-to-VNet VPN uses IKEv2 by default** — shorter 4-message handshake vs IKEv1's 9 messages. Faster establishment and reconnection after failover.
12. **Deletion order strictly enforced** — connections → gateways → LNGs → public IPs. Out-of-order deletion fails.