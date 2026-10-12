locals {
  env     = var.env
  project = var.project
  location_short_map = {
    eastus  = "eus"
    westus  = "wus"
    eastus2 = "eus2"
    westus2 = "wus2"
  }
  location_short = lookup(local.location_short_map, var.location, "unknown")
  prefix         = "${local.project}-${local.env}-${local.location_short}"
  rg_name        = "${local.prefix}-rg"
  vnet_name      = "${local.prefix}-vnet"
}
