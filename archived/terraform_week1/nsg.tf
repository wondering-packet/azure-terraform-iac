resource "azurerm_network_security_group" "web_nsg" {
  name                = "${local.prefix}-web_nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.week1_rg.name

  security_rule {
    name                       = "allow_https"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "172.22.1.0/24"
  }
  security_rule {
    name                       = "allow_http"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "172.22.1.0/24"
  }
  security_rule {
    name                       = "deny_all"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}
resource "azurerm_subnet_network_security_group_association" "web_nsg_association" {
  subnet_id = azurerm_subnet.week1_sn["subnet-web"].id
  network_security_group_id = azurerm_network_security_group.web_nsg.id
}
resource "azurerm_network_security_group" "app_nsg" {
  name                = "${local.prefix}-app_nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.week1_rg.name

  security_rule {
    name                       = "allow_from_web_sn_tcp_8080"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "172.22.1.0/24"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "deny_all"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}
resource "azurerm_subnet_network_security_group_association" "app_nsg_association" {
  subnet_id = azurerm_subnet.week1_sn["subnet-app"].id
  network_security_group_id = azurerm_network_security_group.app_nsg.id
}
resource "azurerm_network_security_group" "db_nsg" {
  name                = "${local.prefix}-db_nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.week1_rg.name

  security_rule {
    name                       = "allow_from_app_sn_tcp_5432"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = "172.22.2.0/24"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "deny_all"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }  
}
resource "azurerm_subnet_network_security_group_association" "db_nsg_association" {
  subnet_id = azurerm_subnet.week1_sn["subnet-db"].id
  network_security_group_id = azurerm_network_security_group.db_nsg.id
}