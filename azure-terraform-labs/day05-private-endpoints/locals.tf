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
  ###---d03ex02 >>>
  # added below for d03ex02
  snet_name = "snet-${local.prefix}"
  ###---d03ex02 <<<

  ###---d05-test_vms >>>
  test_vms_subnet_ids = {
    hub    = azurerm_subnet.hub["shared"].id
    spoke1 = azurerm_subnet.spoke1.id
    spoke2 = azurerm_subnet.spoke2.id
  }
  ###---d05-test_vms <<<
  ###---d05ex03ex04-private_endpoint >>>
  # note that this block is used by bastion resources as well in d05-test_bastion
  vnet_ids = {
    hub    = azurerm_virtual_network.hub.id
    spoke1 = azurerm_virtual_network.spoke1.id
    spoke2 = azurerm_virtual_network.spoke2.id
  }
  ###---d05ex03ex04-private_endpoint <<<
}


