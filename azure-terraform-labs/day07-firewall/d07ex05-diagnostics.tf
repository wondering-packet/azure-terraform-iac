resource "azurerm_log_analytics_workspace" "main" {
  name = local.law_name
  resource_group_name = data.azurerm_resource_group.main.name
  location = data.azurerm_resource_group.main.location
  tags = local.lab_tags
}

resource "azurerm_monitor_diagnostic_setting" "fw" {
  name = "${local.mon_diag_name}-fw"
  target_resource_id = azurerm_firewall.hub.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  metric {
    category = "AllMetrics"
  }
  enabled_log {category = "AzureFirewallApplicationRule"}
  enabled_log {category = "AzureFirewallNetworkRule"}
  enabled_log {category = "AzureFirewallDnsProxy"}
}