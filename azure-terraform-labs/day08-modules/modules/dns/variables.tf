variable "rg_name" {
  type = string
}
variable "dns_zone_name" {
  type = string
}
variable "dns_vnet_links" {
  type = map(object({
    registration_enabled = optional(bool, false)
    vnet_id              = string
  }))
}
variable "dns_vnet_link_prefix" {
  type = string
}
variable "tags" {
  type    = map(string)
  default = {}
}
