variable "vnet_name" {
  type = string
}

variable "rg_name" {
  type = string
}

variable "snet_name" {
  type = string
}

variable "address_prefixes" {
  type = list(string)
  validation {
    condition     = alltrue([for cidr in var.address_prefixes : can(regex("^172\\.", cidr))])
    error_message = "All CIDRs must start with 172."
  }
}

variable "service_endpoints" {
  type    = list(string)
  default = []
}

variable "private_endpoint_network_policies" {
  type    = string
  default = null
}
variable "service_delegations" {
  # map can hold multiple delegations.
  # each delegation will have a key.
  # the value inside the key will contain 
  # {name = NAME actions = ACTIONS}
  type = map(object({
    name    = string
    actions = list(string)
  }))
  default = {} # default when nothing is passed.
}
