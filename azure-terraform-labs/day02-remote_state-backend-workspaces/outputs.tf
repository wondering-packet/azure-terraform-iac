output "vnet_id" {
  value       = azurerm_virtual_network.hub.id
  description = "Resource ID of the hub VNet"
  sensitive   = true
}

output "subnet_ids" {
  value       = { for k, v in azurerm_subnet.hub : k => v.id }
  description = "Map of subnet name to subnet resource ID"
}

output "vnet_address_space" {
  value       = azurerm_virtual_network.hub.address_space
  description = "Full address space owned by hub vnet"
}

output "vnet_primary_cidr" {
  value = azurerm_virtual_network.hub.address_space[0]
}
