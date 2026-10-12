resource "azurerm_virtual_network_gateway" "hub" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  name                = "${local.vpngw_name}-hub"
  type                = "Vpn"
  sku                 = "VpnGw1AZ"
  vpn_type            = "RouteBased"
  active_active       = false
  enable_bgp          = true
  ip_configuration {
    subnet_id                     = data.terraform_remote_state.base.outputs.gateway_subnet_id
    public_ip_address_id          = azurerm_public_ip.hub_vpngw.id
    private_ip_address_allocation = "Dynamic"
  }
  bgp_settings {
    asn = 65010
  }
}

resource "azurerm_virtual_network_gateway" "onprem" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  name                = "${local.vpngw_name}-onprem"
  type                = "Vpn"
  sku                 = "VpnGw1AZ"
  vpn_type            = "RouteBased"
  active_active       = false
  enable_bgp          = true
  ip_configuration {
    subnet_id                     = azurerm_subnet.onprem_gateway.id
    public_ip_address_id          = azurerm_public_ip.onprem_vpngw.id
    private_ip_address_allocation = "Dynamic"
  }
  bgp_settings {
    asn = 65000
  }
}
