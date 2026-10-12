resource "azurerm_virtual_network_peering" "p1_p2_peering" {
  resource_group_name          = var.rg_name
  name                         = var.p1_p2_peering_name
  virtual_network_name         = var.p1_vnet_name
  remote_virtual_network_id    = var.p2_vnet_id
  allow_virtual_network_access = var.allow_virtual_network_access_on_p1
  allow_forwarded_traffic      = var.allow_forwarded_traffic_on_p1
  allow_gateway_transit        = var.allow_gateway_transit_on_p1
  use_remote_gateways          = var.use_remote_gateways_on_p1
}

resource "azurerm_virtual_network_peering" "p2_p1_peering" {
  resource_group_name          = var.rg_name
  name                         = var.p2_p1_peering_name
  virtual_network_name         = var.p2_vnet_name
  remote_virtual_network_id    = var.p1_vnet_id
  allow_virtual_network_access = var.allow_virtual_network_access_on_p2
  allow_forwarded_traffic      = var.allow_forwarded_traffic_on_p2
  allow_gateway_transit        = var.allow_gateway_transit_on_p2
  use_remote_gateways          = var.use_remote_gateways_on_p2
}
