variable "vnet_name" {
  type = string
}

variable "rg_name" {
  type = string
}

variable "location" {
  type = string
}

variable "address_space" {
  type = list(string)
  validation {
    condition     = alltrue([for cidr in var.address_space : can(regex("^172\\.", cidr))])
    error_message = "All CIDRs must start with 172."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
