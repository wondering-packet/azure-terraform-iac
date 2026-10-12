# Exercise 5 — Data Sources
# honestly below hcl conflicts with day01's hcl logically.
## in day01 we are creating below the rg & vnet.
### you could probably assume that we created the resouces in day01
### then here we are importing them to be used to create spoke1
### to see how data blocks work




##-day02 >>> i changed the naming resolution for d02ex06.
# "dev" workspace -> rg-vg-dev-wus-01
# "prod" workspace -> rg-vg-prod-wus-01
# anything else -> rg-vg-lab-wus-01
# ensure rg-vg-dev-wus-01 &rg-vg-prod-wus-01 exists beforehand.
data "azurerm_resource_group" "main" {
  name = "${local.rg_name}-01"
}

##-day02 <<<



###--- below "data" block is redundant with the "resource" block in ex6. 
### only use one. "resource" block is the preferred way.
# data "azurerm_virtual_network" "hub" {
#   name                = "vnet-vg-lab-wus-hub"
#   resource_group_name = data.azurerm_resource_group.main.name
# }

###--- below resource block has been pushed into d03ex04-vnets.tf file.
# resource "azurerm_virtual_network" "spoke1" {
#   name                = "${local.vnet_name}-spoke1"
#   resource_group_name = data.azurerm_resource_group.main.name
#   location            = data.azurerm_resource_group.main.location
#   address_space       = var.vnet_address_space["spoke1"].address_space
# }

