resource "azurerm_private_endpoint" "pe" {
  resource_group_name = var.rg_name
  location            = var.location
  subnet_id           = var.subnet_id
  name                = var.name
  private_service_connection {
    name                           = var.psc_name
    private_connection_resource_id = var.psc_private_connection_resource_id
    subresource_names              = var.psc_subresource_names
    is_manual_connection           = var.psc_is_manual_connection
  }

  tags = var.tags
}
