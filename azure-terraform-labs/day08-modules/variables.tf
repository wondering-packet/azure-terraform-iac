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

###---d08ex01 >>>
variable "vnets" {
  type = map(object({
    address_space = list(string)
    location      = optional(string)
  }))
}
###---d08ex01 <<<
###---d08ex02 >>>
variable "snets" {
  # you only define type at the root.
  type = object(
    {                    # this object contains 4 keys: hub, hub_special, spoke1, spoke2.
      hub = map(object({ # hub is then further defines a map. inner map.
        # inner map here contains all these variables.
        address_prefixes  = list(string)
        has_nsg           = optional(bool, false)
        service_endpoints = optional(list(string))
        delegations = optional(map(object({
          name    = string
          actions = list(string)
        })), {}) # {} set the default.
      }))

      hub_special = map(object({
        address_prefixes = list(string)
        # notice that i am always trying to pass a default for optionals
        # this ensures that my "snets" module inside the root always
        # have this attribute defined. if a subnet doesn't have this attribute
        # defined in tfvars then "null" is passed to subnet module.
        # subnet module too has a default "null" as a 2nd layer of safety
        # the reason for having default at 2 layers is cuz i can now have
        # multiple "snets" modules at root, some of which can choose to include 
        # this attribute (in which both layers work for not assigned variable)
        # while some of the root module can simply choose not to add this attribute
        # in the definition (in which cas my layer 2's default sets the null
        # and this is exactly why i need null at layer 2 as well).
        private_endpoint_network_policies = optional(string, null)
      }))

      spoke1 = map(object({
        address_prefixes  = list(string)
        has_nsg           = optional(bool, false)
        service_endpoints = optional(list(string))
        delegations = optional(map(object({
          name    = string
          actions = list(string)
        })), {})
      }))

      spoke2 = map(object({
        address_prefixes  = list(string)
        has_nsg           = optional(bool, false)
        service_endpoints = optional(list(string))
        delegations = optional(map(object({
          name    = string
          actions = list(string)
        })), {})
      }))
    }
  )
}
###---d08ex02 <<<
###---d08ex03 >>>
variable "nsg_sec_rules" {
  type = map( # a map of map
    map(object({
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
  )
  default = {}
}
###---d08ex03 <<<
###---d08ex04 >>>
variable "peerings" {
  type = map(object({ # map of object allows holding multiple peerings.
    p1 = string       # peer 1
    p2 = string       # peer 2
    # everything below is optional with default
    allow_virtual_network_access_on_p1 = optional(bool, true)
    allow_forwarded_traffic_on_p1      = optional(bool, false)
    allow_gateway_transit_on_p1        = optional(bool, false)
    use_remote_gateways_on_p1          = optional(bool, false)
    allow_virtual_network_access_on_p2 = optional(bool, true)
    allow_forwarded_traffic_on_p2      = optional(bool, false)
    allow_gateway_transit_on_p2        = optional(bool, false)
    use_remote_gateways_on_p2          = optional(bool, false)
  }))
}
variable "routing_tables" {
  type = map(object({ # very similar to peerings
    location                      = string
    bgp_route_propagation_enabled = optional(bool, true)
    owner                         = optional(string, "vg")
    environment                   = optional(string, "lab")
    # here inside each table, we have this routes object which hold
    # a map of object i.e. it can hold multiple routes within.
    # optional makes it so that you can still create a routing table
    # with 0 routes.
    routes = optional(map(object({
      address_prefix  = string
      next_hop_type   = string
      next_hop_target = optional(string, null)
    })), {})
  }))
}
variable "dns" {
  # very similar to above routing variable.
  # note that this is missing vnet_id attribute inside.
  # vnet_id is built in local.dns
  type = map(object({
    rg_name = optional(string)
    vnet_links = optional(map(object({
      registration_enabled = optional(bool, false)
    })))
  }))
}
###---d08ex04 <<<
