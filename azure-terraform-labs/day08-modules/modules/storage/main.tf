resource "azurerm_storage_account" "st" {
  name                            = var.name
  resource_group_name             = var.rg_name
  location                        = var.location
  account_tier                    = var.account_tier
  account_replication_type        = var.account_replication_type
  account_kind                    = var.account_kind
  allow_nested_items_to_be_public = var.allow_nested_items_to_be_public

  tags = var.tags
}

resource "azurerm_storage_account_network_rules" "st_rules" {
  storage_account_id         = azurerm_storage_account.st.id
  default_action             = var.network_rules_default_action
  bypass                     = var.network_rules_bypass
  virtual_network_subnet_ids = var.network_rules_allowed_subnet_ids
}
