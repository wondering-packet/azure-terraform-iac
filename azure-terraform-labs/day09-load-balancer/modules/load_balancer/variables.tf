variable "lb_name" {
  type = string
}

variable "rg_name" {
  type = string
}

variable "location" {
  type = string
}

variable "frontend_ip_configuration" {
  type = object({
    name                          = optional(string)
    subnet_id                     = optional(string)
    private_ip_address            = optional(string)
    private_ip_address_allocation = optional(string)
    public_ip_address_id          = optional(string)
  })
  validation {
    condition = (
      var.frontend_ip_configuration.private_ip_address_allocation != null ||
      contains(["Static", "Dynamic"], var.frontend_ip_configuration.private_ip_address_allocation)
    )
    error_message = "allocation type: Static or Dynamic only"
  }
  default = {}
}

variable "sku" {
  type = string
  validation {
    condition     = contains(["Basic", "Standard", "Gateway"], var.sku)
    error_message = "sku type: Basic, Standard, Gateway only"
  }
  default = "Standard"
}

variable "lb_be_pool" {
  type = object({
    name = string
  })
}
variable "lb_probe" {
  type = object({
    name         = string
    port         = optional(number, 80)
    protocol     = optional(string, "Tcp")
    request_path = optional(string)
  })
  validation {
    condition     = contains(["Http", "Https", "Tcp"], var.lb_probe.protocol)
    error_message = "protocol type: Http, Https, Tcp only"
  }

}

variable "lb_be_nic_associations" {
  type = map(object({
    network_interface_id  = string
    ip_configuration_name = string
  }))
}

variable "lb_rule" {
  type = object({
    name          = string
    frontend_port = number
    backend_port  = number
    protocol      = string
  })
  validation {
    condition     = contains(["Tcp", "Udp", "All"], var.lb_rule.protocol)
    error_message = "Protocols: Tcp, Udp, All only"
  }
}
