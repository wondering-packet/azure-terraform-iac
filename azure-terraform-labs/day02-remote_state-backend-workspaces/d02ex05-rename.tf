# derived from day 02 ex02.

### renamed from "d02-temp-nsg" to "d02-temp-nsg2" for terraform mv ex5.
resource "azurerm_network_security_group" "d02-temp-nsg2" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  name                = "${local.nsg_name}-temp"
}
