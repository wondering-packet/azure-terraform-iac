terraform {
  backend "azurerm" {
    resource_group_name  = "rg-vg-lab-wus-01"
    storage_account_name = "stvglabwustfstate"
    container_name       = "tfstate"
    key                  = "networking/hub-spoke"
    # enabled aad auth in day 03
    use_azuread_auth = true
    use_cli          = true
  }
}
