resource "azurerm_subnet" "hub" {
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.hub.name
  ###---d05ex05 >>>
  for_each = var.hub.subnets # updated value to follow new subnet variable design from d05ex05.
  ###---d05ex05 <<<

  name              = "${local.snet_name}-${each.key}"
  address_prefixes  = [each.value.cidr]
  service_endpoints = each.value.service_endpoints
  dynamic "delegation" {
    ###---d05ex05 >>>
    for_each = each.value.delegations # renamed delegation -> delegations since we can hold multiple values.
    ###---d05ex05 <<<

    content {
      name = delegation.key
      service_delegation {
        name    = delegation.value.service_name
        actions = delegation.value.service_actions
      }
    }
  }
}

resource "azurerm_subnet" "hub_gateway" {
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.hub.name
  name                 = "GatewaySubnet"
  address_prefixes     = [var.hub.subnets_special.GatewaySubnet.cidr]
}

resource "azurerm_subnet" "hub_azurefirewall" {
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.hub.name
  name                 = "AzureFirewallSubnet"
  address_prefixes     = [var.hub.subnets_special.AzureFirewallSubnet.cidr]
}

###---d05ex05 >>>
## below resrouce block replaced with above subnet definitions.
# resource "azurerm_subnet" "hub_reserved" {
#   resource_group_name  = data.azurerm_resource_group.main.name
#   virtual_network_name = azurerm_virtual_network.hub.name
#   for_each             = var.subnets_hub_reserved
#   name                 = each.key
#   address_prefixes     = [each.value.cidr]
# }
###---d05ex05 <<<
resource "azurerm_network_security_group" "main" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  ###---d05ex05 >>>
  # updated value to follow new subnet variable design from d05ex05.
  for_each = { for k, v in var.hub.subnets : k => v if v.has_nsg }
  ###---d05ex05 <<<

  name = "${local.nsg_name}-${each.key}"
}

resource "azurerm_subnet" "spoke1" {
  virtual_network_name = azurerm_virtual_network.spoke1.name
  resource_group_name  = data.azurerm_resource_group.main.name
  name                 = "${local.snet_name}-spoke1-workload"
  address_prefixes     = [var.subnets_spoke1["workload"].cidr]
  ###---d05ex02 >>>
  service_endpoints = var.subnets_spoke1["workload"].service_endpoints
  ###---d05ex02 <<<
}

resource "azurerm_subnet" "spoke2" {
  virtual_network_name = azurerm_virtual_network.spoke2.name
  resource_group_name  = data.azurerm_resource_group.main.name
  name                 = "${local.snet_name}-spoke2-workload"
  address_prefixes     = [var.subnets_spoke2["workload"].cidr]
}

