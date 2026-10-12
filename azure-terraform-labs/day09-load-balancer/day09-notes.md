# Day 9 — Load Balancing (ILB + Application Gateway)

> **How to use this guide.** Each topic's theory gives you the building blocks — including a commented skeleton you can read like documentation — not the finished answer. Each exercise states a full problem: objective, inputs, constraints, and the blocks to write. Attempt it from the theory, predict the plan, then read the solution and apply.
>
> **Assumed knowledge:** load-balancing fundamentals — L4 vs L7, backend pools, health probes — carry over from the CLI phase. This guide teaches the Azure *resource shapes* and their Terraform expression, not a generic LB primer. Days 0–8 (remote state, cross-stack reads, modules, `for_each`, `templatefile`) are assumed.

This is the **last ephemeral stack and the last Azure networking lab.** Everything built here is torn down at session end — persistent in production, ephemeral here for cost (AGW ~$0.25/hr; ILB free). Days 10+ are pure Terraform-practice (CI/CD, import, policy-as-code, capstone).

## File & marker conventions
- `dNN…` files are day-scoped; this day's builds land inside **modules**, driven by composite locals.
- Locals carry inline `# added in d09exNN` markers in `locals.tf`.

## Prerequisites & continuity
The base `networking/hub-spoke` is live and modularized (Day 8), infra unchanged, all outputs stable. This stack (`networking/lb`) **reads** the base via `terraform_remote_state` and never writes to it. It stands up two nginx backend VMs, an Internal Load Balancer (L4), and an Application Gateway (L7) over the same backends, demonstrates the L4/L7 contrast and probe failover, then destroys everything.

## Standard lab environment
| Setting | Value |
|---|---|
| Subscription | `<your-subscription-id>` |
| Region / RG | westus / rg-vg-lab-wus-01 |
| State key (this day) | `networking/lb` (new ephemeral stack) |
| Base state (read-only) | `networking/hub-spoke` via `terraform_remote_state` |
| Backend / auth | stvglabwustfstate / tfstate — Azure AD — default workspace |
| Provider | azurerm, pinned `~> 3.100` (resolved to v3.117.x) |
| OS / shell | Windows / PowerShell — backtick continuation |

## Table of contents
1. [Topic 1 — The LB stack reads the base](#topic-1--the-lb-stack-reads-the-base)
2. [Topic 2 — Backend VMs + nginx](#topic-2--backend-vms--nginx)
3. [Topic 3 — Internal Load Balancer (L4)](#topic-3--internal-load-balancer-l4)
4. [Topic 4 — Application Gateway (L7)](#topic-4--application-gateway-l7)
5. [Topic 5 — Verify + destroy](#topic-5--verify--destroy)
6. [Design challenge](#design-challenge)
7. [Corrections & gotchas](#corrections--gotchas)

---

## Topic 1 — The LB stack reads the base

### Theory

This is a **separate ephemeral stack with its own state key** (`networking/lb`), for the same reason the VPN and firewall stacks were separate: an independently-deployed lifecycle, persistent in prod, torn down here for cost. Two rules govern the cross-stack link:

- **Dependency is one-directional.** `networking/lb` reads `networking/hub-spoke`; the base has no idea this stack exists. Future references past, never the reverse.
- **`terraform_remote_state` exposes root `outputs` only** — never the base's locals or variables. Outputs are the base's entire public API.

Anything the base does not publish as an output must be **re-declared as a local `data` source**. The resource group is the canonical case: this stack's creates need it, but it isn't a base output, so you look it up locally.

```hcl
# The base publishes its subnets as one map output. Read the two you need:
#   data.terraform_remote_state.base.outputs.hub_subnet_ids["shared"]   -> ILB + backend VMs
#   data.terraform_remote_state.base.outputs.hub_subnet_ids["agw"]      -> App Gateway
#
# The RG is NOT an output, so re-declare it as a local data source:
data "azurerm_resource_group" "main" {
  name = # ?  -> build from the workspace-aware naming chain, not hardcoded
}
```

> **Observed quirk.** On a never-applied stack, `terraform console` may show a `terraform_remote_state` read as `(known after apply)` rather than the real value. Run a no-op `terraform apply` once to persist the read into this stack's state, then the console resolves it. Observed this lab; not a universal guarantee.

### Exercise 0 — new-stack + remote-state gate

**Objective:** create the `networking/lb` stack, wire the remote-state read plus a re-declared RG data source, and prove the read resolves with a sane plan. No build resources yet.

**Inputs:**
- This stack's backend key: `networking/lb`
- Base state key (read-only): `networking/hub-spoke`
- Backend storage / container: `stvglabwustfstate` / `tfstate`
- Outputs consumed: `hub_subnet_ids["shared"]`, `hub_subnet_ids["agw"]`
- RG name: workspace-aware chain → `rg-vg-lab-wus-01` on `default`

**Constraints:**
- Copy Day 8 forward for provider/backend/locals scaffolding, then strip every base resource and module call — they belong to `hub-spoke`; recreating them is a state collision.
- Strip the inherited base modules and now-dead base variables too.
- `init -reconfigure` (the backend key changed — plain `init` won't repoint it).
- This stack must never write to the base.

**Blocks to write:**
- `data.terraform_remote_state.base` — `backend = "azurerm"` + a `config = {…}` map keyed to `networking/hub-spoke`. No child blocks.
- `data.azurerm_resource_group.main` — re-declared locally, no child blocks, name from the naming chain.

**Predict:**
- `terraform workspace show` → `default`
- `terraform plan` → `No changes` (only data sources; no managed resources)
- `terraform console` on the shared-subnet read → `(known after apply)` until a no-op apply persists it

**Solution** — try the exercise above before reading on.

`backend.tf` — key repointed; AAD auth carried from Day 3:
```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-vg-lab-wus-01"
    storage_account_name = "stvglabwustfstate"
    container_name       = "tfstate"
    key                  = "networking/lb"   # this stack's own key
    use_azuread_auth     = true
    use_cli              = true
  }
}
```

`remote-state.tf` — the read of the base's published outputs (read-only):
```hcl
data "terraform_remote_state" "base" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-vg-lab-wus-01"
    storage_account_name = "stvglabwustfstate"
    container_name       = "tfstate"
    key                  = "networking/hub-spoke"   # pointing at the base's state
    use_azuread_auth     = true
    use_cli              = true
  }
}
```

`main.tf` — the re-declared RG; name built from the locals chain, never hardcoded:
```hcl
data "azurerm_resource_group" "main" {
  name = "${local.rg_name}-01"
}
```

**Variables & locals (this exercise):**

*Root variables* (`variables.tf`) — the slimmed input surface for the whole stack:
```hcl
variable "location"    { type = string  default = "westus" }
variable "owner"       { type = string }                       # required
variable "environment" { type = string }
variable "tf_stack"    { type = string }                       # tags resources with their owning stack
```

*Root locals* (`locals.tf`) — the naming chain, reused from the base:
```hcl
# local.environment = terraform.workspace == "default" ? "lab" : terraform.workspace  -> "lab"
# local.region_code = var.location == "westus" ? "wus" : "eus"                        -> "wus"
# local.prefix      = "${var.owner}-${local.environment}-${local.region_code}"        -> "vg-lab-wus"
# local.rg_name     = "rg-${local.prefix}"                                            -> "rg-vg-lab-wus"  (RG: rg-vg-lab-wus-01)
```

Run it:
```powershell
terraform init -reconfigure
terraform workspace show      # predict: default
terraform plan                # predict: No changes
terraform console
# > data.terraform_remote_state.base.outputs.hub_subnet_ids["shared"]
#   predict: (known after apply) on the never-applied stack...
terraform apply               # no-op apply persists the remote-state read
# ...then the console resolves it to the real subnet ID.
```

### Q&A

**Q1 — Why read `hub_subnet_ids["shared"]` via remote state instead of an `azurerm_subnet` data-source lookup by name in this stack?** Two reasons. **Ownership/coupling:** the base owns that subnet, so you pull the value from the owner rather than re-querying Azure independently. **Stable contract:** a by-name `data` lookup keys on the subnet *name*, which the base never promised to keep — rename it in the base and a name lookup either errors or silently binds to whatever now wears that name. The output is the promise, and it couples you to the specific subnet the base actually applied, not to a string that happens to match.

---

## Topic 2 — Backend VMs + nginx

### Theory

Two hub VMs behind both load balancers, each serving an identifying page so you can *see* distribution. VM authoring carries over from Day 5 — what's specific here is captured in the skeleton comments below.

```hcl
resource "azurerm_network_interface" "nic" {
  # ...
  ip_configuration {
    # Pin the IP. The AGW backend pool references backends BY IP, so a dynamic
    # address would make that pool a guessing game. Static also shows the IP
    # concretely at plan time here (the VM's reflected copy stays known-after-apply).
    private_ip_address_allocation = "Static"
    private_ip_address            = # .5 / .6
  }
}

resource "azurerm_linux_virtual_machine" "linux_vm" {
  # ...
  custom_data = base64encode(templatefile("...", { label = # module input }))  # see "Understanding custom_data" below

  lifecycle { ignore_changes = [admin_password] }        # Day-5 fix for password-null ForceNew
  # skip_shutdown_and_force_delete = true                 # see Topic 5 — avoids the deallocated-VM 409 at destroy
}
```

Design the module outputs for what's downstream: the ILB needs each NIC's **id + ip-config name**; the AGW needs each **private IP**. Emit all three.

### Understanding `custom_data` (new this lab)

`custom_data` is how you hand a script to a VM so it configures *itself* at first boot — here, installing nginx and writing an identifying page. Unlike the rest of the VM's arguments, it's not a value Terraform manages on an ongoing basis; it's a one-time payload the OS consumes when the VM first comes up. Four things to internalize before you use it:

- **It must be Base64-encoded.** Azure expects the payload as base64, so you always wrap the script in `base64encode(...)`. Max size is 64 KB (before encoding).
- **cloud-init runs it — but only with a shebang.** On the Ubuntu image, the cloud-init service picks up `custom_data` at first boot and executes it. If the script doesn't start with a shebang (`#!/bin/sh` or `#!/bin/bash`), cloud-init silently ignores it — the VM boots healthy with nginx absent, and you find out only when a probe goes red. Log to check on the box: `/var/log/cloud-init-output.log`.
- **It's ForceNew and first-boot-only.** Changing `custom_data` doesn't re-run the script — it **recreates the VM**. It runs once, at first boot; not on reboot, not on re-apply. So get it right up front; it is not a re-runnable provisioner.
- **Per-VM difference comes from `templatefile`.** hub1 and hub2 need different page text, so the script lives in a `.tftpl` template with a `${label}` placeholder, and each module instance passes its own `label`. That's what turns "two hardcoded VMs" into "one module, N instances."

You don't need to derive this wiring — here is the exact pattern to use. The `custom_data` argument on the VM:

```hcl
# reads the template, substitutes ${label}, base64-encodes the result
custom_data = base64encode(templatefile("${path.module}/nginx.sh.tftpl", {
  label = var.custom_data_nginx_page_label   # "hub1" / "hub2", passed per module instance
}))
```

And the template file it reads, `modules/test_linux_vm/nginx.sh.tftpl`:

```sh
#!/bin/sh                                    # REQUIRED — no shebang, cloud-init skips the script
sudo apt update && sudo apt install -y nginx

# ${label} is substituted by templatefile before the script ever reaches the VM
echo "<h1>Response from ${label}</h1>" | sudo tee /var/www/html/index.html

sudo systemctl status nginx
```

At apply time Terraform renders the template (filling in `hub1`/`hub2`), base64-encodes it, and hands it to Azure; cloud-init decodes and runs it on first boot. The result is two identical VMs that announce which one they are — which is the whole point of a distribution demo.

> If a backend probe later shows unhealthy but the VM is up, first suspect cloud-init: `apt install` at first boot can race Ubuntu's `apt-daily` dpkg lock. Check `/var/log/cloud-init-output.log`; the robust alternative is a `#cloud-config` `packages:` block, which cloud-init serializes against its own apt runs.

### Exercise 1 — backend VM module + hub1/hub2 + nginx

**Objective:** author a reusable VM module and instantiate it for `hub1`/`hub2` in the base `shared` subnet, each running nginx with its own identifying page.

**Inputs:**
- `vm-vg-lab-wus-hub1` → `172.22.2.5` (static), page label `hub1`
- `vm-vg-lab-wus-hub2` → `172.22.2.6` (static), page label `hub2`
- Image: Ubuntu 22.04 (`0001-com-ubuntu-server-jammy` / `22_04-lts`)
- Size: `Standard_B1s`
- Subnet: `hub_subnet_ids["shared"]` (remote state)
- No public IP, no NSG
- Auth: password via `TF_VAR_test_vm_admin_password`; `ignore_changes = [admin_password]`
- nginx via `custom_data`

**Constraints:**
- Backends must be hub VMs (the placement gotcha — see Q2). Read the subnet from remote state, not by name.
- Reusable module, `for_each` over a `{hub1=…, hub2=…}` map.
- Per-backend page is non-negotiable for the distribution demo.
- No plaintext password default in `variables.tf`, none in `terraform.tfvars`.

**Blocks to write:**
- `modules/test_linux_vm`: `azurerm_network_interface.nic` (child `ip_configuration {}`, static) and `azurerm_linux_virtual_machine.linux_vm` (child blocks `os_disk {}`, `source_image_reference {}`, `boot_diagnostics {}`, plus `custom_data` and a `lifecycle` block).
- Module `variables.tf` + `outputs.tf`.
- Root: `module.hub_lb_backend_vms` (for_each).

**Predict:**
- 2 resources per VM (VM + NIC) → **4 to add**
- NIC static IP concrete at plan; VM `private_ip_address` `(known after apply)`
- After apply, `curl` directly to `.5`/`.6` from the hub client VM → `Response from hub1`/`hub2`, proving `custom_data` ran before any LB exists

**Solution** — try the exercise above before reading on.

`modules/test_linux_vm/main.tf`:
```hcl
locals {
  nic_name = replace(var.name, "vm", "nic")   # vm-...-hub1 -> nic-...-hub1
}
resource "azurerm_network_interface" "nic" {
  name                = local.nic_name
  location            = var.location
  resource_group_name = var.rg_name
  ip_configuration {
    name                          = "ipconfig-${local.nic_name}"
    subnet_id                     = var.snet_id
    private_ip_address_allocation = "Static"          # pinned so the AGW pool can reference by IP
    private_ip_address            = var.private_ip_address
  }
}

resource "azurerm_linux_virtual_machine" "linux_vm" {
  name                            = var.name
  location                        = var.location
  resource_group_name             = var.rg_name
  size                            = var.size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = var.disable_password_authentication
  network_interface_ids           = [azurerm_network_interface.nic.id]
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

  # base64 required; ForceNew; the label is injected per-backend via templatefile
  custom_data = base64encode(templatefile("${path.module}/nginx.sh.tftpl", {
    label = var.custom_data_nginx_page_label
  }))

  boot_diagnostics {}
  tags = var.tags

  lifecycle {
    ignore_changes = [admin_password]        # Day-5 fix for password-null ForceNew
  }

  # azurerm powers a VM off before deleting it; against an already-deallocated VM
  # that is a deterministic 409. Force-delete skips the pre-delete power-off. (Topic 5)
  skip_shutdown_and_force_delete = true
}
```

`modules/test_linux_vm/nginx.sh.tftpl` — shebang present or cloud-init ignores it:
```sh
#!/bin/sh
sudo apt update && sudo apt install -y nginx

# Customize response page to identify which backend responded
echo "<h1>Response from ${label}</h1>" | sudo tee /var/www/html/index.html

sudo systemctl status nginx
```

`modules/test_linux_vm/outputs.tf` — the three downstream feeds:
```hcl
output "vm_nic_id"          { value = azurerm_network_interface.nic.id }                          # -> ILB NIC association
output "ipconfig_name"      { value = azurerm_network_interface.nic.ip_configuration[0].name }    # -> ILB NIC association
output "private_ip_address" { value = azurerm_network_interface.nic.ip_configuration[0].private_ip_address } # -> AGW pool
# (also vm_name, vm_id)
```

Root call (`main.tf`), driven by the composite local:
```hcl
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
```

**Variables & locals (this exercise):**

*Root variable* (`variables.tf`) — feeds the admin password; sensitive, no default (supply via `TF_VAR_test_vm_admin_password`):
```hcl
variable "test_vm_admin_password" {
  type      = string
  sensitive = true
  default   = null
}
```

*Module variables* (`modules/test_linux_vm/variables.tf`) — the reusable interface:
```hcl
# snet_id, private_ip_address, name, location, rg_name    (required)
# size = "Standard_B1s", admin_username = "azureuser"      (defaulted)
# admin_password (sensitive), disable_password_authentication = false, tags = {}
# custom_data_nginx_page_label
```

*Root locals* (`locals.tf`) — `local.lb_backend_vms` is **declared this exercise** and is the single source of truth for the backends: consumed by this module (`for_each`), by the ILB NIC associations (Topic 3), and by the AGW backend pool (Topic 4). `snet_id` comes from remote state:
```hcl
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
# reused: local.lb_name = "lb-${local.prefix}" ("lb-vg-lab-wus"); local.vm_name = "vm-${local.prefix}"; local.lab_tags
```

Run:
```powershell
terraform plan     # predict: 4 to add
terraform apply
# from the hub client VM over Bastion:
curl http://172.22.2.5   # predict: <h1>Response from hub1</h1>
curl http://172.22.2.6   # predict: <h1>Response from hub2</h1>
```

### Q&A

**Q2 — Backends must be hub VMs; spoke VMs couldn't join the pool. Why, and which pool type would change it?** You used a **NIC-based** backend pool (`azurerm_network_interface_backend_address_pool_association`), which is scoped to the load balancer's **own VNet** — every NIC must be in the same VNet as the LB. Peering doesn't merge VNets, so spoke NICs are rejected. It's a membership-scope rule, not routing or security. An **IP-based** backend pool (members by IP, not NIC reference) *can* reach backends across peered VNets — that's the type that would admit spoke backends, at the cost of some IP-pool feature limitations.

---

## Topic 3 — Internal Load Balancer (L4)

### Theory

The CLI's single `az network lb create` explodes into **separate Terraform resources**, with one exception: the frontend is a nested block on `azurerm_lb`. Read the wiring off this skeleton — the comments are the lesson:

```hcl
resource "azurerm_lb" "lb" {
  sku = # "Standard"   # Basic was retired Sep 2025; omitting sku defaults to Basic and fails at create
  frontend_ip_configuration {         # the frontend is a BLOCK here, not a standalone resource,
    # name / subnet_id / private_ip_address / private_ip_address_allocation   # because it is intrinsic to the LB's identity
  }
}

resource "azurerm_lb_backend_address_pool" "be_pool" {
  loadbalancer_id = # azurerm_lb.lb.id      # empty until members attach (below)
}

resource "azurerm_lb_probe" "probe" {
  protocol     = # "Http"
  request_path = # "/"   # NAMING GOTCHA: the CLI's --path is request_path in azurerm; defaults 15s x 2 give ~30s failover
}

resource "azurerm_lb_rule" "lb_rule" {
  # HA Ports: there is NO enable_ha_ports argument. It is IMPLICIT in this triple:
  protocol      = # "All"
  frontend_port = # 0
  backend_port  = # 0
  # Reference quirk: the rule points at the frontend BY NAME, but the pool + probe BY ID:
  frontend_ip_configuration_name = # azurerm_lb.lb.frontend_ip_configuration[0].name
  probe_id                       = # azurerm_lb_probe.probe.id
  backend_address_pool_ids       = # [azurerm_lb_backend_address_pool.be_pool.id]
}

resource "azurerm_network_interface_backend_address_pool_association" "..." {
  # one per NIC; this is where the VM module's vm_nic_id + ipconfig_name outputs feed in
}
```

**How it ties together:** the `lb` owns the frontend block; the `pool`, `probe`, and `rule` reference the lb by `loadbalancer_id`; the `rule` binds frontend→pool→probe (making traffic actually flow); the NIC associations put the VMs *into* the pool. Miss the rule and you have a frontend that accepts nothing.

> **Distribution is 5-tuple hash, not round-robin.** From a single client, sequential ephemeral source ports bucket unevenly — you see runs (e.g. 7 then 5), not strict alternation. Balance emerges across many independent flows. The knob is `load_distribution` (`Default` = 5-tuple).

### Exercise 2 — ILB shell: lb + static frontend + empty pool + probe

**Objective:** stand up the load balancer, its static internal frontend, an empty backend pool, and the HTTP probe. No rule, no associations yet.

**Inputs:**
- LB: `Standard` SKU
- Frontend: `172.22.2.100` static, in `hub_subnet_ids["shared"]`
- Backend pool: empty
- Probe: Http, port 80, path `/`

**Constraints:**
- Frontend is a block on `azurerm_lb`, not a separate resource
- Standard SKU; static allocation; subnet from remote state

**Blocks to write:** `azurerm_lb.lb` (child `frontend_ip_configuration {}`), `azurerm_lb_backend_address_pool.be_pool` (no child blocks), `azurerm_lb_probe.probe` (no child blocks; mind `request_path`). Reference the theory skeleton above for the wiring.

**Predict:** 3 resources; frontend `172.22.2.100` concrete at plan (static); pool + probe IDs `(known after apply)` for Ex 3.

### Exercise 3 — HA Ports rule + NIC associations

**Objective:** add the HA Ports rule and snap the backend NICs into the pool — the resources that actually make traffic flow.

**Inputs:**
- Rule: `protocol = "All"`, `frontend_port = 0`, `backend_port = 0`
- Associations: one per backend NIC, fed by the VM module outputs

**Constraints:**
- HA Ports triple as above (no `enable_ha_ports` argument exists)
- Rule references frontend by name, pool/probe by id
- One association per NIC

**Blocks to write:** `azurerm_lb_rule.lb_rule`, `azurerm_network_interface_backend_address_pool_association.lb_be_nic_association` (for_each over the NICs). Reference the theory skeleton.

**Predict:** +3 (rule + 2 associations). Then `curl http://172.22.2.100` repeatedly → responses from both hub1 and hub2.

**Solution (Ex 2 + Ex 3)** — try the exercises above before reading on.

The whole ILB is encapsulated as one reusable module (`modules/load_balancer/main.tf`) — a deliberate choice toward a prod/JFrog library:
```hcl
resource "azurerm_lb" "lb" {
  name                = var.lb_name
  resource_group_name = var.rg_name
  location            = var.location
  sku                 = var.sku                       # "Standard"
  frontend_ip_configuration {
    name                          = var.frontend_ip_configuration.name
    subnet_id                     = var.frontend_ip_configuration.subnet_id
    private_ip_address            = var.frontend_ip_configuration.private_ip_address
    private_ip_address_allocation = var.frontend_ip_configuration.private_ip_address_allocation
    public_ip_address_id          = var.frontend_ip_configuration.public_ip_address_id   # null for internal
  }
}

resource "azurerm_lb_rule" "lb_rule" {
  name                           = var.lb_rule.name
  frontend_port                  = var.lb_rule.frontend_port   # 0  ┐
  backend_port                   = var.lb_rule.backend_port    # 0  ├ HA Ports (implicit)
  protocol                       = var.lb_rule.protocol        # "All" ┘
  frontend_ip_configuration_name = azurerm_lb.lb.frontend_ip_configuration[0].name  # by NAME
  loadbalancer_id                = azurerm_lb.lb.id
  probe_id                       = azurerm_lb_probe.probe.id                          # by ID
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.be_pool.id]       # by ID
}

resource "azurerm_lb_backend_address_pool" "be_pool" {
  name            = var.lb_be_pool.name
  loadbalancer_id = azurerm_lb.lb.id
}

resource "azurerm_network_interface_backend_address_pool_association" "lb_be_nic_association" {
  for_each                = var.lb_be_nic_associations
  backend_address_pool_id = azurerm_lb_backend_address_pool.be_pool.id
  network_interface_id    = each.value.network_interface_id
  ip_configuration_name   = each.value.ip_configuration_name
}

resource "azurerm_lb_probe" "probe" {
  name            = var.lb_probe.name
  loadbalancer_id = azurerm_lb.lb.id
  port            = var.lb_probe.port
  protocol        = var.lb_probe.protocol
  request_path    = var.lb_probe.protocol == "Tcp" ? null : var.lb_probe.request_path  # Tcp can't carry a path
}
```

Root call (`main.tf`):
```hcl
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
```

**Variables & locals (this topic):**

*Module variables* (`modules/load_balancer/variables.tf`) — abridged to the shaping bits:
```hcl
variable "sku" {
  type    = string
  default = "Standard"                                   # sane default; caller can override
  validation {
    condition     = contains(["Basic", "Standard", "Gateway"], var.sku)
    error_message = "sku type: Basic, Standard, Gateway only"
  }
}
variable "frontend_ip_configuration" {
  type = object({
    name                          = optional(string)
    subnet_id                     = optional(string)
    private_ip_address            = optional(string)
    private_ip_address_allocation = optional(string)
    public_ip_address_id          = optional(string)    # present so the module can also front a public LB
  })
  validation {
    # allow null (public path), else must be Static/Dynamic. The == null short-circuits so
    # contains() never receives a null (which it rejects outright).
    condition = (
      var.frontend_ip_configuration.private_ip_address_allocation == null ||
      contains(["Static", "Dynamic"], var.frontend_ip_configuration.private_ip_address_allocation)
    )
    error_message = "allocation type: Static or Dynamic only"
  }
  default = {}
}
variable "lb_probe" {
  type = object({
    name         = string
    port         = optional(number, 80)
    protocol     = optional(string, "Tcp")
    request_path = optional(string)
  })
  validation {
    condition     = contains(["Http", "Https", "Tcp"], var.lb_probe.protocol)
    error_message = "protocol type: Http, Https, Tcp only"
  }
}
variable "lb_rule" {
  type = object({ name = string, frontend_port = number, backend_port = number, protocol = string })
  validation {
    condition     = contains(["Tcp", "Udp", "All"], var.lb_rule.protocol)
    error_message = "Protocols: Tcp, Udp, All only"
  }
}
# (also: lb_name, rg_name, location, lb_be_pool = object({name}), lb_be_nic_associations = map(object({network_interface_id, ip_configuration_name})))
```

*Root locals* (`locals.tf`) — `local.load_balancers` is **declared this topic** and drives the module; note `lb_be_nic_associations` is built from the VM module outputs (module output → module input via a local):
```hcl
load_balancers = {
  "${local.lb_name}-hub" = {
    rg_name  = data.azurerm_resource_group.main.name
    location = var.location
    sku      = "Standard"
    lb_be_pool = { name = "${local.lb_be_pool_name}-hub" }
    lb_probe   = { name = "${local.lb_probe_name}-hub", port = 80, protocol = "Http", request_path = "/" }
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
    lb_rule = { name = "${local.lb_rule_name}-hub", frontend_port = 0, backend_port = 0, protocol = "All" }
  }
}
# declared Ex 2: local.lb_name, lb_be_pool_name, lb_probe_name, lb_feip_config_name
# declared Ex 3: local.lb_rule_name = "rule-lb-${local.prefix}"
# reused: local.lb_backend_vms (Ex 1), data.terraform_remote_state.base, data.azurerm_resource_group.main
```

Run:
```powershell
terraform plan     # predict: 3 (Ex 2) then +3 (Ex 3)
terraform apply
1..10 | ForEach-Object { curl.exe -s http://172.22.2.100 }   # both hub1 and hub2; hashed runs, not alternation
```

> **`curl` on PowerShell:** the `curl` alias is `Invoke-WebRequest`, which balks on HTML parsing. Use `curl.exe` for Linux-like behavior.

### Q&A

**Q3 — HA Ports uses port 0 / protocol All. What's it for, and why not on a public LB?** It's for a pool of active-active **NVAs** (firewalls/IDS) that must receive *all* ports/protocols on one rule because they inspect and forward rather than terminate a known service — a per-port rule would be unmanageable. It's **internal-LB-only by design**: the all-ports model is for traffic transiting *through* NVAs inside your network, and Azure doesn't offer it on a public LB. (A public LB's frontend also does double duty for outbound SNAT port allocation, which all-ports inbound balancing would collide with.)

---

## Topic 4 — Application Gateway (L7)

### Theory

Where the ILB is five resources, the AGW is **one resource with ~8 required nested blocks** that wire to each other **by name strings**, not `.id`. You lose the referential integrity the ILB had: a typo'd name is an *apply-time Azure error*, not a plan error, and the Set-typed blocks produce noisy replace-everything diffs. Read the wiring off the skeleton — the `(A)`–`(E)` tags show which names must match:

```hcl
resource "azurerm_application_gateway" "agw" {
  sku { name = "Standard_v2"  tier = "Standard_v2"  capacity = 1 }   # or autoscale_configuration { min/max }

  gateway_ip_configuration { subnet_id = # DEDICATED agw subnet — nothing else may live in it }

  frontend_ip_configuration { name = # (A)   public_ip_address_id = # the PIP (Standard/Static — AGW v2 requires it) }
  frontend_port            { name = # (B)   port = 80 }

  backend_address_pool     { name = # (C)   ip_addresses = # [hub1, hub2] — IP-based pool CAN reach peered VNets }
  backend_http_settings    { name = # (D)   protocol = "Http"  port = 80  request_timeout = 60 }

  http_listener {
    name                           = # (E)
    frontend_ip_configuration_name = # must equal (A)
    frontend_port_name             = # must equal (B)
  }

  probe {
    # For an Http/Https probe, EXACTLY ONE of host / pick_host_name_from_backend_http_settings must be set.
    # Timers: timeout <= interval; detection ~ first-interval + (unhealthy_threshold x interval), and v2 waits the interval between retries.
  }

  request_routing_rule {
    rule_type                  = "Basic"
    priority                   = # 100 — REQUIRED on Standard_v2; omit -> apply error
    http_listener_name         = # must equal (E)
    backend_address_pool_name  = # must equal (C)
    backend_http_settings_name = # must equal (D)
  }

  ssl_policy { policy_type = "Predefined"  policy_name = # PIN it — do not inherit the provider default }
}
```

**How it ties together:** the listener binds a frontend IP + port; the routing rule binds that listener to a backend pool + its HTTP settings; the probe health-gates the backends. Every binding is a **name match**, so the module derives all names once (via `trimprefix`) and reuses them — that's how you keep `(A)`–`(E)` consistent.

> **Provider defaults are landmines — the day's recurring theme.** This lab pinned `version = "~> 3.100"`. On the API version that constraint resolves to, three arguments default to obsolete/wrong values when omitted: `azurerm_lb.sku` → Basic (retired), `azurerm_public_ip.sku` → Basic (AGW v2 needs Standard), and the AGW `ssl_policy` → the retired `AppGwSslPolicy20150501` (TLS 1.0/1.1), which Azure now rejects at create. **Future provider versions may default to current values** — but the safe habit is to pin SKU, PIP SKU, and ssl_policy explicitly regardless. The tell is `(known after apply)` on something you never set: that's a default choosing for you.

### Exercise 4 — the App Gateway

**Objective:** stand up the AGW (Standard_v2) with a public IP, listening :80, load-balancing HTTP across the same hub1/hub2 backends. Kick off the apply immediately — it's 15–20 min.

**Inputs:**
- PIP: `pip-vg-lab-wus-agw`, Standard SKU, Static
- AGW: Standard_v2, capacity 1
- Gateway IP config subnet: `hub_subnet_ids["agw"]`
- Frontend port: 80
- Backend pool: hub1/hub2 private IPs (from the VM module outputs / `local.lb_backend_vms`)
- Listener: :80 Http
- Routing rule: Basic, priority 100
- Probe: Http, :80, path `/`, timers `15 / 10 / 3`

**Constraints:**
- Name consistency across `(A)`–`(E)`
- PIP Standard (AGW v2 requirement)
- `priority = 100` required
- Pin `ssl_policy`
- Probe needs a host source

**Blocks to write:** `azurerm_public_ip.agw_pip` (Standard, Static) and `azurerm_application_gateway.agw`. **Reference the theory skeleton above for the nested-block layout and the `(A)`–`(E)` name wiring.**

**Predict:**
- ~15–20 min to create (Azure provisions the gateway fleet)
- Curl the **public** IP from your own machine — the public frontend the ILB never had

**Solution** — try the exercise above before reading on.

`modules/app_gw/main.tf` — sub-resource names derived once via `trimprefix`, then referenced by name throughout:
```hcl
locals {
  prefix                = trimprefix(var.agw_name, "agw-")   # "agw-vg-lab-wus-hub" -> "vg-lab-wus-hub"
  feip_conf_name        = "agw-feip-conf-${local.prefix}"     # (A)
  fe_port_name          = "agw-fe-port-${local.prefix}"       # (B)
  be_address_pool_name  = "agw-be-address-pool-${local.prefix}"   # (C)
  be_http_settings_name = "agw-be-http-settings-${local.prefix}"  # (D)
  http_listener_name    = "agw-http-listener-${local.prefix}" # (E)
  probe_name            = "agw-probe-${local.prefix}"
  req_routing_rule_name = "agw-req-routing-rule-${local.prefix}"
  gwip_conf_name        = "agw-gwip-conf-${local.prefix}"
}

resource "azurerm_public_ip" "agw_pip" {
  resource_group_name = var.rg_name
  location            = var.location
  allocation_method   = var.pip.allocation_method
  name                = var.pip.name
  sku                 = "Standard"      # AGW v2 requires Standard/Static — never default to Basic
  tags                = var.tags
}

resource "azurerm_application_gateway" "agw" {
  resource_group_name = var.rg_name
  location            = var.location
  name                = var.agw_name

  sku { name = "Standard_v2"  tier = "Standard_v2"  capacity = 1 }

  gateway_ip_configuration {
    name      = local.gwip_conf_name
    subnet_id = var.gateway_ip_configuration.subnet_id   # dedicated agw subnet, from remote state
  }

  frontend_ip_configuration {
    name                 = local.feip_conf_name          # (A)
    public_ip_address_id = azurerm_public_ip.agw_pip.id
  }

  frontend_port { name = local.fe_port_name  port = 80 } # (B)

  backend_address_pool {
    name         = local.be_address_pool_name            # (C)
    ip_addresses = var.backend_address_pool.ip_addresses # [172.22.2.5, 172.22.2.6]
  }

  backend_http_settings {
    name                                = local.be_http_settings_name   # (D)
    protocol                            = "Http"
    port                                = 80
    request_timeout                     = 60
    cookie_based_affinity               = "Disabled"
    pick_host_name_from_backend_address = true
  }

  http_listener {
    name                           = local.http_listener_name           # (E)
    frontend_ip_configuration_name = local.feip_conf_name               # == (A)
    frontend_port_name             = local.fe_port_name                 # == (B)
    protocol                       = "Http"
  }

  probe {
    name                                      = local.probe_name
    interval                                  = "15"   # timeout <= interval
    path                                      = "/"
    protocol                                  = "Http"
    timeout                                   = "10"
    unhealthy_threshold                       = "3"
    pick_host_name_from_backend_http_settings = true   # supplies the required probe host
  }

  request_routing_rule {
    name                       = local.req_routing_rule_name
    rule_type                  = "Basic"
    http_listener_name         = local.http_listener_name        # == (E)
    backend_address_pool_name  = local.be_address_pool_name       # == (C)
    backend_http_settings_name = local.be_http_settings_name      # == (D)
    priority                   = 100                              # REQUIRED on Standard_v2
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"   # pinned; unset would inherit the retired 20150501 on this provider
  }

  tags = var.tags
}
```

Root call (`main.tf`):
```hcl
module "agw" {
  source                   = "./modules/app_gw"
  for_each                 = local.app_gateways
  rg_name                  = data.azurerm_resource_group.main.name
  location                 = data.azurerm_resource_group.main.location
  agw_name                 = each.key
  pip                      = each.value.pip
  gateway_ip_configuration = each.value.gateway_ip_configuration
  backend_address_pool     = each.value.backend_address_pool
  tags                     = local.lab_tags
}
```

**Variables & locals (this exercise):**

*Module variables* (`modules/app_gw/variables.tf`):
```hcl
# rg_name, location, agw_name                                     (required)
# pip = object({ name, allocation_method })                       (validated Static/Dynamic)
# gateway_ip_configuration = object({ subnet_id })
# backend_address_pool = object({ ip_addresses = list(string) })  (validated: all start with 172.)
# tags = {}
```

*Root locals* (`locals.tf`) — `local.app_gateways` is **declared this exercise**; the backend pool IPs are built from `local.lb_backend_vms`, so the AGW and the ILB share exactly one backend definition:
```hcl
app_gateways = {
  "${local.agw_name}-hub" = {
    pip = { name = "${local.pip_name}-agw", allocation_method = "Static" }
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
# declared this exercise: local.agw_name = "agw-${local.prefix}"; local.pip_name = "pip-${local.prefix}"
# reused: local.lb_backend_vms (Ex 1), remote state, RG data source
# note: the module-internal local.prefix (trimprefix) is a SEPARATE scope from the root local.prefix
```

Run:
```powershell
terraform apply    # ~15-20 min
az network public-ip show -g rg-vg-lab-wus-01 -n pip-vg-lab-wus-agw --query ipAddress -o tsv
1..10 | ForEach-Object { curl.exe -s http://<that-ip> }   # both backends; cleaner round-robin than the ILB
# if 502: az network application-gateway show-backend-health -g rg-vg-lab-wus-01 -n agw-vg-lab-wus-hub -o table
```

### Q&A

**Q4 — Why does Terraform model the AGW as one resource with nested blocks and the ILB as ~5 separate resources, and which is easier to review?** Nested blocks are intrinsic and tightly bound; splitting them out would force explicit ID-wiring (several attributes) — overhead — which is why the AGW is one resource. The tradeoff: nested blocks wire **by name strings Terraform can't validate**, so mistakes surface at apply, and Set-typed blocks produce noisy replace-everything diffs. Separate resources (ILB) give **Terraform-validated `.id` references**, targeted changes, and cleaner diffs. Nested wins when you reason about the gateway *as one unit*; separate wins when you *review a change to one piece*.

---

## Topic 5 — Verify + destroy

### Theory

Teardown is the payoff for the anti-spill discipline. This stack only ever **read** the base; reads create no dependency the base tracks. Destroying `networking/lb` is safe by construction — there is nothing of the base's for it to remove. Prove it: list state (everything must be this stack's own), destroy, then confirm the base plan is `No changes`.

> **VM power state affects lifecycle ops.** azurerm issues a **power-off before deleting** a VM. Against an already-deallocated VM that's a **deterministic** 409 (`Operation 'powerOff' is not allowed … VM is … deallocated`) — not a transient race. The VM module sets `skip_shutdown_and_force_delete = true` (see Ex 1) so the delete force-deletes and skips the pre-delete power-off — the right call for lab VMs a scheduler keeps deallocating. Terraform owns lifecycle/desired state; it does **not** own runtime power — that's a separate control plane (Automation, auto-shutdown, `lab-power.ps1`), and the conflict is two control planes touching one VM.

### Exercise 5 — verify, destroy, confirm base clean

**Objective:** confirm ownership, destroy the lb stack, confirm the base is untouched.

**Constraints:**
- Every `state list` entry must be this stack's own
- The base plan afterward must be `No changes`

**Predict:**
- Destroy removes what remains (VMs + NICs + ILB pieces + AGW + PIP; data sources don't count)
- The **AGW dominates wall-time** — heavyweight fleet deprovisioning (~5–6 min), same reason create was slow, not sub-block count
- Base plan afterward: **No changes** — the lb stack only *read* the base; those resources were never in the base's state or config

**Solution** — try the exercise above before reading on.
```powershell
terraform state list      # every line is this stack's own; the hub client VM must NOT appear (it lives in the base)
terraform destroy         # AGW ~5-6 min; VMs/NICs seconds
cd ..\day08-modules
terraform plan            # predict: No changes  -> base untouched, discipline validated
```
`destroy` clears Azure resources and this stack's state — it does **not** delete your `.tf`; the reusable `load_balancer` and `app_gw` modules survive for reuse.

### Q&A

**Q5 — After you destroy the lb stack the base plan stays clean — but what did `172.22.2.100` occupy while it existed, and could the base have collided?** While it existed the ILB frontend held `172.22.2.100` inside the base's `shared` subnet. The base *could* have collided — a dynamic allocation there could have grabbed `.100` before the ILB existed, or claimed it after teardown — because **Azure's fabric is the only backstop**, not either state file. Neither the base nor the lb state tracks the other's in-subnet IP usage.

---

## Design challenge

### The challenge
1. The ILB frontend is a static `172.22.2.100` inside the base's `shared` subnet, but the ILB lives in `networking/lb`. (a) What stops the base from handing `172.22.2.100` to something else later? (b) Is a static IP in another stack's subnet safe, and what makes it unsafe?
2. HA Ports (`frontend_port = 0`, `protocol = All`) forwards everything. When is all-ports right vs a specific `:80` rule?
3. Both LBs front the same backends, but one is L4 and one is L7. Trace an HTTP request through each. What can the AGW do that the ILB structurally cannot, and what does it cost?

### The resolution
**1.** (a) Nothing in *Terraform* — the two state files are blind to each other. The backstop is **Azure's fabric**, which tracks IP usage at the subnet level: dynamic allocation skips in-use IPs, and a static allocation onto a taken IP fails at create. (b) It's safe only because the reservation exists **implicitly** — nothing in the base declares "don't touch `.100`." It becomes unsafe the moment base and lb can both allocate in that range with no coordination (base grabs `.100` before the ILB exists → ILB create fails; or ILB is destroyed and the base takes `.100`, so it can't be recreated at its address). The fix is to make the dependency **explicit** — an IPAM (NetBox), or a reservation owned by the subnet owner and exposed as an output.

**2.** All-ports fits when the backend is a **transparent transit device** (an NVA) that must receive arbitrary flows on any port — one rule covers everything. A specific `:80` rule fits when the backend is a **service endpoint** on a known port — it optimizes for precision and least exposure. The trigger is *what the backend is*, not pool size or cost.

**3.** The ILB (L4) sees a TCP SYN, picks a backend by 5-tuple hash, and **forwards packets** — it never opens the HTTP payload. The AGW (L7) **terminates** the connection, parses `GET / HTTP/1.1` + Host + path + headers, then opens a *separate* connection to a backend — which is what enables host/path routing, rewrites, cookie affinity, TLS offload, and WAF. Costs you felt: a public PIP, per-request latency (terminate + re-originate), money (~$0.25/hr vs free ILB), 15–20 min provisioning weight, slower failover, and loss of client-IP transparency (backends see the AGW's IP → need `X-Forwarded-For`).

**What this reveals.** Two through-lines. *Where you operate decides what you can decide on — and what it costs:* L4 is blind, cheap, instant, transparent; L7 understands the request but you pay in latency, dollars, operational weight, and failover lag. Same backends, same lab — the layer is the entire difference. *State boundaries don't create resource guarantees:* Terraform state is per-stack and blind across the line, so a cross-boundary dependency is exactly as safe as the coordination discipline around it. Make it explicit — an output, an IPAM, a reservation — never implicit.

---

## Corrections & gotchas

| # | Gotcha | Correction | Observed vs universal |
|---|---|---|---|
| 1 | Base subnet outputs referenced as scalars `shared_subnet_id` / `agw_subnet_id` | Day 8's debt sweep collapsed them into a map; correct refs are `hub_subnet_ids["shared"]` / `["agw"]` | Lab-specific (this repo's base contract) |
| 2 | `terraform_remote_state` read shows `(known after apply)` in `console` on a never-applied stack | Run a no-op `terraform apply` once to persist the read | Observed this lab |
| 3 | Provider defaults are landmines on `~> 3.100`: `azurerm_lb.sku`→Basic, `azurerm_public_ip.sku`→Basic, AGW `ssl_policy`→retired `AppGwSslPolicy20150501` | Pin all three explicitly (Standard / Standard / `AppGwSslPolicy20220101`). Tied to the API version this provider constraint resolves to — newer providers may default correctly, but pin regardless | Version-specific behavior; pin is universal |
| 4 | Validating an optional-but-constrained value with `contains()` | `contains()` errors on a null search value, so guard with `== null || contains([...], value)`. The lab's first pass had the operator inverted (`!= null`), which both errored on null and let any non-null value pass — fixed in the solution above | Universal (Terraform `contains`/`||` semantics) |
| 5 | ILB named `lb-vg-lab-wus-hub`; CLI Lab 7 used the `ilb-` prefix | Cosmetic naming divergence from the CLI lab; functionally fine | Lab-specific |
| 6 | AGW blocks wire **by name strings** Terraform can't validate | Keep `(A)`–`(E)` names consistent (derive once, reuse); a typo is an apply-time Azure error, not a plan error | Universal |
| 7 | AGW `request_routing_rule.priority` missing | Required on Standard_v2 (api ≥ 2021-08-01) — omit → apply error | Universal |
| 8 | AGW probe rejected — neither `host` nor `pick_host_name_from_backend_http_settings` set | Exactly one must be set for Http/Https probes | Universal |
| 9 | AGW probe timers `interval=1, timeout=3` gave ~2-min detection | `timeout <= interval`; detection ≈ first-interval + (unhealthy_threshold × interval), and v2 waits the full interval between retries. Corrected to `15/10/3` | Universal |
| 10 | `destroy` 409 `powerOff not allowed` on a deallocated VM | **Deterministic**, not transient — power the VM on first, or set `skip_shutdown_and_force_delete = true` on the VM resource | Universal |
| 11 | PowerShell `curl` (alias for `Invoke-WebRequest`) balks on HTML | Use `curl.exe` | Universal (Windows) |