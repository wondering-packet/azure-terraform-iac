###---exercise 3---###
## alternatively we could have pulled the subnets from variables as well
## but the exercise wants us to manually define them here.
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

  prefix    = "${var.owner}-${var.environment}-${local.region_code}"
  vnet_name = "vnet-${local.prefix}"
  rg_name   = "rg-${local.prefix}"
  nsg_name  = "nsg-${local.prefix}"
}
###--end---ex3--###
