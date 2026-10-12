output "p1_p2_peering_id" {
  value = azurerm_virtual_network_peering.p1_p2_peering.id
}

output "p2_p1_peering_id" {
  value = azurerm_virtual_network_peering.p2_p1_peering.id
}
