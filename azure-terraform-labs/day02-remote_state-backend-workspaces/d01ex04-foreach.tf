# Exercise 4a — for_each: subnets + conditional NSGs
# exercise 4b is in terraform.tfvars file

resource "azurerm_subnet" "hub" {
  ## i have replaced this with "data" block instead of using "resource".main block
  ## to reuse what i am creating in ex5 later.  
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.hub.name

  for_each         = var.subnets
  name             = each.key
  address_prefixes = [each.value.cidr]
}

resource "azurerm_network_security_group" "main" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location

  # Only create NSGs for subnets where has_nsg == true (db is excluded)
  ## i realized i don't need to do if v.has_nsg == true since has_nsg is already boolean.
  for_each = { for k, v in var.subnets : k => v if v.has_nsg }

  name = "${local.nsg_name}-${each.key}"
}
