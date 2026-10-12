# I had made some major changes to how subnets names are contructed
# hence all these move operations.
# moved {
#   from = azurerm_subnet.hub["pe"]
#   to   = azurerm_subnet.hub_pe
# }
# moved {
#   from = azurerm_subnet.hub_reserved["GatewaySubnet"]
#   to   = azurerm_subnet.hub_gateway
# }
# moved {
#   from = azurerm_subnet.hub_reserved["AzureFirewallSubnet"]
#   to   = azurerm_subnet.hub_azurefirewall
# }
