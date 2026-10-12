# moved {
#   from = azurerm_virtual_network.hub
#   # note that we can't do module.vnets["hub"] cuz that is module
#   # instance of "hub". here we need to full resource address so
#   # we gotta reference the exact resource inside the module.
#   to = module.vnets["hub"].azurerm_virtual_network.vnet
# }
# moved {
#   from = azurerm_virtual_network.spoke1
#   to   = module.vnets["spoke1"].azurerm_virtual_network.vnet
# }
# moved {
#   from = azurerm_virtual_network.spoke2
#   to   = module.vnets["spoke2"].azurerm_virtual_network.vnet
# }
# moved {
#   from = azurerm_subnet.hub["agw"]
#   to   = module.snets_hub["agw"].azurerm_subnet.snet
# }
# moved {
#   from = azurerm_subnet.hub["app"]
#   to   = module.snets_hub["app"].azurerm_subnet.snet
# }
# moved {
#   from = azurerm_subnet.hub["db"]
#   to   = module.snets_hub["db"].azurerm_subnet.snet
# }
# moved {
#   from = azurerm_subnet.hub["dns-inbound"]
#   to   = module.snets_hub["dns-inbound"].azurerm_subnet.snet
# }
# moved {
#   from = azurerm_subnet.hub["dns-outbound"]
#   to   = module.snets_hub["dns-outbound"].azurerm_subnet.snet
# }
# moved {
#   from = azurerm_subnet.hub["mgmt"]
#   to   = module.snets_hub["mgmt"].azurerm_subnet.snet
# }
# moved {
#   from = azurerm_subnet.hub["shared"]
#   to   = module.snets_hub["shared"].azurerm_subnet.snet
# }
# moved {
#   from = azurerm_subnet.hub["web"]
#   to   = module.snets_hub["web"].azurerm_subnet.snet
# }
# moved {
#   from = azurerm_subnet.hub_azurefirewall
#   to   = module.snets_hub_special["AzureFirewallSubnet"].azurerm_subnet.snet
# }
# moved {
#   from = azurerm_subnet.hub_gateway
#   to   = module.snets_hub_special["GatewaySubnet"].azurerm_subnet.snet
# }
# moved {
#   from = azurerm_subnet.hub_pe
#   to   = module.snets_hub_special["pe"].azurerm_subnet.snet
# }
# moved {
#   from = azurerm_subnet.spoke1
#   to   = module.snets_spoke1["workload"].azurerm_subnet.snet
# }
# moved {
#   from = azurerm_subnet.spoke2
#   to   = module.snets_spoke2["workload"].azurerm_subnet.snet
# }
# moved {
#   from = azurerm_network_security_group.main["app"]
#   to   = module.nsgs["app"].azurerm_network_security_group.nsg
# }
# moved {
#   from = azurerm_network_security_group.main["web"]
#   to   = module.nsgs["web"].azurerm_network_security_group.nsg
# }
# moved {
#   from = azurerm_network_security_group.storage_pe
#   to   = module.nsg_hub_pe.azurerm_network_security_group.nsg
# }
# moved {
#   from = azurerm_virtual_network_peering.hub_to_spoke1
#   to   = module.peerings["hub_and_spoke1"].azurerm_virtual_network_peering.p1_p2_peering
# }
# moved {
#   from = azurerm_virtual_network_peering.hub_to_spoke2
#   to   = module.peerings["hub_and_spoke2"].azurerm_virtual_network_peering.p1_p2_peering
# }
# moved {
#   from = azurerm_virtual_network_peering.spoke1_to_hub
#   to   = module.peerings["hub_and_spoke1"].azurerm_virtual_network_peering.p2_p1_peering
# }
# moved {
#   from = azurerm_virtual_network_peering.spoke2_to_hub
#   to   = module.peerings["hub_and_spoke2"].azurerm_virtual_network_peering.p2_p1_peering
# }
# moved {
#   from = azurerm_route_table.rt_gateway
#   to   = module.routing["gw"].azurerm_route_table.rt
# }
# moved {
#   from = azurerm_route_table.rt_spoke1
#   to   = module.routing["spoke1"].azurerm_route_table.rt
# }
# moved {
#   from = azurerm_route_table.rt_spoke2
#   to   = module.routing["spoke2"].azurerm_route_table.rt
# }
# moved {
#   from = azurerm_route.gateway_to_spoke1
#   to   = module.routing["gw"].azurerm_route.route["spoke1"]
# }
# moved {
#   from = azurerm_route.gateway_to_spoke2
#   to   = module.routing["gw"].azurerm_route.route["spoke2"]
# }
# moved {
#   from = azurerm_route.spoke1_to_default
#   to   = module.routing["spoke1"].azurerm_route.route["default"]
# }
# moved {
#   from = azurerm_route.spoke2_to_default
#   to   = module.routing["spoke2"].azurerm_route.route["default"]
# }
# moved {
#   from = azurerm_route.spoke1_to_private_endpoint
#   to   = module.routing["spoke1"].azurerm_route.route["pe"]
# }
# moved {
#   from = azurerm_private_dns_zone.internal_lab
#   to   = module.dns["internal.lab.com"].azurerm_private_dns_zone.dns
# }
# moved {
#   from = azurerm_private_dns_zone_virtual_network_link.hub
#   to   = module.dns["internal.lab.com"].azurerm_private_dns_zone_virtual_network_link.dns_vnet_link["hub"]
# }
# moved {
#   from = azurerm_private_dns_zone_virtual_network_link.spoke1
#   to   = module.dns["internal.lab.com"].azurerm_private_dns_zone_virtual_network_link.dns_vnet_link["spoke1"]
# }
# moved {
#   from = azurerm_private_dns_zone_virtual_network_link.spoke2
#   to   = module.dns["internal.lab.com"].azurerm_private_dns_zone_virtual_network_link.dns_vnet_link["spoke2"]
# }
# moved {
#   from = azurerm_storage_account.lab
#   to   = module.storage_se.azurerm_storage_account.st
# }
# moved {
#   from = azurerm_storage_account_network_rules.lab_st_rules
#   to   = module.storage_se.azurerm_storage_account_network_rules.st_rules
# }
# moved {
#   from = azurerm_private_endpoint.lab_storage
#   to   = module.storage_pe.azurerm_private_endpoint.pe
# }
# moved {
#   from = azurerm_private_dns_zone.lab_storage_pe
#   to   = module.dns["privatelink.blob.core.windows.net"].azurerm_private_dns_zone.dns
# }
# moved {
#   from = azurerm_private_dns_zone_virtual_network_link.lab_vnets["hub"]
#   to   = module.dns["privatelink.blob.core.windows.net"].azurerm_private_dns_zone_virtual_network_link.dns_vnet_link["hub"]
# }
# moved {
#   from = azurerm_private_dns_zone_virtual_network_link.lab_vnets["spoke1"]
#   to   = module.dns["privatelink.blob.core.windows.net"].azurerm_private_dns_zone_virtual_network_link.dns_vnet_link["spoke1"]
# }
# moved {
#   from = azurerm_private_dns_zone_virtual_network_link.lab_vnets["spoke2"]
#   to   = module.dns["privatelink.blob.core.windows.net"].azurerm_private_dns_zone_virtual_network_link.dns_vnet_link["spoke2"]
# }