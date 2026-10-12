locals {
  prefix                = trimprefix(var.agw_name, "agw-")
  feip_conf_name        = "agw-feip-conf-${local.prefix}"
  fe_port_name          = "agw-fe-port-${local.prefix}"
  http_listener_name    = "agw-http-listener-${local.prefix}"
  be_address_pool_name  = "agw-be-address-pool-${local.prefix}"
  be_http_settings_name = "agw-be-http-settings-${local.prefix}"
  probe_name            = "agw-probe-${local.prefix}"
  req_routing_rule_name = "agw-req-routing-rule-${local.prefix}"
  gwip_conf_name        = "agw-gwip-conf-${local.prefix}"
}
resource "azurerm_public_ip" "agw_pip" {
  resource_group_name = var.rg_name
  location            = var.location
  allocation_method   = var.pip.allocation_method
  name                = var.pip.name
  sku                 = "Standard"

  tags = var.tags
}

resource "azurerm_application_gateway" "agw" {
  resource_group_name = var.rg_name
  location            = var.location
  name                = var.agw_name

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = local.gwip_conf_name
    subnet_id = var.gateway_ip_configuration.subnet_id
  }

  frontend_ip_configuration {
    name                 = local.feip_conf_name
    public_ip_address_id = azurerm_public_ip.agw_pip.id
  }

  frontend_port {
    name = local.fe_port_name
    port = 80
  }

  backend_address_pool {
    name         = local.be_address_pool_name
    ip_addresses = var.backend_address_pool.ip_addresses
  }

  backend_http_settings {
    name                                = local.be_http_settings_name
    protocol                            = "Http"
    port                                = 80
    request_timeout                     = 60
    cookie_based_affinity               = "Disabled"
    pick_host_name_from_backend_address = true
  }

  http_listener {
    name                           = local.http_listener_name
    frontend_ip_configuration_name = local.feip_conf_name
    frontend_port_name             = local.fe_port_name
    protocol                       = "Http"
  }

  probe {
    name                                      = local.probe_name
    interval                                  = "15"
    path                                      = "/"
    protocol                                  = "Http"
    timeout                                   = "10"
    unhealthy_threshold                       = "3"
    pick_host_name_from_backend_http_settings = true
  }

  request_routing_rule {
    name                       = local.req_routing_rule_name
    rule_type                  = "Basic"
    http_listener_name         = local.http_listener_name
    backend_address_pool_name  = local.be_address_pool_name
    backend_http_settings_name = local.be_http_settings_name
    priority                   = 100
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  tags = var.tags

}
