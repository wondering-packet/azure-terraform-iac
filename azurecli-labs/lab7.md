# Lab 7 — Azure Load Balancing Services

**Topic:** Internal Load Balancer (ILB) with HA Ports, Application Gateway (AGW), health probe failover
**Cost:** AGW Standard_v2 ~$0.25/hour — tear down after lab. ILB free.
**Estimated time:** ~1.5 hours
**Persistent:** Nothing — tear down AGW and test VMs after lab.

---

## Subscription

**Subscription name:** Infrastructure Networking Dev/Test
**Subscription ID:** `<your-subscription-id>`

---

## Topology Built

```
Hub VNet
  ├── snet-vg-lab-wus-shared (172.22.2.0/24)
  │     ├── vm-vg-lab-wus-hub1 (172.22.2.5) — nginx backend
  │     ├── vm-vg-lab-wus-hub2 (172.22.2.6) — nginx backend
  │     ├── vm-vg-lab-wus-hub  (172.22.2.4) — client for ILB testing
  │     └── ilb-vg-lab-wus-hub
  │           ├── Frontend IP: 172.22.2.100
  │           ├── Backend pool: hub1 + hub2
  │           ├── HA Ports rule (all ports, all protocols)
  │           └── HTTP probe: port 80, path /
  └── snet-vg-lab-wus-agw (172.22.6.0/24)
        └── agw-vg-lab-wus-hub
              ├── Public IP: pip-vg-lab-wus-agw
              ├── Backend pool: hub1 (172.22.2.5) + hub2 (172.22.2.6)
              ├── HTTP listener: port 80
              └── HTTP probe: port 80, path /
```

---

## Prerequisites

Labs 1-6 complete. VMs and Bastion: see Lab 3 for detailed instructions.

**Backend VM placement:** For this lab, backend VMs must reside in the hub VNet. In the tested NIC-based backend pool configuration, peered spoke VMs could not be added to the ILB backend pool — hub VMs are used as backends instead.

---

## Step 1 — Deploy Backend VMs

Deploy two VMs in hub shared subnet before deploying load balancers — both ILB and AGW share these backends.

```powershell
# Hub VM 1
az vm create `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-hub1 `
  --image Ubuntu2204 `
  --size Standard_B1s `
  --vnet-name vnet-vg-lab-wus-hub `
  --subnet snet-vg-lab-wus-shared `
  --admin-username azureuser `
  --generate-ssh-keys `
  --public-ip-address '""' `
  --nsg '""' `
  --no-wait `
  --tags owner=vg env=lab purpose=networking

# Hub VM 2
az vm create `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-hub2 `
  --image Ubuntu2204 `
  --size Standard_B1s `
  --vnet-name vnet-vg-lab-wus-hub `
  --subnet snet-vg-lab-wus-shared `
  --admin-username azureuser `
  --generate-ssh-keys `
  --public-ip-address '""' `
  --nsg '""' `
  --no-wait `
  --tags owner=vg env=lab purpose=networking
```

Set passwords for Bastion access (see Lab 3 for details).

Check assigned IPs once provisioned:
```powershell
az vm list-ip-addresses `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-hub1 `
  --query "[].virtualMachine.network.privateIpAddresses" `
  --output tsv

az vm list-ip-addresses `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-hub2 `
  --query "[].virtualMachine.network.privateIpAddresses" `
  --output tsv
```

In this lab: hub1 → `172.22.2.5`, hub2 → `172.22.2.6`.

---

## Step 2 — Install nginx on Backend VMs

Connect to each VM via Bastion and run:

```bash
sudo apt update && sudo apt install -y nginx

# Customize response page to identify which backend responded
echo "<h1>Response from hub1</h1>" | sudo tee /var/www/html/index.html

sudo systemctl status nginx
```

Do the same on hub2 with `<h1>Response from hub2</h1>`.

Custom index pages are essential — without unique responses per backend you cannot confirm load distribution is working.

**Note:** Hub shared subnet has no route table — `0.0.0.0/0` goes directly to internet. No Firewall needed for nginx install.

---

## Step 3 — Deploy Internal Load Balancer

```powershell
# Create ILB with frontend IP
az network lb create `
  --resource-group rg-vg-lab-wus-01 `
  --name ilb-vg-lab-wus-hub `
  --location westus `
  --sku Standard `
  --vnet-name vnet-vg-lab-wus-hub `
  --subnet snet-vg-lab-wus-shared `
  --frontend-ip-name feip-vg-lab-wus-ilb `
  --private-ip-address 172.22.2.100 `
  --backend-pool-name bepool-vg-lab-wus-ilb `
  --tags owner=vg env=lab purpose=networking

# Add health probe
az network lb probe create `
  --resource-group rg-vg-lab-wus-01 `
  --lb-name ilb-vg-lab-wus-hub `
  --name probe-vg-lab-wus-http `
  --protocol Http `
  --port 80 `
  --path /

# Add HA Ports rule
az network lb rule create `
  --resource-group rg-vg-lab-wus-01 `
  --lb-name ilb-vg-lab-wus-hub `
  --name rule-vg-lab-wus-haports `
  --protocol All `
  --frontend-port 0 `
  --backend-port 0 `
  --frontend-ip-name feip-vg-lab-wus-ilb `
  --backend-pool-name bepool-vg-lab-wus-ilb `
  --probe-name probe-vg-lab-wus-http
```

**HA Ports explained:** `--frontend-port 0` and `--backend-port 0` means all ports. Combined with `--protocol All`, this forwards every protocol on every port to the backend pool. Azure's way of expressing `0/0` for ports — `*` is not valid in CLI for port numbers. HA Ports is ILB-only — not available on public Load Balancer. Designed for NVA scale-out scenarios where all traffic types need to be distributed.

---

## Step 4 — Add VMs to ILB Backend Pool

```powershell
az network nic ip-config address-pool add `
  --resource-group rg-vg-lab-wus-01 `
  --nic-name vm-vg-lab-wus-hub1VMNic `
  --ip-config-name ipconfigvm-vg-lab-wus-hub1 `
  --lb-name ilb-vg-lab-wus-hub `
  --address-pool bepool-vg-lab-wus-ilb

az network nic ip-config address-pool add `
  --resource-group rg-vg-lab-wus-01 `
  --nic-name vm-vg-lab-wus-hub2VMNic `
  --ip-config-name ipconfigvm-vg-lab-wus-hub2 `
  --lb-name ilb-vg-lab-wus-hub `
  --address-pool bepool-vg-lab-wus-ilb
```

If ip-config-name is unknown:
```powershell
az network nic show `
  --resource-group rg-vg-lab-wus-01 `
  --name vm-vg-lab-wus-hub1VMNic `
  --query "ipConfigurations[0].name" `
  --output tsv
```

Verify both added:
```powershell
az network lb address-pool show `
  --resource-group rg-vg-lab-wus-01 `
  --lb-name ilb-vg-lab-wus-hub `
  --name bepool-vg-lab-wus-ilb `
  --query "backendIPConfigurations[*].id" `
  --output table
```

---

## Step 5 — Test ILB from Hub VM

Start the original hub VM (`vm-vg-lab-wus-hub`) — use it as the client for ILB testing.

Connect via Bastion and run:

```bash
curl http://172.22.2.100
curl http://172.22.2.100
curl http://172.22.2.100
curl http://172.22.2.100
```

Expected: responses served by one of the backend VMs. Load distribution is based on a hash of the connection tuple. Repeated requests from a single client may continue to hit the same backend, especially when connection reuse occurs. In production with many different clients, distribution appears even across backends.

---

## Step 6 — ILB Health Probe Failover Test

Stop nginx on hub1 via Bastion:
```bash
sudo systemctl stop nginx
```

Wait ~30 seconds (default: 2 failed probes × 15 second interval).

From hub VM:
```bash
curl http://172.22.2.100
curl http://172.22.2.100
curl http://172.22.2.100
```

Expected: all responses from hub2 only — hub1 removed from rotation after probe failure.

**Check backend health state:**
Standard Load Balancer doesn't provide the same straightforward backend health CLI experience as Application Gateway. Portal health views and Azure Monitor metrics are usually the easiest way to verify backend state:
- **Portal** — `ilb-vg-lab-wus-hub` → Backend pools → `bepool-vg-lab-wus-ilb` → health state column
- **Azure Monitor metric** — `DipAvailability`: 100 = healthy, 0 = unhealthy

Restore nginx after test:
```bash
sudo systemctl start nginx
```

---

## Step 7 — Create AGW Subnet

Application Gateway requires a dedicated subnet — cannot share with other resources.

```powershell
az network vnet subnet create `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name snet-vg-lab-wus-agw `
  --address-prefix 172.22.6.0/24
```

---

## Step 8 — Create Public IP for AGW

```powershell
az network public-ip create `
  --resource-group rg-vg-lab-wus-01 `
  --name pip-vg-lab-wus-agw `
  --location westus `
  --sku Standard `
  --allocation-method Static `
  --tags owner=vg env=lab purpose=networking
```

---

## Step 9 — Deploy Application Gateway

AGW v2 takes ~5-10 minutes to provision. Fire with `--no-wait`:

```powershell
az network application-gateway create `
  --resource-group rg-vg-lab-wus-01 `
  --name agw-vg-lab-wus-hub `
  --location westus `
  --sku Standard_v2 `
  --capacity 1 `
  --vnet-name vnet-vg-lab-wus-hub `
  --subnet snet-vg-lab-wus-agw `
  --public-ip-address pip-vg-lab-wus-agw `
  --frontend-port 80 `
  --http-settings-port 80 `
  --http-settings-protocol Http `
  --routing-rule-type Basic `
  --priority 100 `
  --no-wait `
  --tags owner=vg env=lab purpose=networking
```

Verify provisioning:
```powershell
az network application-gateway show `
  --resource-group rg-vg-lab-wus-01 `
  --name agw-vg-lab-wus-hub `
  --query "{state:provisioningState}" `
  --output json
```

---

## Step 10 — Add VMs to AGW Backend Pool

```powershell
az network application-gateway address-pool update `
  --resource-group rg-vg-lab-wus-01 `
  --gateway-name agw-vg-lab-wus-hub `
  --name appGatewayBackendPool `
  --servers 172.22.2.5 172.22.2.6
```

Get AGW public IP:
```powershell
az network public-ip show `
  --resource-group rg-vg-lab-wus-01 `
  --name pip-vg-lab-wus-agw `
  --query ipAddress `
  --output tsv
```

---

## Step 11 — Test AGW from Browser

Open in browser: `http://<agw-public-ip>`

Expected: response from one of the backend VMs. Refresh to see distribution across backends.

**Check backend health if 502 error:**
```powershell
az network application-gateway show-backend-health `
  --resource-group rg-vg-lab-wus-01 `
  --name agw-vg-lab-wus-hub `
  --output json
```

If backends show `Unhealthy` — connect to the VM via Bastion and verify `sudo systemctl status nginx`.

---

## Step 12 — AGW Health Probe Failover Test

Stop nginx on hub1 via Bastion:
```bash
sudo systemctl stop nginx
```

Wait ~90 seconds (default: 3 failed probes × 30 second interval).

Refresh browser — expected: only `Response from hub2`.

**AGW vs ILB failover speed:**

| | Azure Load Balancer | Application Gateway |
|---|---|---|
| Default probe interval | 15 seconds | 30 seconds |
| Default failure threshold | 2 probes | 3 probes |
| Default failover time | ~30 seconds | ~90 seconds |

AGW failover is slower by default. Tune with a custom probe for faster detection:

```powershell
az network application-gateway probe create `
  --resource-group rg-vg-lab-wus-01 `
  --gateway-name agw-vg-lab-wus-hub `
  --name probe-vg-lab-wus-fast `
  --protocol Http `
  --host-name-from-http-settings true `
  --path / `
  --interval 10 `
  --threshold 2 `
  --timeout 10
```

With custom probe: 10s × 2 = ~20 second failover.

Restore nginx after test:
```bash
sudo systemctl start nginx
```

---

## Teardown

```powershell
# Delete AGW and public IP
az network application-gateway delete `
  --resource-group rg-vg-lab-wus-01 `
  --name agw-vg-lab-wus-hub `
  --no-wait

az network public-ip delete `
  --resource-group rg-vg-lab-wus-01 `
  --name pip-vg-lab-wus-agw

# Delete ILB
az network lb delete `
  --resource-group rg-vg-lab-wus-01 `
  --name ilb-vg-lab-wus-hub

# Delete backend VMs
az vm delete --resource-group rg-vg-lab-wus-01 --name vm-vg-lab-wus-hub1 --yes --no-wait
az vm delete --resource-group rg-vg-lab-wus-01 --name vm-vg-lab-wus-hub2 --yes --no-wait

# After VMs deleted — remove NICs and disks
az network nic delete --resource-group rg-vg-lab-wus-01 --name vm-vg-lab-wus-hub1VMNic
az network nic delete --resource-group rg-vg-lab-wus-01 --name vm-vg-lab-wus-hub2VMNic

# Get exact disk names then delete
az disk list `
  --resource-group rg-vg-lab-wus-01 `
  --query "[?contains(name, 'hub1') || contains(name, 'hub2')].name" `
  --output table

az disk delete --resource-group rg-vg-lab-wus-01 --name <hub1-disk-name> --yes
az disk delete --resource-group rg-vg-lab-wus-01 --name <hub2-disk-name> --yes
```

---

## Key Observations from This Lab

1. **Backend VM placement for this lab** — in this lab's Standard Load Balancer NIC-based backend pool configuration, peered spoke VMs could not be added to the ILB backend pool. Backend VMs must reside in the hub VNet.
2. **HA Ports is ILB-only** — not available on public Load Balancer. Port 0 + Protocol All = all ports/protocols. Used for NVA scale-out where all traffic types need distribution.
3. **Standard Load Balancer backend health visibility** — doesn't provide the same straightforward CLI experience as AGW. Use portal health views or Azure Monitor `DipAvailability` metric.
4. **5-tuple hash distribution** — load distribution is based on a hash of the connection tuple. Repeated requests from a single client may continue to hit the same backend, especially when connection reuse occurs. Not a misconfiguration — expected behavior.
5. **AGW default failover ~90 seconds** — 3 probes × 30 second interval. Tune with custom probe for faster detection (10s × 2 = ~20 seconds).
6. **ILB default failover ~30 seconds** — 2 probes × 15 second interval. Faster than AGW by default.
7. **AGW requires dedicated subnet** — cannot share with other resources. Minimum /28, recommended /24.
8. **Custom index pages essential for testing** — without unique responses per backend you cannot confirm load distribution is working.
9. **Hub shared subnet has no route table** — internet access works directly without Firewall. Spoke subnets with UDRs pointing at Firewall IP will black hole internet traffic if Firewall is down.