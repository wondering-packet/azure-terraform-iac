output "lb_name" {
  value = azurerm_lb.lb.name
}

output "lb_id" {
  value = azurerm_lb.lb.id
}

output "lb_feip_address" {
  value = azurerm_lb.lb.frontend_ip_configuration[0].private_ip_address
}

output "lb_be_pool_name" {
  value = azurerm_lb_backend_address_pool.be_pool.name
}

output "lb_be_pool_id" {
  value = azurerm_lb_backend_address_pool.be_pool.id
}

output "lb_probe_name" {
  value = azurerm_lb_probe.probe.name
}
output "lb_probe_id" {
  value = azurerm_lb_probe.probe.id
}
