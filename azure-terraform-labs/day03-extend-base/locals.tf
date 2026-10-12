locals {
  subnet_map_hub = {
    mgmt = cidrsubnet("172.22.0.0/20", 4, 7)
    web  = cidrsubnet("172.22.0.0/20", 4, 10)
    app  = cidrsubnet("172.22.0.0/20", 4, 11)
    db   = cidrsubnet("172.22.0.0/20", 4, 12)
  }

  common_tags = {
    environment = "lab"
    managed_by  = "terraform"
    owner       = "vg" # optional to build the naming chain
    region      = var.location
  }

  region_code = var.location == "westus" ? "wus" : "eus"
  ## naming chain

  environment = terraform.workspace == "default" ? "lab" : terraform.workspace
  prefix      = "${var.owner}-${local.environment}-${local.region_code}"
  vnet_name   = "vnet-${local.prefix}"
  rg_name     = "rg-${local.prefix}"
  nsg_name    = "nsg-${local.prefix}"
  ###---day03ex02 >>>
  # added below for d03ex02
  snet_name = "snet-${local.prefix}"
  ###---day03ex02 <<<
}
