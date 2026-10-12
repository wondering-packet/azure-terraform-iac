variable "vnet_name" {
  type = string
}

variable "address_space" {
  type = list(string)
  validation {
    condition     = alltrue([for cidr in var.address_space : can(regex("^172\\.", cidr))])
    error_message = "All CIDRs must start with 172."
  }
}

variable "location" {
  type    = string
  default = "westus"
}

variable "subnets" {
  type = map(object({
    cidr              = string
    has_nsg           = bool
    service_endpoints = optional(list(string), [])
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "owner" {
  type = string
}

variable "environment" {
  type = string
}

variable "vnet_address_space" {
  type = map(object({
    address_space = list(string)
  }))
}
