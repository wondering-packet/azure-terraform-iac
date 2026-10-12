locals {
  lab_tags = {
    env        = local.environment
    managed_by = "terraform"
    owner      = var.owner
    purpose    = "networking"
    tf_stack   = var.tf_stack
  }

  region_code = var.location == "westus" ? "wus" : "eus"

  environment         = terraform.workspace == "default" ? "lab" : terraform.workspace
  prefix              = "${var.owner}-${local.environment}-${local.region_code}"
  vnet_name           = "vnet-${local.prefix}"
  rg_name             = "rg-${local.prefix}"
  nsg_name            = "nsg-${local.prefix}"
  peering_name        = "peer-${local.prefix}"                       # added in d04ex02
  rt_name             = "rt-${local.prefix}"                         # added in d04ex03
  route_name          = "route-${var.owner}-${local.environment}"    # added in d04ex03
  pdnslink_name       = "pdnslink-${var.owner}-${local.environment}" # added in d04ex05
  dnsresolver_name    = "dnsresolver-${local.prefix}"                # added in d04ex07
  fwrule_name         = "fwrule-${local.prefix}"                     # added in d04ex07
  vnetlink_name       = "vnetlink-${local.prefix}"                   # added in d04ex07. realized i should have used pdslink instead.
  st_lab_name         = "stvglabwus01"                               # added in d05ex01, storage account name can't have hyphens etc.
  nic_name            = "nic-${local.prefix}"                        # added in d05-test_vms
  vm_name             = "vm-${local.prefix}"                         # added in d05-test_vms
  bastion_name        = "bastion-${local.prefix}"                    # added in d05-test_bastion
  pe_name             = "pe-${local.prefix}"                         # added in d05ex03-pe
  snet_name           = "snet-${local.prefix}"
  lb_name             = "lb-${local.prefix}"        # added in d09ex02
  lb_be_pool_name     = "bepool-lb-${local.prefix}" # added in d09ex02
  lb_probe_name       = "probe-lb-${local.prefix}"  # added in d09ex02
  lb_feip_config_name = "feip-lb-${local.prefix}"   # added in d09ex02
  lb_rule_name        = "rule-lb-${local.prefix}"   # added in d09ex03
  agw_name            = "agw-${local.prefix}"       # added in d09ex04
  pip_name            = "pip-${local.prefix}"       # added in d09ex04

  lb_backend_vms = {
    "${local.lb_name}-hub-vms" = {
      "${local.vm_name}-hub1" = {
        snet_id                      = data.terraform_remote_state.base.outputs.hub_subnet_ids["shared"]
        private_ip_address           = "172.22.2.5"
        location                     = var.location
        rg_name                      = data.azurerm_resource_group.main.name
        admin_password               = var.test_vm_admin_password
        custom_data_nginx_page_label = "hub1"
      }
      "${local.vm_name}-hub2" = {
        snet_id                      = data.terraform_remote_state.base.outputs.hub_subnet_ids["shared"]
        private_ip_address           = "172.22.2.6"
        location                     = var.location
        rg_name                      = data.azurerm_resource_group.main.name
        admin_password               = var.test_vm_admin_password
        custom_data_nginx_page_label = "hub2"
      }
    }
  }

  load_balancers = {
    "${local.lb_name}-hub" = {
      rg_name  = data.azurerm_resource_group.main.name
      location = var.location
      sku      = "Standard"
      lb_be_pool = {
        name = "${local.lb_be_pool_name}-hub"
      }
      lb_probe = {
        name         = "${local.lb_probe_name}-hub"
        port         = 80
        protocol     = "Http"
        request_path = "/"
      }
      frontend_ip_configuration = {
        name                          = "${local.lb_feip_config_name}-hub"
        subnet_id                     = data.terraform_remote_state.base.outputs.hub_subnet_ids["shared"]
        private_ip_address            = "172.22.2.100"
        private_ip_address_allocation = "Static"
      }
      lb_be_nic_associations = {
        for vm_name, value in local.lb_backend_vms["${local.lb_name}-hub-vms"] :
        vm_name => {
          network_interface_id  = module.hub_lb_backend_vms[vm_name].vm_nic_id
          ip_configuration_name = module.hub_lb_backend_vms[vm_name].ipconfig_name
        }
      }
      lb_rule = {
        name          = "${local.lb_rule_name}-hub"
        frontend_port = 0
        backend_port  = 0
        protocol      = "All"
      }

    }
  }

  app_gateways = {
    "${local.agw_name}-hub" = {
      pip = {
        name              = "${local.pip_name}-agw"
        allocation_method = "Static"
      }
      gateway_ip_configuration = {
        subnet_id = data.terraform_remote_state.base.outputs.agw_subnet_id
      }
      backend_address_pool = {
        ip_addresses = [
          for each_backend, value in local.lb_backend_vms["${local.lb_name}-hub-vms"] :
          value["private_ip_address"]
        ]
      }
    }
  }
}
