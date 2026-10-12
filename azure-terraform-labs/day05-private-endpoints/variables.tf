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
###---d05ex05 >>>
### I realized the current subnets_hub & subnets_hub_reserved
### design didn't really work well. so i merged them into a parent "hub"
### then broke it down into "subnets" & "subnets_special"
### special block contains all the subnets that are individually unique.
### earlier "reserved" name was too specific that's why the new design.

###---d03ex02 >>>
# variable "subnets_hub" {
#   type = map(object({
#     cidr              = string
#     has_nsg           = bool
#     service_endpoints = optional(list(string), [])
#     ###---d03ex03 >>>
#     delegation = optional(map(object({
#       service_name    = string
#       service_actions = list(string)
#     })), {})
#   }))
#   ###---d03ex03 <<<
# }

# variable "subnets_hub_reserved" {
#   type = map(object({
#     cidr = string
#   }))
# }

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
###---d03ex04 <<<
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

###---d05-test-vms >>>
variable "test_vms" {
  type = map(object({
    private_ip = string
  }))
}

variable "enable_test_vms" {
  type    = bool
  default = false
}

variable "vm_admin_password" {
  # set the password in an env variable beforehand:
  # $env:TF_VAR_vm_admin_password = 'YourSame$trongPass123!'
  type      = string
  sensitive = true
  default   = null
}
###---d05-test-vms <<<
