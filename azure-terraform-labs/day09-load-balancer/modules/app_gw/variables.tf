variable "rg_name" {
  type = string
}

variable "location" {
  type = string
}

variable "agw_name" {
  type = string
}

variable "pip" {
  type = object({
    name              = string
    allocation_method = string
  })
  validation {
    condition     = contains(["Static", "Dynamic"], var.pip.allocation_method)
    error_message = "allocation_method can only be 'Static' or 'Dynamic'"
  }
}

variable "gateway_ip_configuration" {
  type = object({
    subnet_id = string
  })
}

variable "backend_address_pool" {
  type = object({
    ip_addresses = list(string)
  })

  validation {
    condition     = alltrue([for cidr in var.backend_address_pool.ip_addresses : can(regex("^172\\.", cidr))])
    error_message = "All CIDRs must start with 172."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
