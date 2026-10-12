## code now commented out cuz end of exercise task is destroy.

# resource "azurerm_private_dns_resolver" "hub" {
#   virtual_network_id  = azurerm_virtual_network.hub.id
#   location            = azurerm_virtual_network.hub.location
#   name                = local.dnsresolver_name
#   resource_group_name = data.azurerm_resource_group.main.name
# }

# resource "azurerm_private_dns_resolver_inbound_endpoint" "hub_inbound" {
#   name                    = "inbound-${local.prefix}"
#   location                = azurerm_virtual_network.hub.location
#   private_dns_resolver_id = azurerm_private_dns_resolver.hub.id

#   ip_configurations {
#     subnet_id                    = azurerm_subnet.hub["dns-inbound"].id
#     private_ip_allocation_method = "Static"
#     private_ip_address           = "172.22.4.4"
#   }
# }

# resource "azurerm_private_dns_resolver_outbound_endpoint" "hub_outbound" {
#   name                    = "outbound-${local.prefix}"
#   location                = azurerm_virtual_network.hub.location
#   private_dns_resolver_id = azurerm_private_dns_resolver.hub.id
#   subnet_id               = azurerm_subnet.hub["dns-outbound"].id
# }

# resource "azurerm_private_dns_resolver_dns_forwarding_ruleset" "hub_ruleset" {
#   name                = "fwruleset-${local.prefix}"
#   resource_group_name = data.azurerm_resource_group.main.name
#   location            = data.azurerm_resource_group.main.location
#   private_dns_resolver_outbound_endpoint_ids = [
#     azurerm_private_dns_resolver_outbound_endpoint.hub_outbound.id
#   ]
# }

# resource "azurerm_private_dns_resolver_forwarding_rule" "test" {
#   name                      = "${local.fwrule_name}-test"
#   dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.hub_ruleset.id
#   domain_name               = "fakedomain.internal."

#   target_dns_servers {
#     ip_address = "8.8.8.8"
#     port       = 53
#   }
# }

# resource "azurerm_private_dns_resolver_virtual_network_link" "hub_link" {
#   name                      = "${local.vnetlink_name}-hub"
#   virtual_network_id        = azurerm_virtual_network.hub.id
#   dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.hub_ruleset.id
# }
