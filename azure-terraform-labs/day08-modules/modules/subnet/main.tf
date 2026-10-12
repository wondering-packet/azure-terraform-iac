resource "azurerm_subnet" "snet" {
  name                              = var.snet_name
  resource_group_name               = var.rg_name
  virtual_network_name              = var.vnet_name
  address_prefixes                  = var.address_prefixes
  service_endpoints                 = var.service_endpoints
  private_endpoint_network_policies = var.private_endpoint_network_policies

  # read up previous notes to learn about dynamic block
  dynamic "delegation" {
    for_each = var.service_delegations
    content {
      name = delegation.key
      service_delegation {
        name    = delegation.value.name
        actions = delegation.value.actions
      }
    }
  }
}
