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
###---d03ex02 >>>
variable "subnets_hub" {
  type = map(object({
    cidr              = string
    has_nsg           = bool
    service_endpoints = optional(list(string), [])
    ###---d03ex03 >>>
    delegation = optional(map(object({
      service_name    = string
      service_actions = list(string)
    })), {})
  }))
  ###---d03ex03 <<<
}

variable "subnets_hub_reserved" {
  type = map(object({
    cidr = string
  }))
}
###---d03ex04 <<<
variable "subnets_spoke1" {
  type = map(object({
    cidr = string
  }))

}
variable "subnets_spoke2" {
  type = map(object({
    cidr = string
  }))

}
###---d03ex04 >>>
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
