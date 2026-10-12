resource "azurerm_subnet_route_table_association" "spoke1_workload_to_rt_spoke1" {
  route_table_id = azurerm_route_table.rt_spoke1.id
  subnet_id      = azurerm_subnet.spoke1.id
}

resource "azurerm_subnet_route_table_association" "spoke2_workload_to_rt_spoke2" {
  route_table_id = azurerm_route_table.rt_spoke2.id
  subnet_id      = azurerm_subnet.spoke2.id
}

resource "azurerm_subnet_route_table_association" "gateway_to_rt_gateway" {
  route_table_id = azurerm_route_table.rt_gateway.id
  ###---d05ex05 >>>
  # updated value to follow new subnet variable design from d05ex05.
  subnet_id = azurerm_subnet.hub_gateway.id
  ###---d05ex05 <<<

}
