output "pe_name" {
  value = azurerm_private_endpoint.pe.name
}
output "pe_id" {
  value = azurerm_private_endpoint.pe.id
}
output "psc_private_ip_address" {
  value = azurerm_private_endpoint.pe.private_service_connection[0].private_ip_address
}
