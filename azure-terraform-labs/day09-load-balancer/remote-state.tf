data "terraform_remote_state" "base" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-vg-lab-wus-01"
    storage_account_name = "stvglabwustfstate"
    container_name       = "tfstate"
    key                  = "networking/hub-spoke"
    use_azuread_auth     = true
    use_cli              = true
  }
}
