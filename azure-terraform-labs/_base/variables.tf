# =============================================================
# Base variables — standard across every day. Extend per day as needed.
# =============================================================

variable "owner" {
  type    = string
  default = "vg"
}

variable "environment" {
  type    = string
  default = "lab"
}

variable "location" {
  type    = string
  default = "westus"
}

# VNet address spaces keyed by role. Map key = logical handle, value = CIDR.
variable "vnet_address_space" {
  type = map(string)
  default = {
    hub    = "172.22.0.0/20"
    spoke1 = "172.22.16.0/20"
    spoke2 = "172.22.32.0/20"
    onprem = "172.22.64.0/20"
  }
}

# Hub subnets. Map key = subnet name (used via each.key).
# service_endpoints optional — defaults to [] when omitted.
variable "subnets" {
  type = map(object({
    cidr              = string
    has_nsg           = bool
    service_endpoints = optional(list(string), [])
  }))
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
