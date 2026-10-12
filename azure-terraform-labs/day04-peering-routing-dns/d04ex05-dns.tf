resource "azurerm_private_dns_zone" "internal_lab" {
  resource_group_name = data.azurerm_resource_group.main.name
  name                = "internal.lab.com"
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  resource_group_name   = data.azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.internal_lab.name
  virtual_network_id    = azurerm_virtual_network.hub.id
  name                  = "${local.pdslink_name}-hub"
  registration_enabled  = true
}

resource "azurerm_private_dns_zone_virtual_network_link" "spoke1" {
  resource_group_name   = data.azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.internal_lab.name
  virtual_network_id    = azurerm_virtual_network.spoke1.id
  name                  = "${local.pdslink_name}-spoke1"
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "spoke2" {
  resource_group_name   = data.azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.internal_lab.name
  virtual_network_id    = azurerm_virtual_network.spoke2.id
  name                  = "${local.pdslink_name}-spoke2"
  registration_enabled  = false
}
