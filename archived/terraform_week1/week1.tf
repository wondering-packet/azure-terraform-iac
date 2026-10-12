resource "azurerm_resource_group" "week1_rg" {
  name     = local.rg_name
  location = var.location
}

resource "azurerm_virtual_network" "week1_vn" {
  name                = local.vnet_name
  address_space       = ["172.22.0.0/16"]
  location            = azurerm_resource_group.week1_rg.location
  resource_group_name = azurerm_resource_group.week1_rg.name
}

resource "azurerm_subnet" "week1_sn" {
  for_each             = var.subnets
  name                 = each.key
  address_prefixes     = [each.value]
  virtual_network_name = azurerm_virtual_network.week1_vn.name
  resource_group_name  = azurerm_resource_group.week1_rg.name
}
