# Lab-Power.ps1  —  .\Lab-Power.ps1 -Action Start   |   -Action Stop
param([Parameter(Mandatory)][ValidateSet('Start','Stop')]$Action)
$rg  = 'rg-vg-lab-wus-01'
$vms = @('vm-vg-lab-wus-spoke1','vm-vg-lab-wus-spoke2','vm-vg-lab-wus-hub')
foreach ($vm in $vms) {
  if ($Action -eq 'Start') { az vm start     --resource-group $rg --name $vm --no-wait }
  else                     { az vm deallocate --resource-group $rg --name $vm --no-wait }  # deallocate: compute billing stops, disk/NIC kept
}