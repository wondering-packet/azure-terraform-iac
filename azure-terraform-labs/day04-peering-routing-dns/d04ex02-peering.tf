resource "azurerm_virtual_network_peering" "hub_to_spoke1" {
  name                         = "${local.peering_name}-hub-to-spoke1"
  resource_group_name          = data.azurerm_resource_group.main.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke1.id
  allow_virtual_network_access = true
  # honestly "allow_forwarded_traffic = true" is most likely not needed since
  # hub always have direct reachability into all the spokes so there is never a need 
  # to accept forwarded packet. pls validate in a lab.  
  allow_forwarded_traffic = true
  allow_gateway_transit   = true
  use_remote_gateways     = false
}

resource "azurerm_virtual_network_peering" "hub_to_spoke2" {
  name                      = "${local.peering_name}-hub-to-spoke2"
  resource_group_name       = data.azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.spoke2.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "spoke1_to_hub" {
  name                      = "${local.peering_name}-spoke1-to-hub"
  resource_group_name       = data.azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.spoke1.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false # no gateways deployed yet so false for now.
}

resource "azurerm_virtual_network_peering" "spoke2_to_hub" {
  name                      = "${local.peering_name}-spoke2-to-hub"
  resource_group_name       = data.azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.spoke2.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
