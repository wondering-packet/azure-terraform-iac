resource "azurerm_public_ip" "fw" {
  name                = "${local.pip_name}-fw"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.lab_tags
}
