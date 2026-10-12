data "azurerm_resource_group" "main" {
  name = "${local.rg_name}-01"
}

module "hub_lb_backend_vms" {
  source                       = "./modules/test_linux_vm"
  for_each                     = local.lb_backend_vms["${local.lb_name}-hub-vms"]
  name                         = each.key
  snet_id                      = each.value.snet_id
  private_ip_address           = each.value.private_ip_address
  location                     = each.value.location
  rg_name                      = each.value.rg_name
  admin_password               = each.value.admin_password
  custom_data_nginx_page_label = each.value.custom_data_nginx_page_label
  tags                         = local.lab_tags
}

module "load_balancers" {
  source                    = "./modules/load_balancer"
  for_each                  = local.load_balancers
  lb_name                   = each.key
  rg_name                   = each.value.rg_name
  sku                       = each.value.sku
  location                  = each.value.location
  lb_be_pool                = each.value.lb_be_pool
  lb_probe                  = each.value.lb_probe
  frontend_ip_configuration = each.value.frontend_ip_configuration
  lb_be_nic_associations    = each.value.lb_be_nic_associations
  lb_rule                   = each.value.lb_rule
}

module "agw" {
  source                   = "./modules/app_gw"
  rg_name                  = data.azurerm_resource_group.main.name
  location                 = data.azurerm_resource_group.main.location
  for_each                 = local.app_gateways
  agw_name                 = each.key
  pip                      = each.value.pip
  gateway_ip_configuration = each.value.gateway_ip_configuration
  backend_address_pool     = each.value.backend_address_pool
  tags                     = local.lab_tags
}
