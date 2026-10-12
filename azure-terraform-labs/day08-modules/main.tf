data "azurerm_resource_group" "main" {
  name = "${local.rg_name}-01"
}

module "vnets" {
  source        = "./modules/vnet"
  for_each      = var.vnets
  rg_name       = data.azurerm_resource_group.main.name
  location      = each.value.location
  address_space = each.value.address_space
  vnet_name     = "${local.vnet_name}-${each.key}"
  tags          = local.lab_tags
  depends_on    = [data.azurerm_resource_group.main] # this goes here cuz vnet module doesn't know our rg.
}

module "snets_hub" {
  source              = "./modules/subnet"
  rg_name             = data.azurerm_resource_group.main.name
  for_each            = var.snets.hub
  vnet_name           = module.vnets["hub"].vnet_name # this is you consume outputs from a module.
  address_prefixes    = each.value.address_prefixes
  snet_name           = "${local.snet_name}-${each.key}"
  service_endpoints   = each.value.service_endpoints # null is the default in variables.tf if the snet variable doesn't have this attribute.
  service_delegations = each.value.delegations       # similarily the default is [] for this attribute.
}

# i had to create another hub module cuz of non standard naming convention
module "snets_hub_special" {
  source           = "./modules/subnet"
  rg_name          = data.azurerm_resource_group.main.name
  for_each         = var.snets.hub_special
  vnet_name        = module.vnets["hub"].vnet_name
  address_prefixes = each.value.address_prefixes
  # our special pe child still causing problems!
  snet_name                         = each.key == "pe" ? "${local.snet_name}-${each.key}" : each.key
  private_endpoint_network_policies = each.value.private_endpoint_network_policies
}

# i did not want to bundle all subnets into a single snets module
# just to keep some segragation at vnet level.
module "snets_spoke1" {
  source              = "./modules/subnet"
  rg_name             = data.azurerm_resource_group.main.name
  for_each            = var.snets.spoke1
  vnet_name           = module.vnets["spoke1"].vnet_name
  address_prefixes    = each.value.address_prefixes
  snet_name           = "${local.snet_name}-spoke1-${each.key}"
  service_endpoints   = each.value.service_endpoints
  service_delegations = each.value.delegations
}

module "snets_spoke2" {
  source              = "./modules/subnet"
  rg_name             = data.azurerm_resource_group.main.name
  for_each            = var.snets.spoke2
  vnet_name           = module.vnets["spoke2"].vnet_name
  address_prefixes    = each.value.address_prefixes
  snet_name           = "${local.snet_name}-spoke2-${each.key}"
  service_endpoints   = each.value.service_endpoints
  service_delegations = each.value.delegations
}

module "nsgs" {
  source       = "./modules/nsg"
  rg_name      = data.azurerm_resource_group.main.name
  nsg_location = data.azurerm_resource_group.main.location
  for_each     = { for k, v in var.snets.hub : k => v if v.has_nsg }
  nsg_name     = "${local.nsg_name}-${each.key}"
  # lookup is great for this scenario, it returns {} if the key is not found.
  nsg_sec_rules = lookup(var.nsg_sec_rules, each.key, {})
}

module "nsg_hub_pe" {
  source       = "./modules/nsg"
  rg_name      = data.azurerm_resource_group.main.name
  nsg_location = data.azurerm_resource_group.main.location
  # pe ofc needed its own module due to stupid non standard naming convention.
  # and also the above "nsgs" iterates over var.snets.hub while our
  # pe is in var.snets.hub_special
  nsg_name      = "${local.nsg_name}-hub-pe"
  nsg_sec_rules = lookup(var.nsg_sec_rules, "hub-pe", {})
}

# main.tf at root is the perfect plan to tie different modules together.
# nsg association is one such resource.
resource "azurerm_subnet_network_security_group_association" "hub_pe" {
  network_security_group_id = module.nsg_hub_pe.nsg_id
  subnet_id                 = module.snets_hub_special["pe"].snet_id
}

module "peerings" {
  source   = "./modules/peering"
  rg_name  = data.azurerm_resource_group.main.name
  for_each = var.peerings
  # p1 = peer 1 (in our case hub is always p1); p2 = peer 2 (in our case spokes).
  p1_p2_peering_name = "${local.peering_name}-${each.value.p1}-to-${each.value.p2}"
  p2_p1_peering_name = "${local.peering_name}-${each.value.p2}-to-${each.value.p1}"
  p1_vnet_id         = module.vnets[each.value.p1].vnet_id
  p1_vnet_name       = module.vnets[each.value.p1].vnet_name
  # again all these allow & use attributes are optional. look at the variable declared in
  # both the root as well as in the module.
  allow_virtual_network_access_on_p1 = each.value.allow_virtual_network_access_on_p1
  allow_forwarded_traffic_on_p1      = each.value.allow_forwarded_traffic_on_p1
  allow_gateway_transit_on_p1        = each.value.allow_gateway_transit_on_p1
  use_remote_gateways_on_p1          = each.value.use_remote_gateways_on_p1
  p2_vnet_id                         = module.vnets[each.value.p2].vnet_id
  p2_vnet_name                       = module.vnets[each.value.p2].vnet_name
  allow_virtual_network_access_on_p2 = each.value.allow_virtual_network_access_on_p2
  allow_forwarded_traffic_on_p2      = each.value.allow_forwarded_traffic_on_p2
  allow_gateway_transit_on_p2        = each.value.allow_gateway_transit_on_p2
  use_remote_gateways_on_p2          = each.value.use_remote_gateways_on_p2
}

module "routing" {
  source  = "./modules/routing"
  rg_name = data.azurerm_resource_group.main.name
  # looping over each routing table.
  # this gives us e.g. "module.routing["gw"].azurerm_route_table.rt"
  for_each                      = var.routing_tables
  rt_name                       = "${local.rt_name}-${each.key}"
  location                      = each.value.location
  bgp_route_propagation_enabled = each.value.bgp_route_propagation_enabled
  route_name_prefix             = "route-${each.value.owner}-${each.value.environment}"
  # dumping the entire routes object to the module.
  # this contains all the routes for this instance of table.
  # look at how the module is handling this: it is iterating over the routes
  # and adding each route from the table.
  # all of this i.e. adding a table & adding the routes for that table
  # happens in one pass of module["routing"].
  routes = each.value.routes
  next_hop_ips = {
    hub_fw = local.hub_fw_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "spoke1_workload_to_rt_spoke1" {
  route_table_id = module.routing["spoke1"].rt_id
  subnet_id      = module.snets_spoke1["workload"].snet_id
}

resource "azurerm_subnet_route_table_association" "spoke2_workload_to_rt_spoke2" {
  route_table_id = module.routing["spoke2"].rt_id
  subnet_id      = module.snets_spoke2["workload"].snet_id
}

resource "azurerm_subnet_route_table_association" "gateway_to_rt_gateway" {
  route_table_id = module.routing["gw"].rt_id
  ###---d05ex05 >>>
  # updated value to follow new subnet variable design from d05ex05.
  subnet_id = module.snets_hub_special["GatewaySubnet"].snet_id
  ###---d05ex05 <<<

}

module "dns" {
  source  = "./modules/dns"
  rg_name = data.azurerm_resource_group.main.name
  # note we are iterating over local.dns cuz var.dns can't hold vnet_id.
  for_each       = local.dns
  dns_zone_name  = each.key
  dns_vnet_links = each.value.vnet_links
  # again dumping an object from each dns zone that holds all the vnet_links.
  # the module then has a for loop that iterates over each link.
  dns_vnet_link_prefix = each.key == "privatelink.blob.core.windows.net" ? local.vnetlink_name : local.pdnslink_name

  # tags = local.lab_tags # i forgot to add the tags in my original day 05. tags need to be added later.
}

module "storage_se" {
  source                           = "./modules/storage"
  name                             = local.st_lab_name
  rg_name                          = data.azurerm_resource_group.main.name
  location                         = data.azurerm_resource_group.main.location
  account_tier                     = "Standard"
  account_replication_type         = "LRS"
  account_kind                     = "StorageV2"
  allow_nested_items_to_be_public  = false
  network_rules_default_action     = "Deny"
  network_rules_bypass             = ["AzureServices"]
  network_rules_allowed_subnet_ids = [module.snets_spoke1["workload"].snet_id]

  tags = local.lab_tags
}

# module "storage_pe" {
#   source                             = "./modules/private_endpoint"
#   name                               = "${local.pe_name}-storage"
#   rg_name                            = data.azurerm_resource_group.main.name
#   location                           = data.azurerm_resource_group.main.location
#   subnet_id                          = module.snets_hub_special["pe"].snet_id
#   psc_name                           = "psc-${local.prefix}-storage"
#   psc_private_connection_resource_id = module.storage_se.id
#   psc_subresource_names              = ["blob"]
#   psc_is_manual_connection           = false

#   # tags = local.lab_tags # i forgot to add the tags in my original day 05. tags need to be added later.
# }

# resource "azurerm_private_dns_a_record" "lab_storage_pe" {
#   name                = local.st_lab_name
#   resource_group_name = data.azurerm_resource_group.main.name
#   zone_name           = module.dns["privatelink.blob.core.windows.net"].private_dns_zone_name
#   records             = [module.storage_pe.psc_private_ip_address]
#   ttl                 = 300
# }
