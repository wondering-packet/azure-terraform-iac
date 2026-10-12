resource "azurerm_subnet" "hub" {
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.hub.name

  for_each = var.subnets_hub
  ###---d03ex02 >>>
  # our standard naming convention
  name             = "${local.snet_name}-${each.key}"
  address_prefixes = [each.value.cidr]
  # i also added the service endpoints that was missing
  service_endpoints = each.value.service_endpoints
  ###---d03ex02 <<<
  ###---d03ex03 >>>
  dynamic "delegation" {
    for_each = each.value.delegation
    content {
      name = delegation.key
      service_delegation {
        name    = delegation.value.service_name
        actions = delegation.value.service_actions
      }
    }
  }
  ###---d03ex03 <<<
}

resource "azurerm_subnet" "hub_reserved" {
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.hub.name
  # naming convention for reserved subnets. these cannot follow standard naming convention.
  for_each         = var.subnets_hub_reserved
  name             = each.key
  address_prefixes = [each.value.cidr]
}
resource "azurerm_network_security_group" "main" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location

  for_each = { for k, v in var.subnets_hub : k => v if v.has_nsg }

  name = "${local.nsg_name}-${each.key}"
}

###---d03ex04 >>>

resource "azurerm_subnet" "spoke1" {
  virtual_network_name = azurerm_virtual_network.spoke1.name
  resource_group_name  = data.azurerm_resource_group.main.name
  name                 = "${local.snet_name}-spoke1-workload"
  address_prefixes     = [var.subnets_spoke1["workload"].cidr]
}

resource "azurerm_subnet" "spoke2" {
  virtual_network_name = azurerm_virtual_network.spoke2.name
  resource_group_name  = data.azurerm_resource_group.main.name
  name                 = "${local.snet_name}-spoke2-workload"
  address_prefixes     = [var.subnets_spoke2["workload"].cidr]
}

###---d03ex04 <<<
