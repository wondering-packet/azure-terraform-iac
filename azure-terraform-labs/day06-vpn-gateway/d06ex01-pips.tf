resource "azurerm_public_ip" "hub_vpngw" {
  name                = "${local.pip_name}-vpngw"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.lab_tags
}
resource "azurerm_public_ip" "onprem_vpngw" {
  name                = "${local.pip_name}-vpngw-onprem"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.lab_tags
}
