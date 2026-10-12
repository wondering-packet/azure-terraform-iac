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
## the new hub's subnet design:
variable "hub" {
  type = object(
    {
      subnets = map(object({
        cidr              = string
        has_nsg           = bool
        service_endpoints = optional(list(string), [])
        delegations = optional(map(object({ # renamed delegation -> delegations since we can hold multiple values.
          service_name    = string
          service_actions = list(string)
        })), {})
      }))

      subnets_special = map(object({
        cidr = string
      }))

  })
}
###---d05ex05 <<<
###---d06ex02 >>>
# realized it's probably better to bundle all "onprem"
# vnets, subnets into a single variable.
variable "onprem" {
  type = object(
    {
      vnet = map(object({
        address_space = string
      }))
      subnets = map(object({
        cidr = string
      }))

      subnets_special = map(object({
        cidr = string
      }))

  })
}
###---d06ex02 <<<
###---d03ex04 >>>
variable "subnets_spoke1" {
  type = map(object({
    cidr              = string
    service_endpoints = list(string)
  }))

}
variable "subnets_spoke2" {
  type = map(object({
    cidr = string
  }))

}
###---d03ex04 <<<
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

variable "vpn_shared_key" {
  type = string
}

###---d07ex4 >>>
# using this lab ip variable to test the dnat rule
variable "lab_public_ip" {
  type = list(string)
}
###---d07ex04 <<<
