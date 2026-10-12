resource "azurerm_firewall_policy" "main" {
  name                = local.fwpol_name
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  sku                 = "Standard"
  tags                = local.lab_tags
}

resource "azurerm_firewall_policy_rule_collection_group" "main_100" {
  name               = "${local.fwrcg_name}-main"
  firewall_policy_id = azurerm_firewall_policy.main.id
  priority           = 100
  network_rule_collection {
    name     = "${local.fwnetcol_name}-allow"
    priority = 100
    action   = "Allow"
    rule {
      name                  = "allow-spoke1-to-pe"
      protocols             = ["TCP"]
      destination_ports     = ["443"]
      source_addresses      = [data.azurerm_subnet.spoke1_workload.address_prefixes[0]]
      destination_addresses = [data.terraform_remote_state.base.outputs.storage_pe_private_ip]
    }
    rule {
      name                  = "allow-spoke2-to-rfc1918"
      protocols             = ["TCP"]
      source_addresses      = [data.azurerm_subnet.spoke2_workload.address_prefixes[0]]
      destination_addresses = local.rfc1918_address
      destination_ports     = ["*"]
    }
    rule {
      name                  = "allow-spoke1workload-to-spoke2workload"
      protocols             = ["Any"]
      source_addresses      = [data.azurerm_subnet.spoke1_workload.address_prefixes[0]]
      destination_addresses = [data.azurerm_subnet.spoke2_workload.address_prefixes[0]]
      destination_ports     = ["*"]
    }
  }
  application_rule_collection {
    name     = "${local.fwappcol_name}-allow"
    action   = "Allow"
    priority = 200
    rule {
      name = "allow-spoke1-github"
      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }
      destination_fqdns = ["github.com", "*.github.com"]
      source_addresses  = [data.azurerm_subnet.spoke1_workload.address_prefixes[0]]
    }
    # below rule was added for testing the storage pe with app rules
    # but due to issues with dns proxy & need to modify nsg, it was dropped.
    # rule {
    #   name = "allow-spoke1-pe-app"
    #   protocols {
    #     type = "Http"
    #     port = 80
    #   }
    #   protocols {
    #     type = "Https"
    #     port = 443
    #   }
    #   destination_fqdns = ["stvglabwus01.blob.core.windows.net", "*.stvglabwus01.blob.core.windows.net"]
    #   source_addresses  = [data.azurerm_subnet.spoke1_workload.address_prefixes[0]]
    # }
  }
  network_rule_collection {
    name     = "${local.fwnetcol_name}-deny"
    action   = "Deny"
    priority = 300
    rule {
      name                  = "deny-spoke2-to-internet"
      protocols             = ["Any"]
      destination_ports     = ["*"]
      destination_addresses = ["*"]
      source_addresses      = [data.azurerm_subnet.spoke2_workload.address_prefixes[0]]
    }
  }
  nat_rule_collection {
    name     = local.fwnatcol_name
    action   = "Dnat"
    priority = 150
    rule {
      name                = "dnat-ssh-spoke1"
      protocols           = ["TCP"]
      source_addresses    = var.lab_public_ip
      destination_address = azurerm_public_ip.fw.ip_address
      translated_address  = local.spoke1_workload_vm_ip
      translated_port     = 22
      destination_ports   = ["2222"]
    }
  }
}
