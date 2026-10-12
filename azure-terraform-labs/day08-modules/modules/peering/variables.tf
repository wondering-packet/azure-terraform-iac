variable "p1_vnet_name" {
  type        = string
  description = "_1 defines one end of peering. _2 defines the other end"
}

variable "p2_vnet_name" {
  type        = string
  description = "_2 defines one end of peering. _1 defines the other end"

}

variable "p1_vnet_id" {
  type        = string
  description = "_1 defines one end of peering. _2 defines the other end"

}

variable "p2_vnet_id" {
  type        = string
  description = "_2 defines one end of peering. _1 defines the other end"

}

variable "rg_name" {
  type = string
}

variable "p1_p2_peering_name" {
  type = string
}

variable "p2_p1_peering_name" {
  type = string
}

variable "allow_virtual_network_access_on_p1" {
  type    = bool
  default = true
}

variable "allow_forwarded_traffic_on_p1" {
  type    = bool
  default = false
}

variable "allow_gateway_transit_on_p1" {
  type    = bool
  default = false
}

variable "use_remote_gateways_on_p1" {
  type    = bool
  default = false
}

variable "allow_virtual_network_access_on_p2" {
  type    = bool
  default = true
}

variable "allow_forwarded_traffic_on_p2" {
  type    = bool
  default = false
}

variable "allow_gateway_transit_on_p2" {
  type    = bool
  default = false
}

variable "use_remote_gateways_on_p2" {
  type    = bool
  default = false
}
