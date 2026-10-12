resource "azurerm_private_endpoint" "lab_storage" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.hub_pe.id
  name                = "${local.pe_name}-storage"
  private_service_connection {
    name                           = "psc-${local.prefix}-storage"
    private_connection_resource_id = azurerm_storage_account.lab.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }
}

resource "azurerm_private_dns_zone" "lab_storage_pe" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = data.azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "lab_vnets" {
  resource_group_name   = data.azurerm_resource_group.main.name
  for_each              = local.vnet_ids
  name                  = "${local.vnetlink_name}-${each.key}"
  virtual_network_id    = each.value
  private_dns_zone_name = azurerm_private_dns_zone.lab_storage_pe.name
  registration_enabled  = false
}

resource "azurerm_private_dns_a_record" "lab_storage_pe" {
  name                = local.st_lab_name
  resource_group_name = data.azurerm_resource_group.main.name
  zone_name           = azurerm_private_dns_zone.lab_storage_pe.name
  records             = [azurerm_private_endpoint.lab_storage.private_service_connection[0].private_ip_address]
  ttl                 = 300
}

resource "azurerm_network_security_group" "storage_pe" {
  name                = "${local.nsg_name}-hub-pe"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = azurerm_virtual_network.hub.location
  security_rule {
    name                       = "allow-spoke1-workload"
    description                = "allow spoke1's workload subnet to access PE subnet"
    protocol                   = "Tcp"
    destination_port_range     = "443"
    source_port_range          = "*"
    priority                   = 100
    source_address_prefix      = "172.22.16.0/24"
    destination_address_prefix = "*"
    access                     = "Allow"
    direction                  = "Inbound"
  }
  security_rule {
    name                       = "deny-all"
    description                = "explicitely deny all"
    protocol                   = "*"
    priority                   = 4096
    destination_address_prefix = "*"
    source_address_prefix      = "*"
    destination_port_range     = "*"
    source_port_range          = "*"
    access                     = "Deny"
    direction                  = "Inbound"
  }
}

resource "azurerm_subnet" "hub_pe" {
  resource_group_name               = data.azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.hub.name
  name                              = "${local.snet_name}-pe"
  address_prefixes                  = [var.hub.subnets_special.pe.cidr]
  private_endpoint_network_policies = "Enabled"
}

resource "azurerm_subnet_network_security_group_association" "hub_pe" {
  network_security_group_id = azurerm_network_security_group.storage_pe.id
  subnet_id = azurerm_subnet.hub_pe.id
}