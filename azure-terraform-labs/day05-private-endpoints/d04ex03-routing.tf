##---routing tables---##

resource "azurerm_route_table" "rt_gateway" {
  name                          = "${local.rt_name}-gw"
  resource_group_name           = data.azurerm_resource_group.main.name
  location                      = data.azurerm_resource_group.main.location
  bgp_route_propagation_enabled = true
}

resource "azurerm_route_table" "rt_spoke1" {
  name                          = "${local.rt_name}-spoke1"
  resource_group_name           = data.azurerm_resource_group.main.name
  location                      = data.azurerm_resource_group.main.location
  bgp_route_propagation_enabled = false
}

resource "azurerm_route_table" "rt_spoke2" {
  name                          = "${local.rt_name}-spoke2"
  resource_group_name           = data.azurerm_resource_group.main.name
  location                      = data.azurerm_resource_group.main.location
  bgp_route_propagation_enabled = false
}


##---routes---##

resource "azurerm_route" "gateway_to_spoke1" {
  name                   = "${local.route_name}-spoke1"
  route_table_name       = azurerm_route_table.rt_gateway.name
  resource_group_name    = data.azurerm_resource_group.main.name
  address_prefix         = "172.22.16.0/20"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "172.22.1.4"
}

resource "azurerm_route" "gateway_to_spoke2" {
  name                   = "${local.route_name}-spoke2"
  route_table_name       = azurerm_route_table.rt_gateway.name
  resource_group_name    = data.azurerm_resource_group.main.name
  address_prefix         = "172.22.32.0/20"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "172.22.1.4"
}

resource "azurerm_route" "spoke1_to_default" {
  name                   = "${local.route_name}-default"
  route_table_name       = azurerm_route_table.rt_spoke1.name
  resource_group_name    = data.azurerm_resource_group.main.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "172.22.1.4"
}

###---d05ex03ex04ex05-private_endpoint >>>
# i commented out below resource so spoke1's packets dont blackhole.
# resource "azurerm_route" "spoke1_to_private_endpoint" {
#   name                   = "${local.route_name}-pe"
#   route_table_name       = azurerm_route_table.rt_spoke1.name
#   resource_group_name    = data.azurerm_resource_group.main.name
#   address_prefix         = "172.22.3.0/24"
#   next_hop_type          = "VirtualAppliance"
#   next_hop_in_ip_address = "172.22.1.4"
# }
###---d05ex03ex04ex05-private_endpoint <<<
###---d07ex0 >>>
# above block now added back:
resource "azurerm_route" "spoke1_to_private_endpoint" {
  name                   = "${local.route_name}-pe"
  route_table_name       = azurerm_route_table.rt_spoke1.name
  resource_group_name    = data.azurerm_resource_group.main.name
  address_prefix         = "172.22.3.0/24"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "172.22.1.4"
}
###---d07ex0 <<<
resource "azurerm_route" "spoke2_to_default" {
  name                   = "${local.route_name}-default"
  route_table_name       = azurerm_route_table.rt_spoke2.name
  resource_group_name    = data.azurerm_resource_group.main.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "172.22.1.4"
}
