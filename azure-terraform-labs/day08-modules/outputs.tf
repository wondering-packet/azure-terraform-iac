###---d03ex05 >>>
output "hub_vnet_id" { # renamed from "vnet_id" to "hub_vnet_id"
  value       = module.vnets["hub"].vnet_id
  description = "Resource ID of the hub VNet"
}

output "hub_subnet_ids" { # renamed from "subnet_ids" to "hub_subnet_ids"
  value       = { for k, v in module.snets_hub : k => v.snet_id }
  description = "Map of subnet name to subnet resource ID in hub"
}

output "gateway_subnet_id" {
  ###---d05ex05 >>>
  # updated value to follow new subnet variable design from d05ex05.
  value = module.snets_hub_special["GatewaySubnet"].snet_id
  ###---d05ex05 <<<
  description = "Subnet ID of Gateway subnet in hub"
}

output "firewall_subnet_id" {
  ###---d05ex05 >>>
  # updated value to follow new subnet variable design from d05ex05.
  value = module.snets_hub_special["AzureFirewallSubnet"].snet_id
  ###---d05ex05 <<<
  description = "Subnet ID of AzureFirewall subnet in hub"
}

output "pe_subnet_id" {
  ###---d05ex05 >>>
  # updated value to follow new subnet variable design from d05ex05.
  value = module.snets_hub_special["pe"].snet_id
  ###---d05ex05 <<<
  description = "Subnet ID of snet-vg-lab-wus-pe subnet in hub"
}

output "agw_subnet_id" {
  value       = module.snets_hub["agw"].snet_id
  description = "Subnet ID of snet-vg-lab-wus-agw subnet in hub"
}

output "dns_inbound_subnet_id" {
  value       = module.snets_hub["dns-inbound"].snet_id
  description = "Subnet ID of snet-vg-lab-wus-dns-inbound subnet in hub"
}

output "dns_outbound_subnet_id" {
  value       = module.snets_hub["dns-outbound"].snet_id
  description = "Subnet ID of snet-vg-lab-wus-dns-outbound subnet in hub"
}

output "spoke1_vnet_id" {
  value       = module.vnets["spoke1"].vnet_id
  description = "Resource ID of the spoke1 VNet"
}

output "spoke1_workload_subnet_id" {
  value       = module.snets_spoke1["workload"].snet_id
  description = "Map of subnet name to subnet resource ID in spoke1"
}

output "spoke2_vnet_id" {
  value       = module.vnets["spoke2"].vnet_id
  description = "Resource ID of the spoke2 VNet"
}

output "spoke2_workload_subnet_id" {
  value       = module.snets_spoke2["workload"].snet_id
  description = "Map of subnet name to subnet resource ID in spoke2"
}
###---d03ex05 <<<

output "vnet_address_space" {
  value       = module.vnets["hub"].vnet_address_space
  description = "Full address space owned by hub vnet"
}

output "vnet_primary_cidr" {
  value = module.vnets["hub"].vnet_primary_cidr
}

###---d04ex06 >>>

output "route_table_ids" {
  value = {
    gw     = module.routing["gw"].rt_id,
    spoke1 = module.routing["spoke1"].rt_id,
    spoke2 = module.routing["spoke2"].rt_id
  }
}

###---d04ex06 <<<

###---d05ex06 >>>
# output "storage_pe_id" {
#   value       = module.storage_pe.pe_id
#   description = "id of storage PE in hub"
# }
# output "storage_pe_private_ip" {
#   value       = module.storage_pe.psc_private_ip_address
#   description = "ip address of storage PE in hub"
# }
output "storage_account_id" {
  value       = module.storage_se.id
  description = "id of lab storage account hub"
}
output "storage_privatelink_zone_id" {
  value       = module.dns["privatelink.blob.core.windows.net"].private_dns_zone_id
  description = "id of storage PE's privatelink dns zone"
}
###---d05ex06 <<<
