resource "azurerm_network_security_group" "nsg" {
  name                = var.nsg_name
  resource_group_name = var.rg_name
  location            = var.nsg_location

  # read up more on dynamic blocks but bascially it's only passed to azure if not empty.
  dynamic "security_rule" {
    for_each = var.nsg_sec_rules # our main iterator
    content {
      # notice we are referencing the iterated dynamic block which is "security_rule" above.
      # also note that most of below attributes are optional with defaults. see variables.
      name                         = security_rule.key
      description                  = security_rule.value.description
      protocol                     = security_rule.value.protocol
      destination_port_range       = security_rule.value.destination_port_range
      source_port_range            = security_rule.value.source_port_range
      source_port_ranges           = security_rule.value.source_port_ranges
      destination_port_ranges      = security_rule.value.destination_port_ranges
      priority                     = security_rule.value.priority
      source_address_prefix        = security_rule.value.source_address_prefix
      source_address_prefixes      = security_rule.value.source_address_prefixes
      destination_address_prefix   = security_rule.value.destination_address_prefix
      destination_address_prefixes = security_rule.value.destination_address_prefixes
      access                       = security_rule.value.access
      direction                    = security_rule.value.direction
    }
  }
}
