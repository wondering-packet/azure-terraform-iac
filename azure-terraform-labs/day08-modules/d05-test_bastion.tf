resource "azurerm_bastion_host" "test" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  for_each            = var.enable_test_vms ? local.vnet_ids : {}
  name                = "${local.bastion_name}-${each.key}"
  sku                 = "Developer"
  virtual_network_id  = each.value
}
