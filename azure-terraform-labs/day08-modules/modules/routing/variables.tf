variable "rg_name" {
  type = string
}

variable "rt_name" {
  type = string
}

variable "location" {
  type = string
}

variable "bgp_route_propagation_enabled" {
  type    = bool
  default = true
}

variable "routes" {
  type = map(object({
    address_prefix  = string
    next_hop_target = optional(string)
    next_hop_type   = string
  }))
}

variable "route_name_prefix" {
  type    = string
  default = null
}

variable "next_hop_target" {
  type    = string
  default = null
}

variable "next_hop_ips" {
  type    = map(string)
  default = {}
}
