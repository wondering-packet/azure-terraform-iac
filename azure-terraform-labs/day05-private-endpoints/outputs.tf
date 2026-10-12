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
  ###---d05ex05 >>>
  # updated value to follow new subnet variable design from d05ex05.
  value = azurerm_subnet.hub_gateway.id
  ###---d05ex05 <<<
  description = "Subnet ID of Gateway subnet in hub"
}

output "firewall_subnet_id" {
  ###---d05ex05 >>>
  # updated value to follow new subnet variable design from d05ex05.
  value = azurerm_subnet.hub_azurefirewall.id
  ###---d05ex05 <<<
  description = "Subnet ID of AzureFirewall subnet in hub"
}

output "pe_subnet_id" {
  ###---d05ex05 >>>
  # updated value to follow new subnet variable design from d05ex05.
  value = azurerm_subnet.hub_pe.id
  ###---d05ex05 <<<
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

###---d05ex06 >>>
output "storage_pe_id" {
  value       = azurerm_private_endpoint.lab_storage.id
  description = "id of storage PE in hub"
}
output "storage_pe_private_ip" {
  value       = azurerm_private_endpoint.lab_storage.private_service_connection[0].private_ip_address
  description = "ip address of storage PE in hub"
}
output "storage_account_id" {
  value       = azurerm_storage_account.lab.id
  description = "id of lab storage account hub"
}
output "storage_privatelink_zone_id" {
  value       = azurerm_private_dns_zone.lab_storage_pe.id
  description = "id of storage PE's privatelink dns zone"
}
###---d05ex06 <<<
