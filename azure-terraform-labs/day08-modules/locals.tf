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
  pdnslink_name    = "pdnslink-${var.owner}-${local.environment}" # added in d04ex05
  dnsresolver_name = "dnsresolver-${local.prefix}"                # added in d04ex07
  fwrule_name      = "fwrule-${local.prefix}"                     # added in d04ex07
  vnetlink_name    = "vnetlink-${local.prefix}"                   # added in d04ex07. realized i should have used pdslink instead.
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
    hub    = module.snets_hub["shared"].snet_id
    spoke1 = module.snets_spoke1["workload"].snet_id
    spoke2 = module.snets_spoke2["workload"].snet_id
  }
  vnet_ids = {
    hub    = module.vnets["hub"].vnet_id
    spoke1 = module.vnets["spoke1"].vnet_id
    spoke2 = module.vnets["spoke2"].vnet_id
  }
  ###---d08ex04 >>>
  # the reason for having a local.dns and not using var.dns is
  # var.dns doesn't allow expressions i.e. i can't build vnet_id
  # using var. that's why here i am essentially copying var.dns
  # and adding vnet_id as an additional attribute.
  # now my main.tf will loop over local.dns instead of var.dns.
  dns = {
    # parent loop. this builds: zone_name = {vnet_links = {}}
    for zone_name, zone in var.dns : zone_name => {
      vnet_links = {
        # here this child loop fills in the vnet_links object.
        # registration_enabled pulled in from var.dns.
        # vnet_id expression built.
        for vnet_name, link in zone.vnet_links : vnet_name => {
          registration_enabled = link.registration_enabled
          vnet_id              = module.vnets[vnet_name].vnet_id
        }
      }
    }
  }

  ###---d08ex04 <<<
  ###---d08ex07 >>>
  hub_fw_private_ip = "172.22.1.4"
  ###---d08ex07 <<<

}
