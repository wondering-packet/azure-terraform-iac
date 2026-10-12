resource "azurerm_firewall" "hub" {
  name = "${local.fw_name}-hub"
  resource_group_name = data.azurerm_resource_group.main.name
  location = data.azurerm_resource_group.main.location
  sku_name = "AZFW_VNet"
  sku_tier = "Standard"
  firewall_policy_id = azurerm_firewall_policy.main.id
  ip_configuration {
    name = "${local.fwipconf_name}"
    subnet_id = data.terraform_remote_state.base.outputs.firewall_subnet_id
     public_ip_address_id = azurerm_public_ip.fw.id
  }
  tags = local.lab_tags
}