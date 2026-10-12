resource "azurerm_local_network_gateway" "onprem" {
  name                = "${local.lng_name}-onprem"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  address_space       = ["${azurerm_virtual_network_gateway.onprem.bgp_settings[0].peering_addresses[0].default_addresses[0]}/32"]
  gateway_address     = azurerm_public_ip.onprem_vpngw.ip_address
  bgp_settings {
    asn                 = 65000
    bgp_peering_address = azurerm_virtual_network_gateway.onprem.bgp_settings[0].peering_addresses[0].default_addresses[0]
  }
}

resource "azurerm_local_network_gateway" "hub" {
  name                = "${local.lng_name}-hub"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  address_space       = ["${azurerm_virtual_network_gateway.hub.bgp_settings[0].peering_addresses[0].default_addresses[0]}/32"]
  gateway_address     = azurerm_public_ip.hub_vpngw.ip_address
  bgp_settings {
    asn                 = 65010
    bgp_peering_address = azurerm_virtual_network_gateway.hub.bgp_settings[0].peering_addresses[0].default_addresses[0]
  }
}
