output "snet_id" {
  value = azurerm_subnet.snet.id
}

output "address_prefixes" {
  value = azurerm_subnet.snet.address_prefixes
}
