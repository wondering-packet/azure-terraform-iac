locals {
  subnet_map_hub = {
    mgmt = cidrsubnet("172.22.0.0/20", 4, 7)
    web  = cidrsubnet("172.22.0.0/20", 4, 10)
    app  = cidrsubnet("172.22.0.0/20", 4, 11)
    db   = cidrsubnet("172.22.0.0/20", 4, 12)
  }

  ###---d05ex01 >>>
  lab_tags = {
    env        = local.environment
    managed_by = "terraform"
    owner      = var.owner
    purpose    = "networking"
  }
  ###---d05ex01 <<<
  region_code = var.location == "westus" ? "wus" : "eus"
  ## naming chain

  environment      = terraform.workspace == "default" ? "lab" : terraform.workspace
  prefix           = "${var.owner}-${local.environment}-${local.region_code}"
  vnet_name        = "vnet-${local.prefix}"
  rg_name          = "rg-${local.prefix}"
  nsg_name         = "nsg-${local.prefix}"
  snet_name        = "snet-${local.prefix}"                       # added in d03ex02
  peering_name     = "peer-${local.prefix}"                       # added in d04ex02
  rt_name          = "rt-${local.prefix}"                         # added in d04ex03
  route_name       = "route-${var.owner}-${local.environment}"    # added in d04ex03
  pdslink_name     = "pdnslink-${var.owner}-${local.environment}" # added in d04ex05
  dnsresolver_name = "dnsresolver-${local.prefix}"                # added in d04ex07
  fwrule_name      = "fwrule-${local.prefix}"                     # added in d04ex07
  vnetlink_name    = "vnetlink-${local.prefix}"                   # added in d04ex07
  st_lab_name      = "stvglabwus01"                               # added in d05ex01, storage account name can't have hyphens etc.
  nic_name         = "nic-${local.prefix}"                        # added in d05-test_vms
  vm_name          = "vm-${local.prefix}"                         # added in d05-test_vms
  bastion_name     = "bastion-${local.prefix}"                    # added in d05-test_bastion
  pe_name          = "pe-${local.prefix}"                         # added in d05ex03-pe
  pip_name         = "pip-${local.prefix}"                        # added in d06ex01.
  vpngw_name       = "vpngw-${local.prefix}"                      # added in d06ex03.
  lng_name         = "lng-${local.prefix}"                        # added in d06ex04.
  gw_conn_name     = "conn-${local.prefix}"                       # added in d06ex04.

}


