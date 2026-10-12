variable "location" {
  type    = string
  default = "westus"
}

variable "owner" {
  type = string
}

variable "environment" {
  type = string
}

variable "tf_stack" {
  type = string
}

variable "test_vm_admin_password" {
  type      = string
  sensitive = true
  default   = null
}
