# IP Schema & Address Allocation Summary

**Lab environment:** Infrastructure Networking Dev/Test
**Subscription ID:** `<your-subscription-id>`
**Region:** West US (`westus`)
**Resource Group:** `rg-vg-lab-wus-01`
**Naming convention:** `<resource-type>-vg-lab-wus-<purpose>`

---

## Supernet

| Range | Purpose |
|---|---|
| `172.22.0.0/16` | Overall lab address space |

---

## VNet Allocations

| VNet | CIDR | Purpose |
|---|---|---|
| `vnet-vg-lab-wus-hub` | `172.22.0.0/20` | Hub VNet — shared services, firewall, gateways |
| `vnet-vg-lab-wus-spoke1` | `172.22.16.0/20` | Spoke 1 |
| `vnet-vg-lab-wus-spoke2` | `172.22.32.0/20` | Spoke 2 |
| `vnet-vg-lab-wus-onprem` | `172.22.64.0/20` | Simulated on-prem (Lab 5) |
| *(reserved)* | `172.22.48.0/20` | Spoke 3 if needed |

---

## Hub VNet Subnets (`172.22.0.0/20`)

| Subnet | CIDR | Purpose | Special |
|---|---|---|---|
| `GatewaySubnet` | `172.22.0.0/27` | VPN Gateway / ExpressRoute Gateway | Reserved name — Azure behavior |
| `AzureFirewallSubnet` | `172.22.1.0/26` | Azure Firewall | Reserved name — Azure behavior |
| `snet-vg-lab-wus-shared` | `172.22.2.0/24` | Hub shared services, ILB, test VMs | No route table |
| `snet-vg-lab-wus-pe` | `172.22.3.0/24` | Private Endpoints | NSG + `privateEndpointNetworkPolicies` enabled |
| `snet-vg-lab-wus-dns-inbound` | `172.22.4.0/24` | Private Resolver inbound endpoint | Delegated: `Microsoft.Network/dnsResolvers` |
| `snet-vg-lab-wus-dns-outbound` | `172.22.5.0/24` | Private Resolver outbound endpoint | Delegated: `Microsoft.Network/dnsResolvers` |
| `snet-vg-lab-wus-agw` | `172.22.6.0/24` | Application Gateway | Dedicated — no other resources |

---

## Spoke VNet Subnets

| Subnet | CIDR | VNet | Route Table |
|---|---|---|---|
| `snet-vg-lab-wus-spoke1-workload` | `172.22.16.0/24` | spoke1 | `rt-vg-lab-wus-spoke1` |
| `snet-vg-lab-wus-spoke2-workload` | `172.22.32.0/24` | spoke2 | `rt-vg-lab-wus-spoke2` |

---

## On-Prem Sim VNet Subnets (`172.22.64.0/20`)

| Subnet | CIDR | Purpose |
|---|---|---|
| `GatewaySubnet` | `172.22.64.0/27` | VPN Gateway (Lab 5) |
| `snet-vg-lab-wus-onprem-workload` | `172.22.65.0/24` | On-prem workload simulation |

---

## Static / Reserved IP Assignments

**Note on dynamic IPs:** IPs marked as dynamic were the addresses received during this lab. They may differ when resources are redeployed. Always verify actual assigned IPs after provisioning before using them in rules, UDRs, or LNG configurations.

| IP | Resource | Subnet | Allocation | Notes |
|---|---|---|---|---|
| `172.22.1.4` | `fw-vg-lab-wus-hub` | `AzureFirewallSubnet` | Dynamic | Received in lab — verify after redeploy |
| `172.22.2.4` | `vm-vg-lab-wus-hub` | `snet-vg-lab-wus-shared` | Dynamic | Received in lab — verify after redeploy |
| `172.22.2.5` | `vm-vg-lab-wus-hub1` | `snet-vg-lab-wus-shared` | Dynamic | Received in lab — verify after redeploy |
| `172.22.2.6` | `vm-vg-lab-wus-hub2` | `snet-vg-lab-wus-shared` | Dynamic | Received in lab — verify after redeploy |
| `172.22.2.100` | `ilb-vg-lab-wus-hub` | `snet-vg-lab-wus-shared` | Static | Explicitly configured — stable across redeployments |
| `172.22.3.4` | `pe-vg-lab-wus-storage` | `snet-vg-lab-wus-pe` | Dynamic | Received in lab — verify after redeploy |
| `172.22.4.4` | Private Resolver inbound endpoint | `snet-vg-lab-wus-dns-inbound` | Dynamic | Received in lab — verify after redeploy |
| `172.22.16.4` | `vm-vg-lab-wus-spoke1` | `snet-vg-lab-wus-spoke1-workload` | Dynamic | Received in lab — verify after redeploy |
| `172.22.32.4` | `vm-vg-lab-wus-spoke2` | `snet-vg-lab-wus-spoke2-workload` | Dynamic | Received in lab — verify after redeploy |
| `172.22.0.30` | `vpngw-vg-lab-wus-hub` BGP peer IP | `GatewaySubnet` | Dynamic | Received in lab — verify after redeploy |
| `172.22.64.30` | `vpngw-vg-lab-wus-onprem` BGP peer IP | on-prem `GatewaySubnet` | Dynamic | Received in lab — verify after redeploy |

---

## Public IP Assignments

**Note:** All public IPs below were received during this lab with static allocation. If the public IP resources are deleted and recreated, new IPs will be assigned. Update any rules referencing these IPs (e.g. DNAT destination, LNG gateway IP) after redeploy.

| Resource | Public IP | Used in Lab |
|---|---|---|
| `pip-vg-lab-wus-fw` | `104.42.37.52` | Lab 6 — Azure Firewall |
| `pip-vg-lab-wus-agw` | `20.59.115.57` | Lab 7 — Application Gateway |
| `pip-vg-lab-wus-vpngw` | `13.83.221.39` | Lab 5 — Hub VPN Gateway |
| `pip-vg-lab-wus-vpngw-onprem` | `52.241.6.137` | Lab 5 — On-prem VPN Gateway |

---

## BGP ASN Assignments

| Resource | ASN | Notes |
|---|---|---|
| `vpngw-vg-lab-wus-hub` | `65010` | Hub VPN Gateway. Originally 65515 but Azure reserves 65515 — cannot use in Local Network Gateways |
| `vpngw-vg-lab-wus-onprem` | `65000` | On-prem simulated VPN Gateway |

---

## Route Tables

### `rt-vg-lab-wus-spoke1` — attached to `snet-vg-lab-wus-spoke1-workload`

| Route Name | Address Prefix | Next Hop Type | Next Hop IP |
|---|---|---|---|
| `route-vg-lab-default` | `0.0.0.0/0` | VirtualAppliance | `172.22.1.4` |
| `route-vg-lab-pe` | `172.22.3.0/24` | VirtualAppliance | `172.22.1.4` |

BGP propagation: disabled

### `rt-vg-lab-wus-spoke2` — attached to `snet-vg-lab-wus-spoke2-workload`

| Route Name | Address Prefix | Next Hop Type | Next Hop IP |
|---|---|---|---|
| `route-vg-lab-default` | `0.0.0.0/0` | VirtualAppliance | `172.22.1.4` |

BGP propagation: disabled

### `rt-vg-lab-wus-gw` — attached to `GatewaySubnet`

| Route Name | Address Prefix | Next Hop Type | Next Hop IP |
|---|---|---|---|
| `route-vg-lab-spoke1` | `172.22.16.0/20` | VirtualAppliance | `172.22.1.4` |
| `route-vg-lab-spoke2` | `172.22.32.0/20` | VirtualAppliance | `172.22.1.4` |

BGP propagation: enabled

---

## Private DNS Zones

| Zone | Registration VNet | Resolution VNets | Purpose |
|---|---|---|---|
| `internal.lab.com` | hub | spoke1, spoke2 | VM hostname resolution across hub-spoke |
| `privatelink.blob.core.windows.net` | — | hub, spoke1, spoke2 | Storage Private Endpoint DNS override |

---

## NSG Assignments

| NSG | Subnet | Key Rules |
|---|---|---|
| `nsg-vg-lab-wus-hub-pe` | `snet-vg-lab-wus-pe` | AllowSpoke1 (priority 100), DenyAll (priority 4096). `privateEndpointNetworkPolicies: Enabled` |

---

## VNet Peerings

| Peering | From | To | Gateway Transit | Forwarded Traffic |
|---|---|---|---|---|
| `peer-vg-lab-wus-hub-to-spoke1` | hub | spoke1 | `allowGatewayTransit: true` | `allowForwardedTraffic: true` |
| `peer-vg-lab-wus-hub-to-spoke2` | hub | spoke2 | `allowGatewayTransit: true` | `allowForwardedTraffic: true` |
| `peer-vg-lab-wus-spoke1-to-hub` | spoke1 | hub | `useRemoteGateways: false` | `allowForwardedTraffic: true` |
| `peer-vg-lab-wus-spoke2-to-hub` | spoke2 | hub | `useRemoteGateways: false` | `allowForwardedTraffic: true` |

---

## Address Space — Available Ranges

| Range | Status |
|---|---|
| `172.22.7.0/24` through `172.22.15.0/24` | Available in hub VNet |
| `172.22.17.0/24` through `172.22.31.0/24` | Available in spoke1 VNet |
| `172.22.33.0/24` through `172.22.47.0/24` | Available in spoke2 VNet |
| `172.22.48.0/20` | Unallocated — available for spoke3 |
| `172.22.66.0/24` through `172.22.79.0/24` | Available in on-prem sim VNet |