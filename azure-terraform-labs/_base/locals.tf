# =============================================================
# Base locals — naming chain + subnet map. Standard across every day.
# =============================================================

locals {
  region_code = var.location == "westus" ? "wus" : "eus"

  # Naming chain — one source of truth for all resource names
  prefix    = "${var.owner}-${var.environment}-${local.region_code}"
  vnet_name = "vnet-${local.prefix}"
  rg_name   = "rg-${local.prefix}"
  nsg_name  = "nsg-${local.prefix}"

  # Hub subnet CIDRs (base /16 + 8 newbits = /24; netnum = third octet)
  subnet_map = {
    mgmt = cidrsubnet("172.22.0.0/16", 8, 7)   # 172.22.7.0/24
    web  = cidrsubnet("172.22.0.0/16", 8, 10)  # 172.22.10.0/24
    app  = cidrsubnet("172.22.0.0/16", 8, 11)  # 172.22.11.0/24
    db   = cidrsubnet("172.22.0.0/16", 8, 12)  # 172.22.12.0/24
  }

  common_tags = {
    environment = var.environment
    managed_by  = "terraform"
    region      = var.location
  }
}
