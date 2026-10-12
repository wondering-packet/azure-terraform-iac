variable "nsg_name" {
  type = string
}

variable "rg_name" {
  type = string
}

variable "nsg_location" {
  type = string
}

variable "nsg_sec_rules" {
  # this is a map of each security rule.
  # i looked up latest terraform docs to define these.
  # however as you can guess, if terraform or azure deprecates
  # these attributes then i will have to updated them here.
  # that means always testing new terraform updates in dev
  # to ensure our designed variables do not break anything.
  type = map(object({
    # by default each attribute is already set to null in azure.
    # by setting null here, we are keeping things as it is. no changes.
    description                  = optional(string, null)
    protocol                     = string
    source_port_range            = optional(string, null)
    source_port_ranges           = optional(list(string), null)
    destination_port_range       = optional(string, null)
    destination_port_ranges      = optional(list(string), null)
    priority                     = number
    source_address_prefix        = optional(string, null)
    source_address_prefixes      = optional(list(string), null)
    destination_address_prefix   = optional(string, null)
    destination_address_prefixes = optional(list(string), null)
    access                       = string
    direction                    = string
  }))
  default = {}
}
