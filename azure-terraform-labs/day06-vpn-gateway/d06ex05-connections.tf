resource "azurerm_virtual_network_gateway_connection" "gw_onprem_to_lng_hub" {
  resource_group_name        = data.azurerm_resource_group.main.name
  name                       = "${local.gw_conn_name}-onprem-to-hub"
  location                   = data.azurerm_resource_group.main.location
  virtual_network_gateway_id = azurerm_virtual_network_gateway.onprem.id
  local_network_gateway_id   = azurerm_local_network_gateway.hub.id
  type                       = "IPsec"
  shared_key                 = var.vpn_shared_key
  enable_bgp                 = true
}

resource "azurerm_virtual_network_gateway_connection" "gw_hub_to_lng_onprem" {
  resource_group_name        = data.azurerm_resource_group.main.name
  name                       = "${local.gw_conn_name}-hub-to-onprem"
  location                   = data.azurerm_resource_group.main.location
  virtual_network_gateway_id = azurerm_virtual_network_gateway.hub.id
  local_network_gateway_id   = azurerm_local_network_gateway.onprem.id
  type                       = "IPsec"
  shared_key                 = var.vpn_shared_key
  enable_bgp                 = true
}
