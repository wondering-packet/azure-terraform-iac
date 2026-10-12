variable "rg_name" {
  type = string
}
variable "location" {
  type = string
}
variable "subnet_id" {
  type = string
}
variable "name" {
  type = string
}
variable "psc_name" {
  type = string
}
variable "psc_private_connection_resource_id" {
  type    = string
  default = null
}
variable "psc_subresource_names" {
  type    = list(string)
  default = []
}
variable "psc_is_manual_connection" {
  type = bool
}
variable "tags" {
  type    = map(string)
  default = {}
}
