variable "location" {
  type    = string
  default = "eastus"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "project" {
  type    = string
  default = "vg"
}

variable "subnets" {
  default = {
    subnet-web = "172.22.1.0/24"
    subnet-app = "172.22.2.0/24"
    subnet-db  = "172.22.3.0/24"
  }
}
