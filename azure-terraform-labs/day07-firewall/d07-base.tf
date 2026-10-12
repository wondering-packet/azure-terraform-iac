data "azurerm_resource_group" "main" {
  name = "${local.rg_name}-01"
}

data "azurerm_subnet" "spoke1_workload" {
  name                 = "${local.snet_name}-spoke1-workload"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = "${local.vnet_name}-spoke1"
}

data "azurerm_subnet" "spoke2_workload" {
  name                 = "${local.snet_name}-spoke2-workload"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = "${local.vnet_name}-spoke2"
}
