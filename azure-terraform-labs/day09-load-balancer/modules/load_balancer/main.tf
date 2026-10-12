resource "azurerm_lb" "lb" {
  name                = var.lb_name
  resource_group_name = var.rg_name
  location            = var.location
  sku                 = var.sku
  frontend_ip_configuration {
    name                          = var.frontend_ip_configuration.name
    subnet_id                     = var.frontend_ip_configuration.subnet_id
    private_ip_address            = var.frontend_ip_configuration.private_ip_address
    private_ip_address_allocation = var.frontend_ip_configuration.private_ip_address_allocation
    public_ip_address_id          = var.frontend_ip_configuration.public_ip_address_id
  }
}

resource "azurerm_lb_rule" "lb_rule" {
  name                           = var.lb_rule.name
  frontend_port                  = var.lb_rule.frontend_port
  backend_port                   = var.lb_rule.backend_port
  protocol                       = var.lb_rule.protocol
  frontend_ip_configuration_name = azurerm_lb.lb.frontend_ip_configuration[0].name
  loadbalancer_id                = azurerm_lb.lb.id
  probe_id                       = azurerm_lb_probe.probe.id
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.be_pool.id]
}

resource "azurerm_lb_backend_address_pool" "be_pool" {
  name            = var.lb_be_pool.name
  loadbalancer_id = azurerm_lb.lb.id
}

resource "azurerm_network_interface_backend_address_pool_association" "lb_be_nic_association" {
  backend_address_pool_id = azurerm_lb_backend_address_pool.be_pool.id
  for_each                = var.lb_be_nic_associations
  network_interface_id    = each.value.network_interface_id
  ip_configuration_name   = each.value.ip_configuration_name
}

resource "azurerm_lb_probe" "probe" {
  name            = var.lb_probe.name
  loadbalancer_id = azurerm_lb.lb.id
  port            = var.lb_probe.port
  protocol        = var.lb_probe.protocol
  request_path    = var.lb_probe.protocol == "Tcp" ? null : var.lb_probe.request_path
}
