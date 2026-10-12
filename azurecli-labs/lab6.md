# Lab 6 — Azure Firewall

**Topic:** Azure Firewall deployment, rule collections, DNAT, inter-spoke inspection
**Cost:** ~$1.25/hour Standard SKU — deploy, test, tear down same session.
**Estimated time:** ~2 hours (includes ~30 min wait for ip-config provisioning)
**Persistent:** Firewall Policy + rules (free) — keep. Azure Firewall — tear down after lab.

---

## Subscription

**Subscription name:** Infrastructure Networking Dev/Test
**Subscription ID:** `<your-subscription-id>`

---

## Environment Notes

**azure-firewall CLI extension required.** Install before running any firewall commands. Zscaler SSL workaround needed during install:

```powershell
$env:AZURE_CLI_DISABLE_CONNECTION_VERIFICATION = "1"
az extension add --name azure-firewall
Remove-Item Env:\AZURE_CLI_DISABLE_CONNECTION_VERIFICATION
```

---

## Topology Built

```
Hub VNet
  └── AzureFirewallSubnet (172.22.1.0/26)
        └── fw-vg-lab-wus-hub → 172.22.1.4
              └── fwpol-vg-lab-wus
                    └── fwrcg-vg-lab-wus-main (priority 100)
                          ├── fwnetcol-vg-lab-wus-allow (priority 100, Allow)
                          │     ├── allow-spoke1-to-pe
                          │     ├── allow-spoke2-to-rfc1918
                          │     └── allow-spoke1workload-to-spoke2workload
                          ├── fwappcol-vg-lab-wus-allow (priority 200, Allow)
                          │     └── allow-spoke1-to-github
                          └── fwnetcol-vg-lab-wus-deny (priority 300, Deny)
                                └── deny-spoke2-to-internet

Spoke1 route table additions:
  └── route-vg-lab-pe: 172.22.3.0/24 → 172.22.1.4

VNet Peering updates (required for inter-spoke via Firewall):
  └── All peerings: allowForwardedTraffic=true
  └── Spoke peerings: useRemoteGateways=false
```

---

## Prerequisites

Labs 1-5 complete. Verify AzureFirewallSubnet exists:
```powershell
az network vnet subnet show `
  --resource-group rg-vg-lab-wus-01 `
  --name AzureFirewallSubnet `
  --vnet-name vnet-vg-lab-wus-hub `
  --query "{prefix:addressPrefix}" `
  --output tsv
```

Expected: `172.22.1.0/26`

VMs and Bastion: see Lab 3 for detailed instructions.

---

## Rule Processing — Key Concepts

Rule type always takes precedence over RCG priority:
```
0. Threat Intelligence (if enabled) — always evaluated first
1. DNAT pass    — all RCGs by priority → collections by priority → rules
2. Network pass — all RCGs by priority → collections by priority → rules
3. Application pass — all RCGs by priority → collections by priority → rules
4. Implicit Deny — no match in any pass
```

A network rule in RCG priority 500 is evaluated before an application rule in RCG priority 100 — because the entire network pass completes before the application pass begins.

**Rules have no action** — rules define match criteria only. Action (Allow/Deny) belongs to the Rule Collection. RCGs are containers with priority only — no action.

**Priority namespaces are per rule type** — DNAT, network, and application rules each have independent priority namespaces. Priority 100 in network rules does not conflict with priority 100 in application rules.

---

## Enterprise Firewall Priority Design

In production, organize collections by function with deliberate priority spacing:

```
Network Rule Collections:
  Priority 100 — Deny-Critical        (explicit deny for high-risk traffic)
  Priority 200 — Allow-Infrastructure (AD, DNS, management)
  Priority 300 — Allow-SharedServices (internal services)
  Priority 400 — Allow-Internet       (permitted outbound)
  Priority 500 — Deny-Everything      (explicit catch-all deny for logging)

Application Rule Collections:
  Priority 100 — Allow-Microsoft      (O365, Azure services)
  Priority 200 — Allow-Approved-SaaS  (approved business apps)
  Priority 300 — Deny-Explicit        (specific FQDN blocks)
```

Key principle: deny rules only need higher priority than allow rules when **the same traffic** could match both. Different source CIDRs never conflict regardless of priority order.

---

## Step 1 — Create Public IP

```powershell
az network public-ip create `
  --resource-group rg-vg-lab-wus-01 `
  --name pip-vg-lab-wus-fw `
  --location westus `
  --sku Standard `
  --allocation-method Static `
  --tags owner=vg env=lab purpose=networking
```

---

## Step 2 — Create Firewall Policy

```powershell
az network firewall policy create `
  --resource-group rg-vg-lab-wus-01 `
  --name fwpol-vg-lab-wus `
  --location westus `
  --sku Standard `
  --tags owner=vg env=lab purpose=networking
```

---

## Step 3 — Deploy Azure Firewall (Two-Step Process)

**Note:** In this lab environment, the most reliable deployment method was creating the Firewall first and then attaching the IP configuration separately. This may be a CLI version or extension-specific behavior — if `--vnet-name` and `--public-ip` work correctly on `firewall create` in your environment, the separate `ip-config create` step may not be needed. Always verify `ipConfigurations` is populated after create.

```powershell
# Step 3a — Create Firewall resource (completes quickly)
az network firewall create `
  --resource-group rg-vg-lab-wus-01 `
  --name fw-vg-lab-wus-hub `
  --location westus `
  --firewall-policy fwpol-vg-lab-wus `
  --tags owner=vg env=lab purpose=networking

# Step 3b — Attach IP configuration (~30 minutes to provision)
az network firewall ip-config create `
  --resource-group rg-vg-lab-wus-01 `
  --firewall-name fw-vg-lab-wus-hub `
  --name fwipconf-vg-lab-wus `
  --public-ip-address pip-vg-lab-wus-fw `
  --vnet-name vnet-vg-lab-wus-hub
```

**Note:** Step 3b takes approximately 30 minutes to complete. Fire it off and work on other steps (diagnostics setup, rule planning) while it provisions.

**Verify private IP assigned (poll until Succeeded):**
```powershell
az network firewall show `
  --resource-group rg-vg-lab-wus-01 `
  --name fw-vg-lab-wus-hub `
  --query "{state:provisioningState, privateIp:ipConfigurations[0].privateIPAddress}" `
  --output json
```

Expected: `privateIp: 172.22.1.4` — In this lab deployment Azure Firewall received `172.22.1.4`, which is commonly the first assignable address in `AzureFirewallSubnet`. Verify the actual assigned IP before using it in UDRs.

---

## Step 4 — Set Up Diagnostics

Set up while Firewall is provisioning. Required for querying rule hit logs.

### Create Log Analytics Workspace
```powershell
az monitor log-analytics workspace create `
  --resource-group rg-vg-lab-wus-01 `
  --workspace-name law-vg-lab-wus `
  --location westus `
  --tags owner=vg env=lab purpose=networking
```

### Capture Resource IDs
```powershell
$lawId = az monitor log-analytics workspace show `
  --resource-group rg-vg-lab-wus-01 `
  --workspace-name law-vg-lab-wus `
  --query id --output tsv

$fwId = az network firewall show `
  --resource-group rg-vg-lab-wus-01 `
  --name fw-vg-lab-wus-hub `
  --query id --output tsv
```

### Create Diagnostic Settings
```powershell
$logs = '[{"category":"AzureFirewallApplicationRule","enabled":true},{"category":"AzureFirewallNetworkRule","enabled":true},{"category":"AzureFirewallDnsProxy","enabled":true}]'
$metrics = '[{"category":"AllMetrics","enabled":true}]'

az monitor diagnostic-settings create `
  --name diag-fw-vg-lab-wus `
  --resource $fwId `
  --workspace $lawId `
  --logs $logs `
  --metrics $metrics
```

---

## Step 5 — Create Rule Collection Group

```powershell
az network firewall policy rule-collection-group create `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --name fwrcg-vg-lab-wus-main `
  --priority 100
```

---

## Step 6 — Add Network Allow Rule Collection

```powershell
az network firewall policy rule-collection-group collection add-filter-collection `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rule-collection-group-name fwrcg-vg-lab-wus-main `
  --name fwnetcol-vg-lab-wus-allow `
  --collection-priority 100 `
  --action Allow `
  --rule-type NetworkRule `
  --rule-name allow-spoke1-to-pe `
  --source-addresses 172.22.16.0/24 `
  --destination-addresses 172.22.3.4 `
  --destination-ports 443 `
  --ip-protocols TCP
```

**Add additional rules to an existing network collection (skeleton):**
```powershell
az network firewall policy rule-collection-group collection rule add `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rcg-name fwrcg-vg-lab-wus-main `
  --collection-name fwnetcol-vg-lab-wus-allow `
  --rule-type NetworkRule `
  --name <rule-name> `
  --source-addresses <source-cidr> `
  --destination-addresses <dest-cidr-1> <dest-cidr-2> `
  --destination-ports <port-or-*> `
  --ip-protocols <TCP|UDP|Any>
```

**Lab rules — add to allow collection:**
```powershell
# Allow spoke2 to RFC1918
az network firewall policy rule-collection-group collection rule add `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rcg-name fwrcg-vg-lab-wus-main `
  --collection-name fwnetcol-vg-lab-wus-allow `
  --rule-type NetworkRule `
  --name allow-spoke2-to-rfc1918 `
  --source-addresses 172.22.32.0/24 `
  --destination-addresses 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 `
  --destination-ports "*" `
  --ip-protocols Any

# Allow inter-spoke
az network firewall policy rule-collection-group collection rule add `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rcg-name fwrcg-vg-lab-wus-main `
  --collection-name fwnetcol-vg-lab-wus-allow `
  --rule-type NetworkRule `
  --name allow-spoke1workload-to-spoke2workload `
  --source-addresses 172.22.16.0/24 `
  --destination-addresses 172.22.32.0/24 `
  --destination-ports "*" `
  --ip-protocols Any
```

**Note on destination address syntax in CLI:** During this lab, comma-separated destination addresses (`10.0.0.0/8,172.16.0.0/12`) resulted in a rule that did not match traffic. Space-separated values are the supported CLI syntax — use spaces between multiple CIDRs.

---

## Step 7 — Add Application Allow Rule Collection

```powershell
az network firewall policy rule-collection-group collection add-filter-collection `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rule-collection-group-name fwrcg-vg-lab-wus-main `
  --name fwappcol-vg-lab-wus-allow `
  --collection-priority 200 `
  --action Allow `
  --rule-type ApplicationRule `
  --rule-name allow-spoke1-to-github `
  --source-addresses 172.22.16.0/24 `
  --target-fqdns "github.com" "*.github.com" `
  --protocols https=443
```

**Add a new application rule to an existing collection (skeleton):**
```powershell
az network firewall policy rule-collection-group collection rule add `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rcg-name fwrcg-vg-lab-wus-main `
  --collection-name fwappcol-vg-lab-wus-allow `
  --rule-type ApplicationRule `
  --name <rule-name> `
  --source-addresses <source-cidr> `
  --target-fqdns "<apex.domain.com>" "<*.domain.com>" `
  --protocols https=443
```

**Update FQDNs on an existing application rule:**
```powershell
az network firewall policy rule-collection-group collection rule update `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rule-collection-group-name fwrcg-vg-lab-wus-main `
  --collection-name fwappcol-vg-lab-wus-allow `
  --name allow-spoke1-to-github `
  --target-fqdns "github.com" "*.github.com" "newdomain.com"
```

**Critical — apex domain must be explicit:** `*.github.com` covers subdomains only. `github.com` apex domain must be added separately. Azure Firewall sends a TCP RST after Client Hello for denied HTTPS traffic — this appears as an SSL EOF error but is actually the Firewall's deny signal, not a TLS issue.

---

## Step 8 — Add Network Deny Rule Collection

```powershell
az network firewall policy rule-collection-group collection add-filter-collection `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rule-collection-group-name fwrcg-vg-lab-wus-main `
  --name fwnetcol-vg-lab-wus-deny `
  --collection-priority 300 `
  --action Deny `
  --rule-type NetworkRule `
  --rule-name deny-spoke2-to-internet `
  --source-addresses 172.22.32.0/24 `
  --destination-addresses 0.0.0.0/0 `
  --destination-ports "*" `
  --ip-protocols Any
```

**Why explicit deny when implicit deny exists:**
- Produces explicit log entries for auditing
- Documents security intent clearly
- Can override broader allow rules when needed

---

## Step 9 — Add PE Subnet UDR on Spoke1

```powershell
az network route-table route create `
  --resource-group rg-vg-lab-wus-01 `
  --route-table-name rt-vg-lab-wus-spoke1 `
  --name route-vg-lab-pe `
  --address-prefix 172.22.3.0/24 `
  --next-hop-type VirtualAppliance `
  --next-hop-ip-address 172.22.1.4
```

---

## Step 10 — Fix VNet Peering for Inter-Spoke Traffic

Inter-spoke traffic routed through Azure Firewall requires two peering settings on all spoke peerings:

```powershell
# Disable useRemoteGateways on spoke peerings
az network vnet peering update `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --name peer-vg-lab-wus-spoke1-to-hub `
  --set useRemoteGateways=false

az network vnet peering update `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-spoke2 `
  --name peer-vg-lab-wus-spoke2-to-hub `
  --set useRemoteGateways=false

# Enable allowForwardedTraffic on all peerings
az network vnet peering update `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name peer-vg-lab-wus-hub-to-spoke1 `
  --set allowForwardedTraffic=true

az network vnet peering update `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-hub `
  --name peer-vg-lab-wus-hub-to-spoke2 `
  --set allowForwardedTraffic=true

az network vnet peering update `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-spoke1 `
  --name peer-vg-lab-wus-spoke1-to-hub `
  --set allowForwardedTraffic=true

az network vnet peering update `
  --resource-group rg-vg-lab-wus-01 `
  --vnet-name vnet-vg-lab-wus-spoke2 `
  --name peer-vg-lab-wus-spoke2-to-hub `
  --set allowForwardedTraffic=true
```

---

## Step 11 — Verify Rules

```powershell
az network firewall policy rule-collection-group show `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --name fwrcg-vg-lab-wus-main `
  --output json
```

Note: `az network firewall policy rule-collection-group collection rule list` does not exist — use `show` on the RCG to see all rules.

---

## Step 12 — Test Rules

Start spoke VMs and set passwords (see Lab 3 for details).

**From spoke1 via Bastion:**
```bash
# Application rule — should be allowed
curl -I https://github.com --max-time 10

# Implicit deny — should return TLS reset
curl -I https://google.com --max-time 10

# Network rule — should reach storage PE
curl -I https://stvglabwus01.blob.core.windows.net --max-time 10

# Inter-spoke — should reach spoke2
ping 172.22.32.4 -c 3
```

**From spoke2 via Bastion:**
```bash
# Explicit deny — should be blocked
curl -I https://github.com --max-time 10

# RFC1918 allow — should reach spoke1
ping 172.22.16.4 -c 3
```

**Expected results:**

| Test | Expected |
|---|---|
| Spoke1 → github.com | HTTP 200 — application rule matches |
| Spoke1 → google.com | TLS reset — implicit deny |
| Spoke1 → storage PE | HTTP 400 — network rule matches |
| Spoke1 ↔ Spoke2 ping | Success — inter-spoke rule matches |
| Spoke2 → internet | Blocked — explicit deny rule |
| Spoke2 → RFC1918 | Success — allow-spoke2-to-rfc1918 matches |

---

## Step 13 — Query Firewall Logs

Wait 2-3 minutes after generating traffic before querying. Run in `law-vg-lab-wus` workspace under **Logs**.

**All rule hits — last 15 minutes:**
```kusto
AzureDiagnostics
| where Category in ("AzureFirewallNetworkRule", "AzureFirewallApplicationRule")
| where TimeGenerated > ago(15m)
| project TimeGenerated, Category, msg_s
| order by TimeGenerated desc
```

Expected output — one line per connection with rule name and action:
```
TimeGenerated         Category                        msg_s
2026-06-12 10:00:00   AzureFirewallApplicationRule    HTTPS request from 172.22.16.4:12345 to github.com:443. Action: Allow. Rule: allow-spoke1-to-github
2026-06-12 10:00:01   AzureFirewallNetworkRule        TCP request from 172.22.32.4:54321 to 0.0.0.0/0:443. Action: Deny. Rule: deny-spoke2-to-internet
```

**Inter-spoke traffic only:**
```kusto
AzureDiagnostics
| where Category in ("AzureFirewallNetworkRule", "AzureFirewallApplicationRule")
| where TimeGenerated > ago(30m)
| extend src = extract(@"from\s+(\d+\.\d+\.\d+\.\d+)", 1, msg_s)
| extend dest = extract(@"to\s+(\d+\.\d+\.\d+\.\d+)", 1, msg_s)
| where (src == "172.22.16.4" and dest == "172.22.32.4")
    or (src == "172.22.32.4" and dest == "172.22.16.4")
| project TimeGenerated, src, dest, msg_s
| order by TimeGenerated desc
```

Expected: rows showing both spoke IPs with `Action: Allow` confirming inter-spoke rule is matching.

**DNAT and network rule hits:**
```kusto
AzureDiagnostics
| where Category in ("AzureFirewallNetworkRule", "AzureFirewallNatRule")
| where TimeGenerated > ago(15m)
| project TimeGenerated, Category, msg_s
| order by TimeGenerated desc
```

**Filter by specific source IP (useful for troubleshooting):**
```kusto
AzureDiagnostics
| where Category in ("AzureFirewallNetworkRule", "AzureFirewallApplicationRule")
| where TimeGenerated > ago(15m)
| where msg_s contains "172.22.16.4"
| project TimeGenerated, Category, msg_s
| order by TimeGenerated desc
```

**Denied traffic only:**
```kusto
AzureDiagnostics
| where Category in ("AzureFirewallNetworkRule", "AzureFirewallApplicationRule")
| where TimeGenerated > ago(15m)
| where msg_s contains "Deny"
| project TimeGenerated, Category, msg_s
| order by TimeGenerated desc
```

---

## Step 14 — DNAT Rule (Optional)

DNAT exposes an internal resource via the Firewall's public IP. Testing requires unrestricted outbound internet access — corporate networks may block connections to non-standard ports on Azure public IPs.

Get your current public IP:
```powershell
(Invoke-WebRequest -Uri "https://api.ipify.org").Content
```

```powershell
az network firewall policy rule-collection-group collection add-nat-collection `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rcg-name fwrcg-vg-lab-wus-main `
  --collection-priority 150 `
  --name fwnatcol-vg-lab-wus `
  --rule-name dnat-ssh-spoke1 `
  --description "Allow SSH to spoke1 via Firewall public IP" `
  --destination-addresses 104.42.37.52 `
  --source-addresses <your-public-ip> `
  --translated-address 172.22.16.4 `
  --translated-port 22 `
  --destination-ports 2222 `
  --ip-protocols TCP
```

Test:
```powershell
ssh -p 2222 azureuser@104.42.37.52
```

**Update source address when your public IP changes:**
```powershell
az network firewall policy rule-collection-group collection rule update `
  --resource-group rg-vg-lab-wus-01 `
  --policy-name fwpol-vg-lab-wus `
  --rule-collection-group-name fwrcg-vg-lab-wus-main `
  --collection-name fwnatcol-vg-lab-wus `
  --name dnat-ssh-spoke1 `
  --source-addresses <your-new-public-ip>
```

**DNAT implicit allow:** DNAT rules do not require a separate network allow rule. Matching traffic is translated and allowed without further evaluation by network or application rules.

---

## Teardown

**Keep (free):**
- Firewall Policy `fwpol-vg-lab-wus` + all rules
- All UDRs and peering settings

**Delete:**
```powershell
az network firewall delete `
  --resource-group rg-vg-lab-wus-01 `
  --name fw-vg-lab-wus-hub `
  --no-wait

az network public-ip delete `
  --resource-group rg-vg-lab-wus-01 `
  --name pip-vg-lab-wus-fw

az monitor log-analytics workspace delete `
  --resource-group rg-vg-lab-wus-01 `
  --workspace-name law-vg-lab-wus `
  --force `
  --yes
```

Clean up Lab 4 storage resources:
```powershell
az network private-endpoint delete `
  --resource-group rg-vg-lab-wus-01 `
  --name pe-vg-lab-wus-storage

az storage account delete `
  --resource-group rg-vg-lab-wus-01 `
  --name stvglabwus01 `
  --yes
```

---

## Key Observations from This Lab

1. **Two-step Firewall deployment** — In this lab environment, the most reliable deployment method was creating the Firewall first and then attaching the IP configuration with `az network firewall ip-config create`. This may be a CLI version or extension-specific behavior — not necessarily universal. Step 3b takes ~30 minutes.
2. **Rule type evaluates before RCG priority** — network rules in low-priority RCGs are always evaluated before application rules in high-priority RCGs. Full pass through all DNAT → all network → all application.
3. **Rules have no action** — action belongs to Rule Collection. Rules only define match criteria.
4. **Priority namespaces are per rule type** — DNAT, network, and application rules each have independent priority namespaces.
5. **Use space-separated destination addresses in CLI** — During this lab, comma-separated destination addresses resulted in a rule that did not match traffic. Space-separated addresses are the supported CLI syntax and should always be used. This may be a CLI parsing or shell quoting issue specific to the environment.
6. **Apex domain must be explicit** — `*.github.com` does not cover `github.com`. Add both explicitly.
7. **Azure Firewall TLS reset for denied HTTPS** — Firewall sends TCP RST after Client Hello for denied traffic. Appears as SSL EOF error — not a TLS issue.
8. **Inter-spoke via Firewall requires peering fixes** — must set `useRemoteGateways=false` and `allowForwardedTraffic=true` on spoke peerings.
9. **`rule list` subcommand does not exist** — use `rule-collection-group show` to see all rules.
10. **DNAT implicitly allows translated traffic** — no separate network allow rule needed for DNAT destinations.
11. **Evaluation order matters when match criteria overlap** — network rules are evaluated before application rules. If a network deny rule matches the same traffic (same source, destination, port, protocol) as an application allow rule, the deny fires first and the allow is never reached. Different sources or non-overlapping criteria do not conflict regardless of collection priority.
12. **Diagnostics required for log querying** — Firewall logs are not available without a Log Analytics workspace and diagnostic settings configured.
13. **Teardown reminder** — Firewall costs ~$1.25/hour. Always tear down after lab.