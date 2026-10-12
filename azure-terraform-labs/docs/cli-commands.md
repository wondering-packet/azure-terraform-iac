# Azure CLI Commands (PowerShell) — verification helpers

Use these to verify what Terraform deployed. Reader role on your individual
account is enough for all of these. Always use backtick (`) for line continuation.

## Auth / context
```powershell
az login --service-principal `
  --username <client-id> `
  --password <client-secret> `
  --tenant <tenant-id>

az account show --output table
az account list --output table
```

## Verify networking
```powershell
# VNets and subnets
az network vnet list -g rg-vg-lab-wus-01 --output table
az network vnet subnet list `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub --output table

# NSGs and rules
az network nsg list -g rg-vg-lab-wus-01 --output table
az network nsg rule list `
  --resource-group rg-vg-lab-wus-01 `
  --nsg-name nsg-vg-lab-wus-web --output table

# Peering status
az network vnet peering list `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub --output table

# Effective routes on a NIC (BGP-learned routes show here, not in route table view)
az network nic show-effective-route-table `
  --resource-group rg-vg-lab-wus-01 `
  --name <nic-name> --output table
```

## Role assignments (confirm SP scope)
```powershell
az role assignment list `
  --assignee <client-id> --all --output table
```
