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

  environment           = terraform.workspace == "default" ? "lab" : terraform.workspace
  prefix                = "${var.owner}-${local.environment}-${local.region_code}"
  vnet_name             = "vnet-${local.prefix}"
  rg_name               = "rg-${local.prefix}"
  nsg_name              = "nsg-${local.prefix}"
  snet_name             = "snet-${local.prefix}"                            # added in d03ex02
  peering_name          = "peer-${local.prefix}"                            # added in d04ex02
  rt_name               = "rt-${local.prefix}"                              # added in d04ex03
  route_name            = "route-${var.owner}-${local.environment}"         # added in d04ex03
  pdslink_name          = "pdnslink-${var.owner}-${local.environment}"      # added in d04ex05
  dnsresolver_name      = "dnsresolver-${local.prefix}"                     # added in d04ex07
  fwrule_name           = "fwrule-${local.prefix}"                          # added in d04ex07
  vnetlink_name         = "vnetlink-${local.prefix}"                        # added in d04ex07
  st_lab_name           = "stvglabwus01"                                    # added in d05ex01, storage account name can't have hyphens etc.
  nic_name              = "nic-${local.prefix}"                             # added in d05-test_vms
  vm_name               = "vm-${local.prefix}"                              # added in d05-test_vms
  bastion_name          = "bastion-${local.prefix}"                         # added in d05-test_bastion
  pe_name               = "pe-${local.prefix}"                              # added in d05ex03-pe
  pip_name              = "pip-${local.prefix}"                             # added in d06ex01.
  vpngw_name            = "vpngw-${local.prefix}"                           # added in d06ex03.
  lng_name              = "lng-${local.prefix}"                             # added in d06ex04.
  gw_conn_name          = "conn-${local.prefix}"                            # added in d06ex04.
  fwpol_name            = "fwpol-${local.prefix}"                           # added in d07ex02.
  fwrcg_name            = "fwrcg-${local.prefix}"                           #added in d07ex02.
  fwnetcol_name         = "fwnetcol-${local.prefix}"                        #added in d07ex04.
  fwappcol_name         = "fwappcol-${local.prefix}"                        #added in d07ex04.
  fwnatcol_name         = "fwnatcol-${local.prefix}"                        #added in d07ex04.
  rfc1918_address       = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"] # added in d07ex02.
  fw_name               = "fw-${local.prefix}"                              # added in d07ex03.
  fwipconf_name         = "fwipconf-${local.prefix}"                        # added in d07ex03.
  spoke1_workload_vm_ip = "172.22.16.4"                                     # added d07ex04.
  # above vm_ip defines the same static ip that we attached to our spoke 1 test vm.
  law_name      = "law-${local.prefix}"  # added in d07ex05.
  mon_diag_name = "diag-${local.prefix}" # added in d07ex05.
}



