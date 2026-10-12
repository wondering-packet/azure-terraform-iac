###---d03ex05 >>>
output "hub_vnet_id" { # renamed from "vnet_id" to "hub_vnet_id"
  value       = azurerm_virtual_network.hub.id
  description = "Resource ID of the hub VNet"
}

output "hub_subnet_ids" { # renamed from "subnet_ids" to "hub_subnet_ids"
  value       = { for k, v in azurerm_subnet.hub : k => v.id }
  description = "Map of subnet name to subnet resource ID in hub"
}

output "gateway_subnet_id" {
  value       = azurerm_subnet.hub_reserved["GatewaySubnet"].id
  description = "Subnet ID of Gateway subnet in hub"
}

output "firewall_subnet_id" {
  value       = azurerm_subnet.hub_reserved["AzureFirewallSubnet"].id
  description = "Subnet ID of AzureFirewall subnet in hub"
}

output "pe_subnet_id" {
  value       = azurerm_subnet.hub["pe"].id
  description = "Subnet ID of snet-vg-lab-wus-pe subnet in hub"
}

output "agw_subnet_id" {
  value       = azurerm_subnet.hub["agw"].id
  description = "Subnet ID of snet-vg-lab-wus-agw subnet in hub"
}

output "dns_inbound_subnet_id" {
  value       = azurerm_subnet.hub["dns-inbound"].id
  description = "Subnet ID of snet-vg-lab-wus-dns-inbound subnet in hub"
}

output "dns_outbound_subnet_id" {
  value       = azurerm_subnet.hub["dns-outbound"].id
  description = "Subnet ID of snet-vg-lab-wus-dns-outbound subnet in hub"
}

output "spoke1_vnet_id" {
  value       = azurerm_virtual_network.spoke1.id
  description = "Resource ID of the spoke1 VNet"
}

output "spoke1_workload_subnet_id" {
  value       = azurerm_subnet.spoke1.id
  description = "Map of subnet name to subnet resource ID in spoke1"
}

output "spoke2_vnet_id" {
  value       = azurerm_virtual_network.spoke2.id
  description = "Resource ID of the spoke2 VNet"
}

output "spoke2_workload_subnet_id" {
  value       = azurerm_subnet.spoke2.id
  description = "Map of subnet name to subnet resource ID in spoke2"
}
###---d03ex05 <<<

output "vnet_address_space" {
  value       = azurerm_virtual_network.hub.address_space
  description = "Full address space owned by hub vnet"
}

output "vnet_primary_cidr" {
  value = azurerm_virtual_network.hub.address_space[0]
}

###---d04ex06 >>>

output "route_table_ids" {
  value = {
    gw     = azurerm_route_table.rt_gateway.id,
    spoke1 = azurerm_route_table.rt_spoke1.id,
    spoke2 = azurerm_route_table.rt_spoke2.id
  }
}

###---d04ex06 <<<
