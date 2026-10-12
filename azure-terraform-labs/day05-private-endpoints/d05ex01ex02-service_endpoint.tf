resource "azurerm_storage_account" "lab" {
  name                            = local.st_lab_name
  resource_group_name             = data.azurerm_resource_group.main.name
  location                        = data.azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  allow_nested_items_to_be_public = false

  tags = local.lab_tags
}

resource "azurerm_storage_account_network_rules" "lab_st_rules" {
  storage_account_id = azurerm_storage_account.lab.id
  default_action     = "Deny"
  ## i realized even if i comment out the bypass line.
  ## azure by default bypasses azureservices.
  ## you can confirm this with "terraform state show azurerm_storage_account_network_rules.lab_st_rules"
  bypass                     = ["AzureServices"]
  virtual_network_subnet_ids = [azurerm_subnet.spoke1.id]
}
