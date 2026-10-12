# Azure CLI — Networking Command Reference

A worked command reference distilled from the seven hands-on CLI labs in this folder. Every
example uses the **real lab values** (resource names, CIDRs, SKUs, ASNs) so you can read a
command and immediately see what each argument does in context. Swap in your own subscription,
region, and naming as needed.

- **Shell:** Windows PowerShell — line continuation is the backtick `` ` ``, never `\`.
- **Subscription:** replace `<your-subscription-id>` with your own. (The labs ran in a
  subscription named *Infrastructure Networking Dev/Test*.)
- **Region:** `westus` throughout.
- **Resource group:** `rg-vg-lab-wus-01`.
- **Naming convention:** `<resource-type>-vg-lab-wus-<purpose>` — e.g. `vnet-vg-lab-wus-hub`.
  (`vg` is the owner tag in a shared subscription; `lab` the environment; `wus` the region.)
- **Supernet:** `172.22.0.0/16` — Hub `172.22.0.0/20`, Spoke1 `172.22.16.0/20`,
  Spoke2 `172.22.32.0/20`, on-prem sim `172.22.64.0/20`.
- **Standard tag block used on most creates:** `--tags owner=vg env=lab purpose=networking`.

> Reserved subnet names Azure enforces by exact string: `GatewaySubnet` (VPN/ER gateway),
> `AzureFirewallSubnet` (Azure Firewall). They must be named exactly — Azure services look
> for these literals.

---

## 1. Authentication & subscription context

```powershell
az --version
az login
az account show --output table

# When you have more than one subscription
az account list --output table
az account set --subscription "<your-subscription-id>"
```

Service-principal login (used by CI and the Terraform track):

```powershell
az login --service-principal `
  --username <client-id> `
  --password <client-secret> `
  --tenant <tenant-id>
```

> **Corporate TLS inspection (e.g. Zscaler):** if `az extension add` fails on an SSL error,
> disable connection verification **for the lab session only** — never in production:
> ```powershell
> $env:AZURE_CLI_DISABLE_CONNECTION_VERIFICATION = "1"
> # ...run the extension install...
> Remove-Item Env:\AZURE_CLI_DISABLE_CONNECTION_VERIFICATION
> ```

---

## 2. Resource groups

```powershell
az group create `
  --name rg-vg-lab-wus-01 `
  --location westus `
  --tags owner=vg env=lab purpose=networking

az group show --name rg-vg-lab-wus-01 --output table     # expect ProvisioningState: Succeeded
az group list --output table

# Full teardown (async). Rebuilding the foundation takes ~10 minutes.
az group delete --name rg-vg-lab-wus-01 --yes --no-wait
```

---

## 3. Virtual networks & subnets

Create a VNet and its first subnet in one call:

```powershell
az network vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-hub `
  --address-prefix 172.22.0.0/20 `
  --subnet-name GatewaySubnet `
  --subnet-prefix 172.22.0.0/27 `
  --tags owner=vg env=lab purpose=networking
```

Add more subnets to an existing VNet:

```powershell
az network vnet subnet create `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name AzureFirewallSubnet `
  --address-prefix 172.22.1.0/26

az network vnet subnet create `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name snet-vg-lab-wus-shared `
  --address-prefix 172.22.2.0/24
```

Spoke VNet with its workload subnet inline:

```powershell
az network vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-spoke1 `
  --address-prefix 172.22.16.0/20 `
  --subnet-name snet-vg-lab-wus-spoke1-workload `
  --subnet-prefix 172.22.16.0/24 `
  --tags owner=vg env=lab purpose=networking
```

Delegate a subnet to a service (here, the DNS Private Resolver):

```powershell
az network vnet subnet create `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name snet-vg-lab-wus-dns-inbound `
  --address-prefix 172.22.4.0/24 `
  --delegations Microsoft.Network/dnsResolvers
```

Set custom DNS servers on a VNet (and the reset gotcha):

```powershell
az network vnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-spoke1 `
  --dns-servers 172.22.4.4

# Revert to Azure-provided DNS — use the literal null, NOT an empty string
az network vnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-spoke1 `
  --dns-servers null
```

Inspect:

```powershell
az network vnet list --resource-group rg-vg-lab-wus-01 --output table
az network vnet subnet list `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub --output table
az network vnet subnet show `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name GatewaySubnet `
  --query "{prefix:addressPrefix, routeTable:routeTable.id}" --output json
```

> `--dns-servers ""` fails with `NetcfgInvalidIPAddress`. Use `null`.
> `privateEndpointNetworkPolicies` shows as `Disabled` on every subnet by default — relevant
> later for Private Endpoints (section 7).

---

## 4. VNet peering (hub-spoke)

Peering is **bidirectional but needs two objects — one per side.** One side alone leaves the
peering in `Initiated`, not `Connected`.

```powershell
# Hub -> Spoke1
az network vnet peering create `
  --resource-group rg-vg-lab-wus-01 `
  --name peer-vg-lab-wus-hub-to-spoke1 `
  --vnet-name vnet-vg-lab-wus-hub `
  --remote-vnet vnet-vg-lab-wus-spoke1 `
  --allow-vnet-access true

# Spoke1 -> Hub
az network vnet peering create `
  --resource-group rg-vg-lab-wus-01 `
  --name peer-vg-lab-wus-spoke1-to-hub `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --remote-vnet vnet-vg-lab-wus-hub `
  --allow-vnet-access true
```

Update the transit flags (needed once a VPN gateway or firewall enters the hub):

```powershell
# On the HUB side of each spoke peering — let spokes use the hub's gateway and cross it
az network vnet peering update `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name peer-vg-lab-wus-hub-to-spoke1 `
  --set allowGatewayTransit=true

# On the SPOKE side — consume the remote (hub) gateway
az network vnet peering update `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --name peer-vg-lab-wus-spoke1-to-hub `
  --set useRemoteGateways=true

# Allow the hub firewall to forward spoke-to-spoke traffic (set on all peerings)
az network vnet peering update `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name peer-vg-lab-wus-hub-to-spoke1 `
  --set allowForwardedTraffic=true

az network vnet peering list `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub --output table
```

> Peering is **non-transitive**: spoke1 learns only the hub's prefix, never spoke2's. Direct
> spoke-to-spoke peering is technically allowed by Azure but breaks hub-spoke inspection —
> route inter-spoke traffic through the hub NVA instead. `useRemoteGateways` must be `false`
> when inter-spoke traffic goes through the firewall (section 10), `true` when spokes should
> ride the hub VPN gateway (section 9) — the two labs flip it deliberately.

---

## 5. Route tables & user-defined routes (UDRs)

A route table is **inert until associated** to a subnet.

```powershell
# BGP propagation OFF on spokes (explicit UDR control), ON for GatewaySubnet (full awareness)
az network route-table create `
  --resource-group rg-vg-lab-wus-01 `
  --name rt-vg-lab-wus-spoke1 `
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

Add routes — forced-tunnel default route to the firewall NVA, and a blackhole:

```powershell
# Default route -> Azure Firewall private IP (172.22.1.4 = .4 of AzureFirewallSubnet)
az network route-table route create `
  --resource-group rg-vg-lab-wus-01 `
  --route-table-name rt-vg-lab-wus-spoke1 `
  --name route-vg-lab-default `
  --address-prefix 0.0.0.0/0 `
  --next-hop-type VirtualAppliance `
  --next-hop-ip-address 172.22.1.4

# Blackhole — silently drop a prefix (no next-hop IP)
az network route-table route create `
  --resource-group rg-vg-lab-wus-01 `
  --route-table-name rt-vg-lab-wus-spoke1 `
  --name route-vg-lab-drop `
  --address-prefix 192.168.100.0/24 `
  --next-hop-type None
```

Associate the route table to a subnet, then view **effective** routes on a NIC:

```powershell
az network vnet subnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name snet-vg-lab-wus-spoke1-workload `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --route-table rt-vg-lab-wus-spoke1

az network nic show-effective-route-table `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1VMNic --output table
```

> When a UDR overrides a system route at equal prefix length, Azure keeps the system route
> visible but marks it `Invalid`. `None` next-hop = silent drop (no ICMP unreachable).
> BGP-learned routes appear **only** in effective routes on a NIC — never in the portal's
> static route-table view. The VM must be **running** for `show-effective-route-table` to
> return usable output.

---

## 6. Azure DNS — private zones, links, records, Private Resolver

Private DNS zones are **global** — no `--location`.

```powershell
az network private-dns zone create `
  --resource-group rg-vg-lab-wus-01 `
  --name internal.lab.com `
  --tags owner=vg env=lab purpose=networking
```

Link VNets — hub with auto-registration, spokes resolution-only:

```powershell
az network private-dns link vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name internal.lab.com `
  --name pdnslink-vg-lab-hub `
  --virtual-network vnet-vg-lab-wus-hub `
  --registration-enabled true

az network private-dns link vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name internal.lab.com `
  --name pdnslink-vg-lab-spoke1 `
  --virtual-network vnet-vg-lab-wus-spoke1 `
  --registration-enabled false
```

Manual A record (spokes can't auto-register against a hub-owned zone):

```powershell
az network private-dns record-set a add-record `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name internal.lab.com `
  --record-set-name vm-vg-lab-wus-spoke1 `
  --ipv4-address 172.22.16.4

az network private-dns record-set a list `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name internal.lab.com
```

### DNS Private Resolver

Requires the `dns-resolver` extension and two delegated subnets (section 3).

```powershell
az extension add --name dns-resolver

$vnetId = az network vnet show `
  --resource-group rg-vg-lab-wus-01 `
  --name vnet-vg-lab-wus-hub --query id --output tsv

az dns-resolver create `
  --resource-group rg-vg-lab-wus-01 `
  --name dnsresolver-vg-lab-wus `
  --location westus `
  --id $vnetId `
  --tags owner=vg env=lab purpose=networking

# Inbound endpoint — gets 172.22.4.4; this is the IP spokes/on-prem forward queries to
az dns-resolver inbound-endpoint create `
  --resource-group rg-vg-lab-wus-01 `
  --dns-resolver-name dnsresolver-vg-lab-wus `
  --name inbound-vg-lab-wus `
  --location westus `
  --ip-configurations "[{privateIpAllocationMethod:'Dynamic',id:'/subscriptions/<your-subscription-id>/resourceGroups/rg-vg-lab-wus-01/providers/Microsoft.Network/virtualNetworks/vnet-vg-lab-wus-hub/subnets/snet-vg-lab-wus-dns-inbound'}]"

# Outbound endpoint — no IP; internal egress only
az dns-resolver outbound-endpoint create `
  --resource-group rg-vg-lab-wus-01 `
  --dns-resolver-name dnsresolver-vg-lab-wus `
  --name outbound-vg-lab-wus `
  --location westus `
  --id "/subscriptions/<your-subscription-id>/resourceGroups/rg-vg-lab-wus-01/providers/Microsoft.Network/virtualNetworks/vnet-vg-lab-wus-hub/subnets/snet-vg-lab-wus-dns-outbound"
```

Forwarding ruleset + rule + link to the hub VNet:

```powershell
az dns-resolver forwarding-ruleset create `
  --resource-group rg-vg-lab-wus-01 `
  --name fwruleset-vg-lab-wus `
  --location westus `
  --outbound-endpoints "[{id:'/subscriptions/<your-subscription-id>/resourceGroups/rg-vg-lab-wus-01/providers/Microsoft.Network/dnsResolvers/dnsresolver-vg-lab-wus/outboundEndpoints/outbound-vg-lab-wus'}]"

az dns-resolver forwarding-rule create `
  --resource-group rg-vg-lab-wus-01 `
  --ruleset-name fwruleset-vg-lab-wus `
  --name fwrule-vg-lab-test `
  --domain-name "fakedomain.internal." `
  --forwarding-rule-state Enabled `
  --target-dns-servers "[{ipAddress:'8.8.8.8',port:53}]"

az dns-resolver vnet-link create `
  --resource-group rg-vg-lab-wus-01 `
  --ruleset-name fwruleset-vg-lab-wus `
  --name vnetlink-vg-lab-hub `
  --id "/subscriptions/<your-subscription-id>/resourceGroups/rg-vg-lab-wus-01/providers/Microsoft.Network/virtualNetworks/vnet-vg-lab-wus-hub"
```

> **Teardown order is enforced** (out-of-order returns `BadRequest`):
> forwarding rules → ruleset VNet links → ruleset → outbound endpoint → inbound endpoint →
> resolver. Forwarding-rule domain names need a **trailing dot** (`fakedomain.internal.`).
> The ruleset does nothing until linked to the hub VNet. Resolution links on spokes become
> **redundant** once spokes point their DNS at the inbound endpoint — pick one pattern.

---

## 7. Service Endpoints & Private Endpoints

### Service Endpoint (public IP + subnet trust claim)

```powershell
az network vnet subnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name snet-vg-lab-wus-spoke1-workload `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --service-endpoints Microsoft.Storage

# Storage account — policy here forces --allow-blob-public-access false
az storage account create `
  --resource-group rg-vg-lab-wus-01 `
  --name stvglabwus01 `
  --location westus `
  --sku Standard_LRS `
  --kind StorageV2 `
  --allow-blob-public-access false `
  --tags owner=vg env=lab purpose=networking

az storage account network-rule add `
  --resource-group rg-vg-lab-wus-01 `
  --account-name stvglabwus01 `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --subnet snet-vg-lab-wus-spoke1-workload

az storage account update `
  --resource-group rg-vg-lab-wus-01 `
  --name stvglabwus01 `
  --default-action Deny
```

### Private Endpoint (private IP + DNS override)

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

# Note the assigned private IP (172.22.3.4 — .4 of the PE subnet)
az network private-endpoint show `
  --resource-group rg-vg-lab-wus-01 `
  --name pe-vg-lab-wus-storage `
  --query customDnsConfigs --output json
```

Private DNS for the PE (the `privatelink.*` zone + A record + links):

```powershell
az network private-dns zone create `
  --resource-group rg-vg-lab-wus-01 `
  --name privatelink.blob.core.windows.net `
  --tags owner=vg env=lab purpose=networking

az network private-dns record-set a add-record `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name privatelink.blob.core.windows.net `
  --record-set-name stvglabwus01 `
  --ipv4-address 172.22.3.4

az network private-dns link vnet create `
  --resource-group rg-vg-lab-wus-01 `
  --zone-name privatelink.blob.core.windows.net `
  --name pdnslink-vg-lab-blob-spoke1 `
  --virtual-network vnet-vg-lab-wus-spoke1 `
  --registration-enabled false
```

> **PaaS firewall rules only apply to internet-originated traffic.** Traffic reaching a
> storage account over a Private Endpoint from a peered VNet bypasses `defaultAction: Deny`
> entirely — the **NSG on the PE subnet** is the only effective control for internal traffic,
> and only once `privateEndpointNetworkPolicies` is `Enabled` (section 8). `--group-id`
> scopes the PE to one sub-resource (blob/file/queue/table) — each needs its own PE and its
> own `privatelink.*` zone. Same-tenant PE connections auto-approve.

---

## 8. Network Security Groups (NSGs)

```powershell
az network nsg create `
  --resource-group rg-vg-lab-wus-01 `
  --name nsg-vg-lab-wus-hub-pe `
  --location westus `
  --tags owner=vg env=lab purpose=networking

# Allow spoke1 to the PE subnet
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

# Explicit deny-all BELOW Azure's default AllowVnetInBound (priority 65000)
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

# Enable PE network policies AND attach the NSG in one update
az network vnet subnet update `
  --resource-group rg-vg-lab-wus-01 `
  --name snet-vg-lab-wus-pe `
  --vnet-name vnet-vg-lab-wus-hub `
  --private-endpoint-network-policies Enabled `
  --network-security-group nsg-vg-lab-wus-hub-pe

az network nsg rule list `
  --resource-group rg-vg-lab-wus-01 `
  --nsg-name nsg-vg-lab-wus-hub-pe --output table
```

> Azure's default `AllowVnetInBound` (priority 65000) lets **all** peered-VNet traffic in.
> Without an explicit deny at a lower number (here 4096), spoke2 reaches the PE despite your
> spoke1-only allow rule. NSG priorities are per-direction. Azure warns the deny blocks the
> `AzureLoadBalancer`/`VirtualNetwork` tags — harmless on a PE-only subnet.

---

## 9. VPN Gateway, Local Network Gateways, BGP

Public IPs must be **Standard SKU, static** for AZ gateway SKUs:

```powershell
az network public-ip create `
  --resource-group rg-vg-lab-wus-01 `
  --name pip-vg-lab-wus-vpngw `
  --location westus `
  --sku Standard `
  --allocation-method Static `
  --tags owner=vg env=lab purpose=networking
```

Deploy the gateway (`--no-wait`; provisioning is 25–45 min). Hub and on-prem need
**different ASNs**:

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

# Poll until Succeeded and the BGP peering address is populated
az network vnet-gateway show `
  --resource-group rg-vg-lab-wus-01 `
  --name vpngw-vg-lab-wus-hub `
  --query "{state:provisioningState, bgpAsn:bgpSettings.asn, bgpPeeringAddress:bgpSettings.bgpPeeringAddress}" `
  --output json
```

Local Network Gateways represent the *other* side. With BGP, you only need the peer's BGP
address as a `/32`:

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

Connections (both directions, BGP enabled, matching shared key):

```powershell
az network vpn-connection create `
  --resource-group rg-vg-lab-wus-01 `
  --name conn-vg-lab-wus-hub-to-onprem `
  --vnet-gateway1 vpngw-vg-lab-wus-hub `
  --local-gateway2 lng-vg-lab-wus-onprem `
  --shared-key <shared-key> `
  --enable-bgp `
  --location westus `
  --tags owner=vg env=lab purpose=networking
```

Verify BGP route exchange:

```powershell
az network vnet-gateway list-advertised-routes `
  --resource-group rg-vg-lab-wus-01 `
  --name vpngw-vg-lab-wus-hub `
  --peer 172.22.64.30 --output table

az network vnet-gateway list-learned-routes `
  --resource-group rg-vg-lab-wus-01 `
  --name vpngw-vg-lab-wus-hub --output table
```

> **BGP runs inside the IPsec tunnel on private IPs** — point the LNG at the peer's BGP
> peering address (`172.22.0.30` / `172.22.64.30`), not the public IP. The public IP is only
> for IKE/IPsec establishment. **ASN 65515 is reserved by Azure** and can't be used in an
> LNG — the hub here uses 65010. AZ SKUs (`VpnGw1AZ`) are mandatory for new gateways.
> Spokes only advertise via BGP once `allowGatewayTransit=true` (hub peering) **and**
> `useRemoteGateways=true` (spoke peering) are set. Deletion order:
> connections → gateways (15–20 min) → LNGs → public IPs.

---

## 10. Azure Firewall & Firewall Policy

Install the extension, then build policy before the firewall:

```powershell
az extension add --name azure-firewall

az network public-ip create `
  --resource-group rg-vg-lab-wus-01 `
  --name pip-vg-lab-wus-fw `
  --location westus --sku Standard --allocation-method Static `
  --tags owner=vg env=lab purpose=networking

az network firewall policy create `
  --resource-group rg-vg-lab-wus-01 `
  --name fwpol-vg-lab-wus `
  --location westus --sku Standard `
  --tags owner=vg env=lab purpose=networking
```

Deploy the firewall, then attach the IP config separately (the reliable two-step in this
lab; step 3b takes ~30 min):

```powershell
az network firewall create `
  --resource-group rg-vg-lab-wus-01 `
  --name fw-vg-lab-wus-hub `
  --location westus `
  --firewall-policy fwpol-vg-lab-wus `
  --tags owner=vg env=lab purpose=networking

az network firewall ip-config create `
  --resource-group rg-vg-lab-wus-01 `
  --firewall-name fw-vg-lab-wus-hub `
  --name fwipconf-vg-lab-wus `
  --public-ip-address pip-vg-lab-wus-fw `
  --vnet-name vnet-vg-lab-wus-hub

az network firewall show `
  --resource-group rg-vg-lab-wus-01 `
  --name fw-vg-lab-wus-hub `
  --query "{state:provisioningState, privateIp:ipConfigurations[0].privateIPAddress}" `
  --output json
```

Rule collection group → filter collections → rules:

```powershell
az network firewall policy rule-collection-group create `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --name fwrcg-vg-lab-wus-main `
  --priority 100

# Network allow collection (creates the collection AND its first rule)
az network firewall policy rule-collection-group collection add-filter-collection `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rule-collection-group-name fwrcg-vg-lab-wus-main `
  --name fwnetcol-vg-lab-wus-allow `
  --collection-priority 100 --action Allow `
  --rule-type NetworkRule --rule-name allow-spoke1-to-pe `
  --source-addresses 172.22.16.0/24 `
  --destination-addresses 172.22.3.4 `
  --destination-ports 443 --ip-protocols TCP

# Add another rule to an existing collection — space-separated CIDRs
az network firewall policy rule-collection-group collection rule add `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rcg-name fwrcg-vg-lab-wus-main `
  --collection-name fwnetcol-vg-lab-wus-allow `
  --rule-type NetworkRule --name allow-spoke2-to-rfc1918 `
  --source-addresses 172.22.32.0/24 `
  --destination-addresses 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 `
  --destination-ports "*" --ip-protocols Any

# Application allow collection — apex AND wildcard FQDN both required
az network firewall policy rule-collection-group collection add-filter-collection `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rule-collection-group-name fwrcg-vg-lab-wus-main `
  --name fwappcol-vg-lab-wus-allow `
  --collection-priority 200 --action Allow `
  --rule-type ApplicationRule --rule-name allow-spoke1-to-github `
  --source-addresses 172.22.16.0/24 `
  --target-fqdns "github.com" "*.github.com" `
  --protocols https=443
```

DNAT (publishes an internal host via the firewall's public IP; implicitly allowed):

```powershell
az network firewall policy rule-collection-group collection add-nat-collection `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rcg-name fwrcg-vg-lab-wus-main `
  --collection-priority 150 `
  --name fwnatcol-vg-lab-wus --rule-name dnat-ssh-spoke1 `
  --destination-addresses 104.42.37.52 `
  --source-addresses <your-public-ip> `
  --translated-address 172.22.16.4 --translated-port 22 `
  --destination-ports 2222 --ip-protocols TCP

# There is no `rule list` subcommand — show the whole RCG to see rules
az network firewall policy rule-collection-group show `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --name fwrcg-vg-lab-wus-main --output json
```

Diagnostics to Log Analytics (set up while the firewall provisions):

```powershell
az monitor log-analytics workspace create `
  --resource-group rg-vg-lab-wus-01 `
  --workspace-name law-vg-lab-wus --location westus `
  --tags owner=vg env=lab purpose=networking

$lawId = az monitor log-analytics workspace show -g rg-vg-lab-wus-01 --workspace-name law-vg-lab-wus --query id -o tsv
$fwId  = az network firewall show -g rg-vg-lab-wus-01 --name fw-vg-lab-wus-hub --query id -o tsv
$logs = '[{"category":"AzureFirewallApplicationRule","enabled":true},{"category":"AzureFirewallNetworkRule","enabled":true},{"category":"AzureFirewallDnsProxy","enabled":true}]'
$metrics = '[{"category":"AllMetrics","enabled":true}]'

az monitor diagnostic-settings create `
  --name diag-fw-vg-lab-wus `
  --resource $fwId --workspace $lawId `
  --logs $logs --metrics $metrics
```

KQL for rule hits (run in the `law-vg-lab-wus` workspace):

```kusto
AzureDiagnostics
| where Category in ("AzureFirewallNetworkRule", "AzureFirewallApplicationRule")
| where TimeGenerated > ago(15m)
| project TimeGenerated, Category, msg_s
| order by TimeGenerated desc
```

> **Rule type beats collection priority:** the entire DNAT pass runs, then all network
> rules, then all application rules — so a network rule in RCG priority 500 is evaluated
> before an application rule in RCG priority 100. **Rules have no action** — Allow/Deny lives
> on the collection. Priority namespaces are per rule type. Use **space-separated** CIDRs
> (comma-separated silently failed to match). `*.github.com` does **not** cover the apex
> `github.com` — list both. Denied HTTPS returns a TCP RST after Client Hello (looks like an
> SSL EOF, not a TLS fault). Firewall is ~$1.25/hr — tear down after use.

---

## 11. Load balancing — Internal LB and Application Gateway

### Internal Load Balancer (ILB) with HA Ports

```powershell
az network lb create `
  --resource-group rg-vg-lab-wus-01 `
  --name ilb-vg-lab-wus-hub --location westus --sku Standard `
  --vnet-name vnet-vg-lab-wus-hub --subnet snet-vg-lab-wus-shared `
  --frontend-ip-name feip-vg-lab-wus-ilb `
  --private-ip-address 172.22.2.100 `
  --backend-pool-name bepool-vg-lab-wus-ilb `
  --tags owner=vg env=lab purpose=networking

az network lb probe create `
  --resource-group rg-vg-lab-wus-01 `
  --lb-name ilb-vg-lab-wus-hub `
  --name probe-vg-lab-wus-http --protocol Http --port 80 --path /

# HA Ports: frontend/backend port 0 + protocol All = every port, every protocol (ILB only)
az network lb rule create `
  --resource-group rg-vg-lab-wus-01 `
  --lb-name ilb-vg-lab-wus-hub `
  --name rule-vg-lab-wus-haports `
  --protocol All --frontend-port 0 --backend-port 0 `
  --frontend-ip-name feip-vg-lab-wus-ilb `
  --backend-pool-name bepool-vg-lab-wus-ilb `
  --probe-name probe-vg-lab-wus-http

# Add VMs to the pool by NIC ip-config
az network nic ip-config address-pool add `
  --resource-group rg-vg-lab-wus-01 `
  --nic-name vm-vg-lab-wus-hub1VMNic `
  --ip-config-name ipconfigvm-vg-lab-wus-hub1 `
  --lb-name ilb-vg-lab-wus-hub `
  --address-pool bepool-vg-lab-wus-ilb
```

### Application Gateway (v2)

```powershell
az network vnet subnet create `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name snet-vg-lab-wus-agw --address-prefix 172.22.6.0/24

az network public-ip create `
  --resource-group rg-vg-lab-wus-01 `
  --name pip-vg-lab-wus-agw --location westus --sku Standard --allocation-method Static `
  --tags owner=vg env=lab purpose=networking

az network application-gateway create `
  --resource-group rg-vg-lab-wus-01 `
  --name agw-vg-lab-wus-hub --location westus `
  --sku Standard_v2 --capacity 1 `
  --vnet-name vnet-vg-lab-wus-hub --subnet snet-vg-lab-wus-agw `
  --public-ip-address pip-vg-lab-wus-agw `
  --frontend-port 80 --http-settings-port 80 --http-settings-protocol Http `
  --routing-rule-type Basic --priority 100 --no-wait `
  --tags owner=vg env=lab purpose=networking

az network application-gateway address-pool update `
  --resource-group rg-vg-lab-wus-01 `
  --gateway-name agw-vg-lab-wus-hub `
  --name appGatewayBackendPool `
  --servers 172.22.2.5 172.22.2.6

az network application-gateway show-backend-health `
  --resource-group rg-vg-lab-wus-01 `
  --name agw-vg-lab-wus-hub --output json
```

> **AGW needs a dedicated subnet** (nothing else in it). HA Ports is **ILB-only**. Default
> failover: ILB ~30s (2 probes × 15s), AGW ~90s (3 probes × 30s) — tune an AGW custom probe
> (`--interval 10 --threshold 2`) for ~20s. Standard LB has no clean CLI health view — use
> the portal or the `DipAvailability` metric (100 healthy / 0 unhealthy). Distribution is a
> 5-tuple hash; a single client may stick to one backend — expected, not a fault.

---

## 12. VM & Bastion helpers (lab testing)

Disposable test VM — no public IP, no default NSG (reach it via Bastion):

```powershell
az vm create `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1 `
  --image Ubuntu2204 --size Standard_B1s `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --subnet snet-vg-lab-wus-spoke1-workload `
  --public-ip-address '""' --nsg '""' `
  --admin-username azureuser --generate-ssh-keys --no-wait `
  --tags owner=vg env=lab purpose=networking

# Bastion Developer SKU is free but password-only and cannot cross VNet peering
az network bastion create `
  --resource-group rg-vg-lab-wus-01 `
  --name bastion-vg-lab-wus-spoke1 `
  --vnet-name vnet-vg-lab-wus-spoke1 --sku Developer --location westus

# Developer SKU has no SSH-key support — set a password before connecting
az vm user update `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-spoke1 `
  --username azureuser --password '<set-a-strong-password>'
```

Lifecycle and lookups:

```powershell
az vm deallocate -g rg-vg-lab-wus-01 --name vm-vg-lab-wus-spoke1 --no-wait   # stops billing, keeps disk/NIC
az vm start      -g rg-vg-lab-wus-01 --name vm-vg-lab-wus-spoke1
az vm restart    -g rg-vg-lab-wus-01 --name vm-vg-lab-wus-spoke1 --no-wait   # e.g. to pick up new DNS

az vm get-instance-view `
  --resource-group rg-vg-lab-wus-01 --name vm-vg-lab-wus-spoke1 `
  --query instanceView.statuses[1].displayStatus --output tsv

az vm list-ip-addresses `
  --resource-group rg-vg-lab-wus-01 --name vm-vg-lab-wus-hub1 `
  --query "[].virtualMachine.network.privateIpAddresses" --output tsv

# NIC name = last segment of this id; pattern is usually <vm-name>VMNic
az vm show -g rg-vg-lab-wus-01 --name vm-vg-lab-wus-spoke1 `
  --query networkProfile.networkInterfaces[0].id --output tsv
```

> Deallocate (don't delete) between labs: compute billing stops, disk and NIC survive, you
> restart later. Auto-registered DNS A records disappear when a VM is deallocated — keep the
> hub VM running if spokes must resolve it, or use manual A records.

---

## 13. Query & output patterns

```powershell
--output table    # human-readable columns
--output tsv      # single values for $vars / scripting
--output json     # full object

# JMESPath projections
--query "{state:provisioningState, ip:ipConfigurations[0].privateIPAddress}"
--query "[?contains(name, 'hub1')].name"
--query serviceEndpoints
```

Capture a value into a PowerShell variable:

```powershell
$lawId = az monitor log-analytics workspace show `
  -g rg-vg-lab-wus-01 --workspace-name law-vg-lab-wus --query id --output tsv
```

---

## Quick gotcha index

- **Peering needs both sides** — one side alone sits in `Initiated`, not `Connected`.
- **Peering is non-transitive** — spoke1 never learns spoke2; route via the hub.
- **Route table is inert until associated** to a subnet.
- **UDR override marks the system route `Invalid`** (still shown, for clarity).
- **BGP-learned routes show only in a NIC's effective routes**, never the portal RT view.
- **VM must be running** for `show-effective-route-table`.
- **`--dns-servers null`**, never `""` (which errors `NetcfgInvalidIPAddress`).
- **Resolver teardown is order-enforced**; forwarding-rule domains need a trailing dot.
- **PaaS firewall rules don't apply to Private Endpoint / internal traffic** — use the PE-subnet NSG.
- **`privateEndpointNetworkPolicies` defaults to `Disabled`** — NSG silently unenforced until `Enabled`.
- **Default `AllowVnetInBound` (65000)** lets peered VNets in — add an explicit deny below it.
- **BGP peers on private IPs inside the tunnel** — LNG points at the BGP address, not the public IP.
- **ASN 65515 is reserved** by Azure — unusable in an LNG.
- **Firewall rule type beats collection priority** — DNAT → network → application passes.
- **Firewall rules carry no action** — Allow/Deny is on the collection.
- **Space-separated CIDRs** in firewall rules (comma-separated silently fails to match).
- **`*.domain` excludes the apex** — add both `domain` and `*.domain`.
- **No firewall `rule list`** subcommand — `rule-collection-group show`.
- **HA Ports is ILB-only**; AGW needs a dedicated subnet.
- **Bastion Developer SKU** is password-only and can't traverse peering.
- **Deallocate ≠ delete** — keep disks/NICs; deallocation drops auto-registered DNS records.
