###---d03ex04 >>>
# note that this is only one part of the ex04. we still create subnet in subnet file.

##-- added lifecycle rules to prevent accidental destruction
resource "azurerm_virtual_network" "spoke1" {
  name                = "${local.vnet_name}-spoke1"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  address_space       = var.vnet_address_space["spoke1"].address_space
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags]
  }

  depends_on = [data.azurerm_resource_group.main]
}

resource "azurerm_virtual_network" "spoke2" {
  name                = "${local.vnet_name}-spoke2"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  address_space       = var.vnet_address_space["spoke2"].address_space
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags]
  }

  depends_on = [data.azurerm_resource_group.main]
}


###---d03ex04 <<<
