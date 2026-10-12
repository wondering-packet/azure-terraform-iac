# Exercise 6 — Meta-arguments & lifecycle
# Hub VNet with prevent_destroy, ignore_changes, and depends_on.
# Depends on the data source declared in ex05-datasources.tf.

resource "azurerm_virtual_network" "hub" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  name                = "${local.vnet_name}-hub"
  address_space       = var.vnet_address_space["hub"].address_space

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags]
  }

  depends_on = [data.azurerm_resource_group.main]
}
