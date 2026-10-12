resource "azurerm_virtual_network" "onprem" {
  name                = "${local.vnet_name}-onprem"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  address_space       = [var.onprem.vnet.main.address_space]
}

resource "azurerm_subnet" "onprem_gateway" {
  resource_group_name  = data.azurerm_resource_group.main.name
  name                 = "GatewaySubnet"
  virtual_network_name = azurerm_virtual_network.onprem.name
  address_prefixes     = [var.onprem.subnets_special.GatewaySubnet.cidr]
}

resource "azurerm_subnet" "onprem_workload" {
  name                 = "${local.snet_name}-onprem-workload"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.onprem.name
  address_prefixes     = [var.onprem.subnets.workload.cidr]
}
