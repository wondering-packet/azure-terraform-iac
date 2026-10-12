resource "azurerm_private_dns_zone" "dns" {
  resource_group_name = var.rg_name
  name                = var.dns_zone_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_vnet_link" {
  for_each              = var.dns_vnet_links
  name                  = "${var.dns_vnet_link_prefix}-${each.key}"
  resource_group_name   = var.rg_name
  virtual_network_id    = each.value.vnet_id
  registration_enabled  = each.value.registration_enabled
  private_dns_zone_name = azurerm_private_dns_zone.dns.name
}
