resource "azurerm_route_table" "rt" {
  name                          = var.rt_name
  resource_group_name           = var.rg_name
  location                      = var.location
  bgp_route_propagation_enabled = var.bgp_route_propagation_enabled
}

resource "azurerm_route" "route" {
  resource_group_name    = var.rg_name
  route_table_name       = azurerm_route_table.rt.name
  for_each               = var.routes
  name                   = "${var.route_name_prefix}-${each.key}"
  address_prefix         = each.value.address_prefix
  next_hop_type          = each.value.next_hop_type
  next_hop_in_ip_address = try(var.next_hop_ips[each.value.next_hop_target], null)
}
