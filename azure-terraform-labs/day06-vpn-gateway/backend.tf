terraform {
  backend "azurerm" {
    resource_group_name  = "rg-vg-lab-wus-01"
    storage_account_name = "stvglabwustfstate"
    container_name       = "tfstate"
    key                  = "networking/vpn"
    use_azuread_auth     = true
    use_cli              = true
  }
}


