# Azure Networking Labs — CLI & Terraform

A self-paced, hands-on course for learning **Azure networking** two ways: first by building it
by hand with the **Azure CLI**, then by rebuilding the same estate as **Infrastructure as Code
with Terraform**. The two tracks mirror each other topic-for-topic, so you learn each concept
imperatively first, then declaratively — and feel exactly what IaC buys you.

Maintained and shared by **wondering-packet**. Everything here is lab material: real commands,
real resource layouts, lab-only IP ranges. Bring your own Azure subscription.

---

## What's in here — two tracks

| Folder | Track | What it is |
|---|---|---|
| `azurecli-labs/` | **1 — Azure CLI** | Seven topic labs you run by hand in PowerShell, plus theory notes, an IP schema, and a command reference. Do this first. |
| `azure-terraform-labs/` | **2 — Terraform** | A day-by-day Terraform program that rebuilds the same networking stack as code. Do this second. |
| `archived/` | — | Early first-pass material kept for reference. Ignore unless you're curious. |

Both tracks target the **same topics** — hub-spoke peering, UDRs/forced tunneling, Azure DNS,
Private Endpoints, VPN Gateway, Azure Firewall, and load balancing — so the CLI muscle memory
transfers directly to the Terraform resources.

---

## Standard lab environment

Shared across both tracks. Swap the tokens for your own values.

| Setting | Value |
|---|---|
| Subscription | `<your-subscription-id>` |
| Tenant | `<your-tenant-id>` |
| Region | `westus` |
| Resource group | `rg-vg-lab-wus-01` |
| Naming convention | `<resource-type>-vg-lab-wus-<purpose>` |
| Supernet | `172.22.0.0/16` — Hub `/20`, Spoke1 `172.22.16.0/20`, Spoke2 `172.22.32.0/20`, on-prem sim `172.22.64.0/20` |
| OS / shell | Windows / PowerShell — backtick (`` ` ``) line continuation, never `\` |

**The naming convention, element by element:**

| Element | Example | Meaning |
|---|---|---|
| `<resource-type>` | `rg`, `vnet`, `snet`, `nsg`, `rt`, `pe`, `fw` | Azure resource-type abbreviation |
| `vg` | `vg` | Owner identifier in a shared subscription |
| `lab` | `lab` | Environment (distinguishes from dev/prod) |
| `wus` | `wus` | Region (West US) |
| `<purpose>` | `hub`, `spoke1`, `shared`, `pe` | What the resource is for |

> The IP ranges throughout are lab ranges — safe to keep as-is. The subscription and tenant
> IDs are placeholders: set `az account set --subscription "<your-subscription-id>"` (CLI) or
> the `ARM_*` environment variables (Terraform) to your own before running anything.

---

## How to use these labs

**Do Track 1 (CLI) first, then Track 2 (Terraform).** Building each thing by hand first makes
the Terraform resource graph click — you already know what `allowGatewayTransit`,
`privateEndpointNetworkPolicies`, or an HA-Ports rule actually does before you declare it.

### Track 1 — Azure CLI (`azurecli-labs/`)

1. Read `lab_ip_schema.md` once — it's the address plan every lab builds against.
2. Work the labs **in order**, `lab1.md` → `lab7.md`. Lab 1 builds a persistent hub-spoke
   foundation the later labs reuse; don't skip it.
3. For deeper theory on any topic, read the matching `week2_notes_topicN.md` (concept notes,
   an AWS-to-Azure anchor, a Q&A bank, and a gotchas list).
4. Keep `cli-reference.md` open as your command cheat-sheet — it's the whole CLI surface of
   the course distilled into one file with real, copy-ready examples.

| CLI lab | Topic |
|---|---|
| `lab1.md` | VNet peering & hub-spoke topology |
| `lab2.md` | User-defined routes & forced tunneling |
| `lab3.md` | Azure DNS — private zones & Private Resolver |
| `lab4.md` | Service Endpoints & Private Endpoints |
| `lab5.md` | VPN Gateway & hybrid connectivity (BGP) |
| `lab6.md` | Azure Firewall & policy |
| `lab7.md` | Load balancing — ILB & Application Gateway |

Each lab states its **cost** and whether resources are **persistent** or should be **torn
down** after the session — read that header before you start so you don't leave a VPN Gateway
or Firewall running.

> `test1.ps1` is a scratchpad, not a lab — a loose collection of commands used during
> experimentation (it targets an `eastus` variant of the naming). Safe to ignore.

### Track 2 — Terraform (`azure-terraform-labs/`)

1. Read `docs/day00-terraform-intro.md` once — concepts, state model, HCL, the workflow.
2. Work `day01` → `day09` in order. Each day folder is a **self-contained Terraform root**:
   copy the `_base/` template, drop in that day's exercise files, and run Terraform inside the
   folder.

   ```powershell
   Copy-Item -Recurse _base dayNN-topic-name
   cd dayNN-topic-name

   $env:ARM_CLIENT_ID       = "<client-id>"
   $env:ARM_CLIENT_SECRET   = "<client-secret>"
   $env:ARM_TENANT_ID       = "<your-tenant-id>"
   $env:ARM_SUBSCRIPTION_ID = "<your-subscription-id>"

   terraform init
   terraform fmt
   terraform validate
   terraform plan
   terraform apply
   # ...work the day's exercises...
   terraform destroy
   ```

3. Lean on `docs/` as you go: `terraform-cheatsheet.md` (commands & plan symbols),
   `hcl-cheatsheet.md` (language), `cli-commands.md` (az verification helpers to confirm what
   Terraform deployed), `common-errors.md` (symptom → cause → fix), and `useful-links.md`.
   `day01-notes.md` is the worked example every later day follows.

| TF day | Focus | CLI parallel |
|---|---|---|
| `day01-hcl-deep-dive` | HCL: variables, outputs, locals, for_each, data sources, lifecycle | — |
| `day02-remote_state-backend-workspaces` | Remote state, backends, locking, workspaces | — |
| `day03-extend-base` | Base env: RG + hub VNet + subnets + NSGs | Lab 1–2 |
| `day04-peering-routing-dns` | Hub-spoke peering, routing, DNS | Lab 1–3 |
| `day05-private-endpoints` | Private Endpoints + Private DNS | Lab 4 |
| `day06-vpn-gateway` | VPN Gateway + hybrid | Lab 5 |
| `day07-firewall` | Azure Firewall + UDR routing | Lab 6 |
| `day08-modules` | Reusable modules | — |
| `day09-load-balancer` | Load balancing: ILB & Application Gateway | Lab 7 |

> **Why each day copies `_base/`:** Terraform only reads `.tf` files in the current directory
> (plus declared modules) — never parent or sibling folders. So the shared base (provider,
> variables, locals) must sit alongside each day's exercises. See `docs/workflow.md` and
> `docs/common-errors.md` for the full reasoning.

---

## Prerequisites

- An Azure subscription where you can create networking resources (Contributor at the
  resource-group or subscription scope).
- **Azure CLI** (`az`) for Track 1, plus the `dns-resolver` and `azure-firewall` extensions
  (the labs show when to install them).
- **Terraform** and the `azurerm` provider for Track 2.
- Windows PowerShell (the examples use backtick line-continuation). On bash, swap `` ` `` for
  `\`.

> Behind a TLS-inspecting proxy (e.g. Zscaler), `az extension add` may fail on an SSL error.
> The labs show a lab-only workaround — never disable verification in production.

---

## A note on costs

Most of what you build (VNets, subnets, peering, route tables, NSGs, private DNS, Firewall
*policy*) is free. The things that cost real money are **VPN Gateways**, **Azure Firewall**,
**Application Gateway**, the **DNS Private Resolver**, and **running VMs**. Each lab flags
these in its header and gives teardown steps. Deallocate VMs between sessions and tear down
the paid resources when you're done — don't leave a gateway running overnight.

Happy routing. — *wondering-packet*
