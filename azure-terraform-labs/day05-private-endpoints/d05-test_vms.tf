resource "azurerm_network_interface" "test" {
  for_each            = var.enable_test_vms ? var.test_vms : {}
  name                = "${local.nic_name}-${each.key}-test"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.test_vms_subnet_ids[each.key]
    private_ip_address_allocation = "Static" # static, per IP schema
    private_ip_address            = each.value.private_ip
  }
}

resource "azurerm_linux_virtual_machine" "test" {
  for_each                        = var.enable_test_vms ? var.test_vms : {}
  name                            = "${local.vm_name}-${each.key}"
  location                        = data.azurerm_resource_group.main.location
  resource_group_name             = data.azurerm_resource_group.main.name
  size                            = "Standard_B1s"
  admin_username                  = "azureuser"
  admin_password                  = var.vm_admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.test[each.key].id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
  boot_diagnostics {}
  tags = local.lab_tags

  lifecycle {
    # i had add this block cuz without it, 
    # i will have to set env variable for password in every new shell.
    # if i don't set the env variable then terraform assumes a destroy
    # operation since password changes to 'null'.
    ignore_changes = [admin_password]
  }
}
