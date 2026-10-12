output "vnet_id" {
  value = azurerm_virtual_network.vnet.id
}

output "vnet_address_space" {
  value = azurerm_virtual_network.vnet.address_space
}

output "vnet_primary_cidr" {
  value = azurerm_virtual_network.vnet.address_space[0]
}

output "vnet_name" {
  value = azurerm_virtual_network.vnet.name
}

output "vnet_location" {
  value = azurerm_virtual_network.vnet.location
}
