resource "azurerm_virtual_network" "vnet" {
  # define all these variables in variables file.
  # the root modules will see these as the variables that
  # can be passed in this module.
  # visual code studio e.g. pops up suggestions with these names.
  name                = var.vnet_name
  resource_group_name = var.rg_name
  location            = var.location
  address_space       = var.address_space
  tags                = var.tags
  # explicitely setting lifecycle.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags]
  }
}
