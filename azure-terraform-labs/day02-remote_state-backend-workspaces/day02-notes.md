# Day 2 — Remote State, Backends & Workspaces

> **For a team member picking this up cold:** this document is self-contained for Day 2's material. It assumes the Day 0 intro and Day 1 deep-dive (state concept, the Terraform workflow, `.gitignore` rules, plan symbols, the variables/tfvars contract, PowerShell service-principal auth). Those aren't re-explained here. The exercises build the remote backend from scratch on top of the carried-forward Day 1 config.

---

## Prerequisites & continuity

**Prerequisite:** Day 0 (concepts, workflow, state, HCL, type system) + Day 1 (variables, outputs, locals, `for_each`, data sources, lifecycle).

**How this day's folder was set up.** The entire Day 1 folder was copied forward into the Day 2 folder — not just resource files, but everything: `locals.tf`, `variables.tf`, `terraform.tfvars`, `outputs.tf`, `main.tf`, and all the resource definitions. A couple of conventions make it easy to see what Day 2 touched:

- **Files prefixed `d01`** are carried-forward Day 1 files. Where Day 2 modified one, the change is wrapped in a marker block so it's easy to find:
  ```
  ##-day02 >>>  ...day-02 changes here...  ##-day02 <<<
  ```
- **Files prefixed `d02`** are new Day 2 files and contain Day 2 code only (no marker block needed).
- **`d01ex05-datasources.tf` was renamed to `d02ex06-workspaces.tf`**, because Ex 6 builds directly on top of the Day 1 data-source work — so it graduated into a Day 2 file. Its Day 2 edits still use the `##-day02` markers inside.

**Correcting one carried-over assumption.** The Day 1 notes said "only where state lives changes" for Day 2. That turned out not to be strictly true — two real code changes were needed to make workspaces work (both inside `##-day02` marker blocks):
1. In `locals.tf`, the `prefix` naming chain was rewritten to fold the workspace name into resource names.
2. In `d02ex06-workspaces.tf`, the `data "azurerm_resource_group"` block was pointed at that workspace-aware name so each workspace reads its own resource group.

Both are shown in full in Topic 6.

---

## Standard lab environment

(Full subscription/tenant/IP schema is in the Day 0 reference. Day 2 additions below.)

| Setting | Value |
|---|---|
| Region / RG | `westus` · `rg-vg-lab-wus-01` |
| Default state storage account | `stvglabwustfstate` |
| Dev state storage account | `stvglabwustfstatedev` |
| Prod state storage account | `stvglabwustfstateprod` |
| State container (each account) | `tfstate` |
| Real state key (hub-spoke) | `networking/hub-spoke` |
| Other planned keys | `networking/modules`, `networking/lb`, `networking/capstone` |

**Authentication note (read before the exercises).** This lab walks the backend using **shared-key auth**, because the RBAC role needed for the more secure Azure AD path could not be self-granted. The intended-state commands (disable shared keys, switch the backend block, and the storage-owner role grant) are in the section after Ex 4. If those storage privileges have since been arranged, use the AAD path instead.

---

## Table of contents

1. Why remote state
2. The azurerm backend
3. State locking
4. State migration (+ reaching the intended end state)
5. terraform state commands
6. Workspaces
7. Azure foundation: storage accounts & resource groups
8. Design challenge
9. Corrections & gotchas
10. Quick reference

---

## Topic 1 — Why remote state

### Theory

Day 0 established that state is Terraform's memory and that a plan is the diff between config, state, and live reality. It's worth keeping that diff in front of you as a table, because every behavior in this document falls out of it:

| | In config | Not in config |
|---|---|---|
| **In state** | compare, and **update** if different | **destroy** (Terraform assumes you removed it deliberately) |
| **Not in state** | **create** | **ignored** — outside Terraform's universe |

The most dangerous cell is top-right: a resource in state but no longer in config is **destroyed**. The bottom-right (in neither) is the safe "Terraform doesn't know it exists" case.

Day 2's starting point is a limitation of this model: with **local** state, that memory is a file on one engineer's disk. Fine solo; broken the moment a second engineer appears.

**Why local state fails on a team.** The `.tf` files are shared through Git, but `terraform.tfstate` sits on each engineer's own disk and is never shared (Day 0's `.gitignore` rules ensure it *can't* be committed). Two engineers with identical config therefore have two *divergent memories*:

- **Silent divergence.** Engineer A adds `spoke3` and applies; it's recorded only in A's local state. Engineer B, who never pulled A's code, has `spoke3` in neither their config nor their state, so B's runs ignore it (bottom-right cell). Nothing breaks yet. The landmine detonates later: when B pulls A's code, B's config now declares `spoke3` but B's state has never heard of it (bottom-left → **create**) — and the create fails or clobbers because the VNet already exists in Azure.
- **The lost update.** If two applies write the *same* state file at nearly the same moment, the second to finish overwrites the first's recorded changes. One engineer's work vanishes from state even though it exists in Azure; the next plan then proposes to recreate things that already exist.

**A resource-modeling trap that amplifies this.** Azure subnets can be modeled two ways, and the choice sets your blast radius:

- **Separate `azurerm_subnet` resources** — each subnet is independently tracked with its own state address. A subnet in nobody's config or state is ignored. Safe. (This is what our lab uses — see `d01ex04-foreach.tf`, which creates subnets via a `for_each` on separate `azurerm_subnet` resources.)
- **Inline `subnet { }` blocks inside `azurerm_virtual_network`** — the subnet has no independent identity; it's an *attribute* of the VNet. Terraform treats the VNet's subnet list as complete and authoritative, so any subnet not declared there is seen as drift and **removed**. One engineer's config silently owns *every* subnet on that VNet.

The principle: **the granularity at which state tracks objects equals the granularity of your blast radius.** Prefer separate `azurerm_subnet` resources. (The azurerm provider also warns against mixing both styles on one VNet — they fight each other.)

**What a remote backend adds over local state:** a single shared source of truth (no divergence); locking (Topic 3); and encryption at rest plus durability (state holds plaintext secrets — far safer in Blob than on a laptop).

### Q&A

**Q1 — Two engineers share `main.tf` via Git but each hold local state. You add `spoke3` and apply. Your teammate, without pulling your code, adds a subnet to the hub VNet (a resource present in both configs and both state files) and applies. After both applies, is the hub subnet safe?**

It depends entirely on how the subnet is modeled. If it's a separate `azurerm_subnet` resource (as in our lab): your state and config never reference the teammate's subnet, so your next `plan` sees a subnet in neither your state nor config and ignores it (bottom-right cell) — safe. But if subnets were inline `subnet{}` blocks on the hub VNet (which *is* in your state and config), your `plan` refreshes the VNet, sees a subnet your config doesn't declare, treats the VNet's declared list as authoritative, and proposes to **remove** the teammate's subnet. Same divergence, opposite outcome — decided purely by resource modeling. Concrete reason to prefer separate `azurerm_subnet` resources.

---

## Topic 2 — The azurerm backend

### Theory

Day 0 showed the shape of the backend block. In our lab it lives in its own file, **`backend.tf`** (separate from `main.tf`, which holds only the `terraform`/provider config):

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-vg-lab-wus-01"
    storage_account_name = "stvglabwustfstate"
    container_name        = "tfstate"
    key                    = "networking/hub-spoke"
    # use_azuread_auth     = true   # intended end state — see Topic 4
    # use_cli              = true
  }
}
```

(The two `use_*` lines are commented out because this lab runs on shared-key auth; the intended-state section in Topic 4 explains when to uncomment them.)

The four core arguments:

- **`resource_group_name`** — the RG holding the *storage account* (not necessarily your workload's RG, though here they coincide).
- **`storage_account_name`** — the globally-unique storage account holding your state blobs.
- **`container_name`** — the blob container inside that account.
- **`key`** — the **blob name** for this specific state file. Not the storage access key — just the filename. It's how one storage account + container holds many independent state files side by side. Our four planned keys (`hub-spoke`, `modules`, `lb`, `capstone`) are four separate blobs, like four labelled files in one drawer.

**The backend block cannot use variables, `local.*`, or any interpolation — literal strings only.** Terraform parses this block during `init`, before it evaluates variables. But the deeper reason is stronger than ordering: the backend defines *which state file a working directory talks to*, and that mapping must be fixed for the directory, independent of whatever `-var` flags or `.tfvars` a given command uses. If the backend could read a variable, two `plan` commands in the same folder run with different `-var` values could silently point at two different state blobs — and the whole compare-config-vs-state-vs-reality model collapses once "which state" becomes a moving target.

**Partial configuration** works around this without hardcoding sensitive/environment-specific values: leave arguments out of the block and supply them at init time.

```powershell
terraform init `
  -backend-config="storage_account_name=stvglabwustfstate" `
  -backend-config="key=networking/hub-spoke"
```

This lets a pipeline drive a different `key` or storage account per environment without editing `.tf` files.

**Authentication.** The backend reaches the storage account one of three ways:
- **Shared account key** — the backend calls `listKeys` on the account and uses the returned key. The *default* path, and the one this lab uses.
- **Azure AD / Entra auth** (`use_azuread_auth = true`) — uses the caller's identity and its RBAC data-plane role. No shared secret. The intended end state.
- **CLI session** (`use_cli = true`) — rides on your existing `az login` for interactive work.

A security subtlety worth understanding regardless: the built-in **Contributor** role includes `Microsoft.Storage/storageAccounts/listKeys/action`. Anyone with Contributor can fetch the account key and get full read/write on every blob — bypassing any data-plane RBAC. To truly enforce RBAC-only access you must disable shared key access. But Contributor's definition *also* excludes `Microsoft.Authorization/*/Write`, so a Contributor cannot self-assign the `Storage Blob Data Contributor` role that AAD auth needs — that requires Owner or "Role Based Access Control Administrator," held by a storage owner.

**Locking granularity — a consequence of `key`.** A lock is a lease on a single *blob*, identified by its `key`, not on the container or account. So an apply on `networking/hub-spoke` and a simultaneous apply on `networking/capstone` never block each other. Two applies on the *same* key do contend.

### Exercise — Ex 1: create the backend storage account and container

**Objective:** create the storage account and container that today's state lives in.

```powershell
az storage account create `
  --resource-group rg-vg-lab-wus-01 `
  --name stvglabwustfstate `
  --location westus `
  --sku Standard_LRS `
  --kind StorageV2 `
  --allow-blob-public-access false `
  --bypass AzureServices `
  --tags owner=vg env=lab purpose=networking

az storage container create --name tfstate --account-name stvglabwustfstate --auth-mode login
```

**Why `--bypass AzureServices`?** Our environment has a management-group policy set (`mg-wondering-packet-all`, "Security Initiative - High Global Policies") requiring every storage account to allow trusted Microsoft services through its network ACLs. Without this flag, create/update is denied with `RequestDisallowedByPolicy`. It only permits first-party Azure services to bypass the network ACL; it does not affect key vs. AAD auth.

**Why `--auth-mode login` on the container command?** Without it, the CLI silently defaults to key-based auth, fetching the account key via `listKeys`. Specifying `login` forces authentication as *your* Entra identity via RBAC — the correct habit for every `az storage` data-plane command.

Design choices: `Standard_LRS` fits lab state (durability without geo-replication you won't use); `--allow-blob-public-access false` blocks anonymous access to state; `stvglabwustfstate` is 17 lowercase-alphanumeric chars, inside Azure's 3–24 char globally-unique constraint.

### Q&A

**Q1 — Given the backend block is read before variables exist, why is it technically impossible for Terraform to support `resource_group_name = var.rg_name` there, even in principle?**

Variable values come from `-var` flags, `.tfvars`, `TF_VAR_*` env vars, or defaults — and can differ between command invocations. If the backend could read a variable, the same working directory could point at different state blobs on two runs minutes apart depending on which flags were passed. The invariant a backend must guarantee is that a directory always maps to exactly one state file, regardless of command-line inputs. A variable-driven backend breaks that invariant — forbidden not merely because variables aren't loaded yet, but because allowing it would make "which state am I managing" ambiguous.

**Q2 — One storage account, one container, four `key` values. Why is it safe to `apply` on `hub-spoke` and on `capstone` at the same time? What's the unit that gets locked?**

Each `key` is a genuinely separate blob object. The backend acquires a **lease on the specific blob** it's about to write — the lease attaches to that one blob, not the container or account. `hub-spoke` and `capstone` are two different blobs, so two applies lease two different objects and never contend. Only two applies against the *same* key collide. The locked unit is the individual state blob, identified by its `key`.

---

## Topic 3 — State locking

### Theory

Locking prevents two operations writing the same state file at once. On azurerm it's **on by default and cannot be disabled** except via `-lock=false` (a last resort).

**Mechanism: a blob lease.** Azure builds locking into the state blob itself — before writing, Terraform acquires a *lease* on the blob. There's no separate lock file; the state blob *is* the lock. You see it in the CLI (`Acquiring state lock...` / `Releasing state lock...` around every operation) and in the Portal (the blob's lease state shows "Locked" during an apply, "Available" after).

A collision produces:

```
Error: Error acquiring the state lock

Error message: state blob is already locked
Lock Info:
  ID:        c019b207-...
  Path:      networking/hub-spoke
  Operation: OperationTypeApply
  Who:       vipin@LAPTOP-XYZ
  Created:   2026-07-15 14:05:33 UTC
```

`Who` and `Created` are your diagnostics — genuine in-flight operation, or stale leftover?

**Stale locks.** If the process holding the lease crashes, is killed, or loses its network mid-apply, **Azure does not auto-expire the lease** — it persists indefinitely until broken. The documented recovery is `terraform force-unlock <LOCK_ID>`, but there's a known azurerm-specific bug where that fails with `LeaseIdMissing` / HTTP 412. The reliable fallback is to break the lease directly:

```powershell
az storage blob lease break `
  --account-name stvglabwustfstate `
  --container-name tfstate `
  --blob-name networking/hub-spoke
```

**Before breaking any lock, verify nothing is really running** — check `Who`/`Created`, ask the team, check CI. Breaking the lease on a genuinely in-flight apply can corrupt a half-written state file, far worse than the stale lock.

**The lock is held for the entire apply — including long provisioning waits.** A plain interactive `terraform apply` acquires the lock *before* computing the plan and holds it through plan → the yes/no prompt (however long you deliberate) → apply → release. This covers slow resources: creating something like an Azure Firewall (30+ min) holds the lock the whole time, because the provider's `Create` submits the request to Azure Resource Manager and then *blocks*, polling until Azure reports success/failure before returning. Terraform can't move on — or release the lock — until then. By design: it makes it impossible for a second engineer's apply to land on a resource still mid-provisioning.

**The two-step workflow avoids holding the lock during human review:**

```powershell
terraform plan -out=tfplan     # lock held only for the plan's duration, then released
terraform apply tfplan         # a fresh, short-lived lock just for the apply
```

The saved plan file holds no lock — review it as long as you like. But it's pinned to the state's **serial number** at creation. If anyone else applies in the interim (advancing the serial), `terraform apply tfplan` refuses with `Error: Saved plan is stale` rather than silently overwriting. *Any* state change invalidates the whole plan, even an unrelated no-op that bumped the serial.

**`-lock-timeout`.** Default `0s` — fail instantly on any held lock. Setting `-lock-timeout=5m` makes Terraform automatically *retry* acquiring the lock for that window before failing (the command appears to hang, printing `Lock Info`, then proceeds if the lock frees or fails at the end). A courtesy for *ordinary* contention — a colleague's real apply about to finish — not a defense against stale locks, which never release regardless of wait.

### Q&A

**Q1 — Two engineers, same backend, same state blob, `apply` at the exact same second. What does the second apply's terminal show, and does its plan calculation still happen or get blocked first?**

Whichever acquires the lease first runs its full plan → approval → apply → release cycle. The second attempts to acquire the lock as its *very first step*, before computing anything, finds the blob leased, and fails immediately with `Error acquiring the state lock`. Its plan is never calculated — blocked before that. (With `-lock-timeout` set, it instead waits and retries for the window.)

**Q2 — Some resources take up to an hour to provision. Does the apply hold the lock the whole time? If you're spinning up a firewall that takes 30 minutes, is that good or bad?**

It holds the lock the entire time, and that's good. The provider's `Create` for a long-running resource blocks and polls Azure Resource Manager until the resource reaches a terminal state, then returns — only then can the lock release. This is *why* a second engineer's apply against the same firewall can't start while it's still coming up; they'd hit the held lock. If the lock released early, that protection would vanish and a concurrent apply could act on a half-built resource. (State is persisted incrementally as each resource finishes, so a later failure doesn't lose earlier successes — but the single overall lock stays held across the whole apply command.)

---

## Topic 4 — State migration

### Theory

Migration moves existing state from one backend to another — here, from local disk into the azurerm blob. Day 0 introduced `terraform init -migrate-state`; here's the full flow.

**`-migrate-state` vs. `-reconfigure` — don't confuse them:**

| | `-migrate-state` | `-reconfigure` |
|---|---|---|
| Use when | The backend genuinely changed and you want existing state **copied** to the new location | Only Terraform's local *cache* of the backend config is stale; the real backend didn't move |
| Effect | Copies state content to the new backend | Discards the cache, initializes fresh against the block as written, **copies nothing** |
| Danger | — | If the backend really did change and you use this by mistake, Terraform starts believing it manages *nothing* and may try to recreate everything |

**The flow:** have a local `terraform.tfstate` (from a prior local apply) → add the `backend "azurerm"` block → run `terraform init -migrate-state` → answer `yes` at the copy prompt → Terraform pushes the full local state into the blob at your `key`. Terraform writes a one-time local `terraform.tfstate.backup` before touching the original. **Verify two ways:** confirm the blob exists (`az storage blob list`) and — the important one — run `terraform plan`, which should report **zero changes**. Any unexpected diff means stop and investigate. If local state had multiple workspaces, `-migrate-state` copies all of them.

> The one-time `.tfstate.backup` is **not** maintained once you're on a remote backend — don't treat it as an ongoing backup. Ongoing protection comes from the backend's own features (blob versioning, container soft delete).

**The real post-migration risk.** Once remote state is the source of truth, a teammate who still has the old local `terraform.tfstate` and hasn't pulled the new backend block keeps applying against their local file. There's **no lock contention and no error** — their operations touch a completely different object (local disk) than the remote blob, so the lease system never sees a conflict. Two independent "sources of truth" silently coexist until drift or a destructive apply exposes it. Worse than a lock conflict precisely because a lock conflict is loud and safe, whereas this is silent.

### Exercise — Ex 2 + Ex 3 + Ex 4: generate local state, add the backend, migrate

**Objective:** generate real local state, point the config at the remote backend, migrate the state into Azure, and prove it's intact.

**Ex 2 — generate local state.** The Day 1 hub-spoke environment was already carried forward into this folder. A small NSG was added in a new file, **`d02ex02-update_state.tf`**, purely to exercise the flow and write fresh local state, then the full config was applied against local state:

```powershell
terraform init
terraform plan
terraform apply
```

After apply, `terraform state list` confirmed the full inventory in local state:

```
data.azurerm_resource_group.main
azurerm_network_security_group.d02-temp-nsg
azurerm_network_security_group.main["app"]
azurerm_network_security_group.main["web"]
azurerm_subnet.hub["app"]
azurerm_subnet.hub["db"]
azurerm_subnet.hub["mgmt"]
azurerm_subnet.hub["web"]
azurerm_virtual_network.hub
azurerm_virtual_network.spoke1
```

Because this is the genuine hub-spoke environment, it was migrated under the real key `networking/hub-spoke`.

> Note: `d02ex02-update_state.tf`'s NSG resource is now **commented out** in the final code — Ex 5 (`d02ex05-rename.tf`) took over that NSG under a renamed address. The `d02ex02` file is kept as a record of where the state-generating resource originated.

**Ex 3 — add the backend block** in `backend.tf` (shared-key version — the `use_*` lines stay commented; see the intended-state section for why):

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-vg-lab-wus-01"
    storage_account_name = "stvglabwustfstate"
    container_name        = "tfstate"
    key                    = "networking/hub-spoke"
    # use_azuread_auth     = true
    # use_cli              = true
  }
}
```

With shared key access enabled on the account (its default at creation), this block needs no explicit auth arguments — the backend fetches the account key automatically via the same `listKeys` mechanism the CLI uses.

**Ex 4 — migrate and verify:**

```powershell
terraform init -migrate-state
```
```
Initializing the backend...
Acquiring state lock. This may take a few moments...
Do you want to copy existing state to the new backend?
  ... Enter a value: yes
Releasing state lock. This may take a few moments...
Successfully configured the backend "azurerm"!
Terraform has been successfully initialized!
```

Verify the blob landed:

```powershell
az storage blob list -c tfstate --account-name stvglabwustfstate
```
```
[
  {
    "name": "networking/hub-spoke",
    "properties": { "contentLength": 15739, "blobType": "BlockBlob", ... }
  }
]
```

Decisive check:

```powershell
terraform plan
```
```
No changes. Your infrastructure matches the configuration.
```

Zero changes confirms the migration was byte-accurate.

### Reaching the intended end state (AAD auth, no shared keys)

The lab above runs on shared-key auth as a fallback. The intended, more secure end state is Azure AD auth with shared keys disabled entirely, so blob access is governed purely by RBAC. Three steps — the last needs a storage owner:

**1. Disable shared key access on the storage account.** (Re-include `--bypass AzureServices` — the `mg-wondering-packet-all` policy re-evaluates the whole resource on any update, so omitting it fails with `RequestDisallowedByPolicy`.)

```powershell
az storage account update `
  --name stvglabwustfstate `
  --resource-group rg-vg-lab-wus-01 `
  --allow-shared-key-access false `
  --bypass AzureServices
```

**2. Enable AAD auth in `backend.tf`** by uncommenting the two `use_*` lines:

```hcl
    use_azuread_auth = true
    use_cli          = true
```

Then re-run `terraform init` to pick up the changed auth arguments. (No `-migrate-state` needed — the storage location isn't changing, only how it authenticates.)

**3. A storage owner must grant the data-plane role — the piece we couldn't self-serve.** Contributor cannot assign RBAC roles (it excludes `Microsoft.Authorization/*/Write`), so someone with Owner or "Role Based Access Control Administrator" has to add **both** the individual engineer's account **and** the Terraform service principal to the `Storage Blob Data Contributor` role, scoped to the storage account. Without this, step 1 immediately locks everyone out of the blob (no key path left, no RBAC path yet). Per identity:

```powershell
az role assignment create `
  --assignee <object-id-of-user-or-SP> `
  --role "Storage Blob Data Contributor" `
  --scope "/subscriptions/<your-subscription-id>/resourceGroups/rg-vg-lab-wus-01/providers/Microsoft.Storage/storageAccounts/stvglabwustfstate"
```

Scope it to the storage account, not the subscription — the right-sized grant, and easier to get approved. Once both identities hold the role, the AAD backend authenticates cleanly and the shared-key door is fully closed.

### Q&A

**Q1 — You migrated to remote state. A teammate still has the old local `terraform.tfstate` on disk and hasn't pulled your backend change. They run `terraform apply`. What happens, and what's the actual risk?**

Their Terraform doesn't error and doesn't notice anything — it reads and writes their local file as before. No lock contention, because locking only guards operations against the *same blob*; their local file and the remote blob are entirely separate objects the lease system never compares. So you now have two independent Terraform "brains," each convinced it's the authoritative source of truth for the same real infrastructure, with no warning to either. The risk is silent state divergence surfacing later as drift or a destructive apply — scarier than a lock conflict precisely because a lock conflict fails loudly and safely, while this fails silently.

---

## Topic 5 — terraform state commands

### Theory

Four commands to inspect and surgically manipulate state, each mapping onto one side of the reconciliation table:

- **`terraform state list [prefix]`** — read-only inventory of tracked resource addresses. Filterable by prefix or module. Writes no backup.
- **`terraform state show <address>`** — full attribute dump for one resource as currently recorded. Answers "what does Terraform believe this looks like right now" without touching Azure.
- **`terraform state mv SOURCE DESTINATION`** — re-binds an existing real object to a *new Terraform address*, with **zero Azure API calls**. Correct order: rename the `.tf` label first, then `state mv`, then `plan` to confirm zero changes. (`-dry-run` previews it.)
- **`terraform state rm <address>`** — removes the entry from **state only**; the real Azure resource is untouched and keeps running (and billing). Terraform just forgets it exists.

**The distinction behind `state mv`: a resource's *label* is not its *arguments*.** In `resource "azurerm_network_security_group" "d02-temp-nsg2"`, the `d02-temp-nsg2` part is a purely internal Terraform identifier with no connection to any real Azure property. The real object's identity comes from arguments like `name` and `resource_group_name`. Renaming the *label* is free via `state mv`. Changing the *`name` argument* is a real change to the Azure resource — and since Azure NSG names can't change in place, that forces a **destroy-and-recreate** (`-/+ replace`), almost never what you intend when "renaming."

**`state rm` and its trap.** After `state rm`, the resource is in config but no longer in state → your next `apply` tries to **create** it fresh, which in Azure usually errors ("already exists"). So `state rm` alone, without also editing config, is a loaded gun aimed at your next apply. Legitimate use: handing a resource between teams — team A `state rm` to disown it, team B `terraform import` to adopt the same live object.

**Safe-sequencing principle for any two-step state surgery.** When two steps must happen with an unavoidable gap, order them so anything landing in the gap fails *safely* rather than *destructively*. For a handoff, run `state rm` **first**, delete the `.tf` block **second**: an apply in the gap then fails harmlessly with "already exists." The reverse order (delete config first) means an apply in the gap sees "in state, not in config" → **destroys a live resource**. Cheap failure first, expensive failure never.

All of these work identically against a remote backend. The mutating commands (`mv`, `rm`) always write a local backup first — can't be disabled, only redirected with `-backup`.

### Exercise — Ex 5: inspect and rename a resource without recreating it

**Objective:** read the migrated remote state, then rename a resource's Terraform address using `state mv` and prove no real resource was touched.

Inspect:

```powershell
terraform state list
terraform state show azurerm_network_security_group.d02-temp-nsg
```

Rename — the renamed block lives in **`d02ex05-rename.tf`** (carried on from `d02ex02`'s original NSG). **Only the label changed** (`d02-temp-nsg` → `d02-temp-nsg2`); every argument, including `name`, is identical:

```hcl
# d02ex05-rename.tf — renamed from "d02-temp-nsg" for the terraform state mv exercise
resource "azurerm_network_security_group" "d02-temp-nsg2" {
  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  name                = "${local.nsg_name}-temp"   # unchanged — a real Azure property
}
```

Point the existing tracked object at the new label:

```powershell
terraform state mv azurerm_network_security_group.d02-temp-nsg azurerm_network_security_group.d02-temp-nsg2
```
```
Move "azurerm_network_security_group.d02-temp-nsg" to "azurerm_network_security_group.d02-temp-nsg2"
Successfully moved 1 object(s).
```

Confirm the label moved and reality is untouched:

```powershell
terraform state list          # now shows ...d02-temp-nsg2
terraform plan                # No changes. Your infrastructure matches the configuration.
```

> **Common mistake to avoid:** changing the `name` *argument* instead of the label. That's not a rename — it edits a real Azure property, and since NSG names are immutable, `plan` shows `-/+ must be replaced` (destroy + recreate). If you see `-/+ replace` when you only meant to rename, you edited an argument, not the label.

### Q&A

**Q1 — You run `terraform state rm azurerm_virtual_network.hub` with config untouched. What does `terraform plan` show immediately after? And what would you have needed to do differently if the goal was to hand this VNet to another team's Terraform project?**

Immediately after, `plan` shows Terraform wanting to **create** the hub VNet — it's now in config but not in state. An `apply` would almost certainly fail "already exists," since the VNet is still live. For a clean handoff, `state rm` is the right disown step, but sequencing matters: run `state rm` **first** (while the `.tf` block still exists), then delete the `.tf` block — so an accidental apply in the gap fails safely with "already exists" rather than destroying the live VNet. The other team then runs `terraform import` to adopt the same real object — no destroy/recreate anywhere.

---

## Topic 6 — Workspaces

### Theory

A workspace uses the **same backend and same `key`**, but Terraform transparently manages a **separate state file per workspace** underneath it. You always start in `default`. Your `.tf` files, backend block, and providers are identical across every workspace — **only the state differs**.

```powershell
terraform workspace new dev       # create AND switch to it
terraform workspace select prod   # switch to an existing one
terraform workspace list          # list all; * marks current
terraform workspace show          # print just the current name
terraform workspace delete dev    # remove it (must not be the active one)
```

`terraform.workspace` is a built-in reference for varying values by workspace. It's the *only* mechanism that makes a workspace behave differently — workspaces do **not** branch config automatically; you write the conditional yourself.

**Azure blob naming quirk.** Non-default workspaces don't get a tidy folder path. The azurerm backend **appends `env:<workspace>` directly onto the `key`** — no separator. With `key = "networking/hub-spoke"`, the `dev` workspace's blob is literally `networking/hub-spokeenv:dev`. The `default` workspace uses the bare `key`. Looking for an `env:/dev/...` subfolder means looking for the wrong shape.

**A brand-new workspace's state is completely empty** — not a copy of anything. This matters more than it first appears: applying your *unmodified* config into a fresh workspace does **not** safely spin up a parallel copy. If resource names and resource group are fixed (e.g. static locals), the new workspace's apply tries to create the *same* names in the *same* resource group a second time, and Azure rejects it ("already exists"). Workspaces isolate *state*; they do nothing on their own to stop two workspaces claiming the same real resource name in the same scope.

For a workspace to hold a genuinely separate, non-colliding set of resources, **the config must be made workspace-aware**: fold `terraform.workspace` into resource naming, and/or vary the resource group per workspace.

**Config is never workspace-scoped.** Because the `.tf` files are shared, switching workspaces never toggles a code edit on or off — a change saved in a file is visible to *every* workspace instantly. "Test a hotfix in one workspace, discard it by switching back" does not work: the edit is in the file for every workspace, and prod's `plan` would propose to apply it too. Only *already-applied state* differs per workspace, never the pending code.

**Workspaces vs. separate directories.** Because every workspace shares identical code, the only thing separating dev resources from prod is which workspace is selected in your terminal — no separate backend, no credential boundary, no approval gate, just a name you must remember to `select`. Forget to switch and a "dev" change applies straight against prod. Separate directories (a `dev/`, `staging/`, `prod/` folder, each with its own backend block and ideally its own storage account) give real isolation: wrong environment means a wrong `cd`, and you can enforce genuinely different RBAC per environment at the storage-account level. Guidance is explicit: workspaces suit short-lived, disposable parallel copies (a personal sandbox, an ephemeral per-PR preview) — **not** a permanent dev/staging/prod boundary.

**Good vs. bad uses of workspaces:**

| Use case | Good fit? | Why |
|---|---|---|
| Personal disposable sandbox, torn down after use | Yes | Genuinely throwaway; resources never need to merge anywhere |
| Ephemeral per-PR / per-branch CI environments | Yes | Created and destroyed wholesale; config made workspace-aware so names/scope never collide |
| Parallel identical demo/POC environments | Yes | No config variation needed beyond naming disambiguation; no promotion step |
| Testing a hotfix before promoting to prod | No | Config is shared — the edit is visible to every workspace instantly |
| Permanent dev/staging/prod boundary | No | Zero credential/access-control separation; a wrong `select` silently applies to the wrong environment |
| Environments needing different access control | No | One backend, one credential path, for every workspace |

The genuinely safe way to preview a change before it touches prod isn't a throwaway workspace — it's `terraform plan` against prod's own real state (read-only, free) and/or a real, *persistent* staging environment with its own backend.

### Exercise — Ex 6: workspaces and workspace-aware naming

**Objective:** create `dev` and `prod` workspaces, make the config workspace-aware so environments don't collide, and prove isolation.

**The config changes that made this work** (both inside `##-day02` marker blocks). First, in **`locals.tf`**, the naming chain was rewritten so the workspace name drives the environment portion of every resource name, with a self-scaling fallback:

```hcl
##-day02 >>> changed the naming resolution for d02ex06.
# earlier:  prefix = "${var.owner}-${var.environment}-${local.region_code}"
# replaced var.environment with the new local.environment below.
environment = terraform.workspace == "default" ? "lab" : terraform.workspace
prefix      = "${var.owner}-${local.environment}-${local.region_code}"
vnet_name   = "vnet-${local.prefix}"
rg_name     = "rg-${local.prefix}"
nsg_name    = "nsg-${local.prefix}"
##-day02 <<<
```

> **Why the fallback matters:** a narrower conditional like `terraform.workspace == "dev" ? "dev" : var.environment` only special-cases `dev` — a later `prod` workspace would fall through to `var.environment` ("lab") and collide with the real `default` environment. The `== "default" ? "lab" : terraform.workspace` form handles every current and future workspace automatically.

Second, in **`d02ex06-workspaces.tf`** (the renamed Day 1 data-source file), the `data "azurerm_resource_group"` block was pointed at the workspace-aware name so each workspace reads its own resource group:

```hcl
##-day02 >>>
# "dev" workspace  -> rg-vg-dev-wus-01
# "prod" workspace -> rg-vg-prod-wus-01
# anything else    -> rg-vg-lab-wus-01
# ensure rg-vg-dev-wus-01 & rg-vg-prod-wus-01 exist beforehand.
data "azurerm_resource_group" "main" {
  name = "${local.rg_name}-01"
}
##-day02 <<<
```

**Creating and proving isolation.** Because the data source only *reads* a resource group (never creates one), each non-default workspace needs its resource group to already exist. Create it, then plan:

```powershell
az group create `
  --name rg-vg-dev-wus-01 `
  --location westus `
  --tags owner=vg env=lab purpose=networking

terraform workspace new dev
terraform workspace list        # shows: default  and  * dev
terraform plan
```

The `dev` plan correctly showed **9 resources to create** — a fully separate hub-spoke with `dev` in every name, targeting `rg-vg-dev-wus-01`:

```
Plan: 9 to add, 0 to change, 0 to destroy.
  # azurerm_virtual_network.hub  -> name = "vnet-vg-dev-wus-hub", resource_group_name = "rg-vg-dev-wus-01"
  # azurerm_subnet.hub["app"]    -> virtual_network_name = "vnet-vg-dev-wus-hub"
  ... (all 9 resources named with "dev", not "lab")
```

The same was verified against a `prod` workspace (`rg-vg-prod-wus-01` created the same way). **No `apply` was run in `dev` or `prod`** — the `plan` output alone proves isolation (distinct names, distinct resource group, all *creates* with zero destroys touching the real `default` environment). Standing up a throwaway parallel environment just for a demo would waste real Azure resources; the plan is the proof.

Switching back confirmed the real environment was untouched:

```powershell
terraform workspace select default
terraform plan                  # No changes. Your infrastructure matches the configuration.
```

> **On cleanup:** the `rg-vg-dev-wus-01` and `rg-vg-prod-wus-01` resource groups are kept (they anchor the dev/prod state storage accounts in Topic 7). If resources had been *applied* into a workspace, the correct teardown is `terraform destroy` with the workspace selected — never commenting out config — followed by `terraform workspace delete`, which safely refuses to delete a workspace whose state still holds resources.

### Q&A

**Q1 — Workspaces vs. separate directories for dev/staging/prod: which is safer for production, and why? Is there a legitimate use for the `dev`/`prod` workspaces this exercise created, or is the exercise itself the anti-pattern?**

Separate directories are safer. Workspaces share one backend, one credential path, and identical code — the only thing keeping a "dev" change out of prod is remembering to `select` the right workspace, with no access boundary or approval gate. Separate directories give a real filesystem boundary and let you enforce different RBAC per environment at the storage-account level. The exercise's `dev`/`prod` workspaces are fine *as a teaching demonstration of the mechanics* — creating them, seeing the `env:`-suffixed blobs, proving `terraform.workspace` drives non-colliding names. But using workspaces this way for a *real* permanent dev/prod split is the anti-pattern; the design challenge lays out the correct production structure (separate directories and separate storage accounts per environment).

---

## Topic 7 — Azure foundation: storage accounts & resource groups

Beyond the single lab backend, the multi-environment foundation a real team needs was built: **three storage accounts** (one per environment) and **three resource groups**. Separate storage accounts per environment — not just separate containers in one account — is the stronger isolation choice: each account carries its own data-protection settings (soft-delete/retention, network rules, lifecycle) and its own blast radius, so prod's protections can be strictly tighter without dev/staging inheriting or diluting them.

**Created:**

| Environment | Storage account | Resource group |
|---|---|---|
| Default / lab | `stvglabwustfstate` | `rg-vg-lab-wus-01` |
| Dev | `stvglabwustfstatedev` | `rg-vg-dev-wus-01` |
| Prod | `stvglabwustfstateprod` | `rg-vg-prod-wus-01` |

Sample storage account creation (prod shown; dev/default identical bar names):

```powershell
az storage account create `
  --resource-group rg-vg-prod-wus-01 `
  --name stvglabwustfstateprod `
  --location westus `
  --sku Standard_LRS `
  --kind StorageV2 `
  --allow-blob-public-access false `
  --tags owner=vg env=lab purpose=networking
```

Sample resource group creation (prod shown):

```powershell
az group create `
  --name rg-vg-prod-wus-01 `
  --location westus `
  --tags owner=vg env=lab purpose=networking
```

**Operational cost to be aware of:** three separate storage accounts means the `Storage Blob Data Contributor` grant needed for the AAD end state (Topic 4) must be made **three times — once per account** — for both individual engineers and the Terraform service principal. This triples the storage-owner request that a plain Contributor can't self-serve. A worthwhile trade for the isolation, but plan for it rather than discover it.

---

## Design challenge

**Prompt:** design a state-management strategy for 5 engineers, 3 environments (dev/staging/prod), 2 regions.

> **The prompt gives you four state keys to work with** — the lab's standard `networking/hub-spoke`, `networking/modules`, `networking/lb`, `networking/capstone`. The design below uses those four keys as the per-environment/region module split.

### Environments and prod access — the decisive choice

Environments are split into **separate directories, each with its own backend and its own storage account.** Workspaces were rejected for environment separation for one reason tied directly to the prod-access requirement: all workspaces for a given `key` live as blobs inside the *same container*, and Azure RBAC is granted at the storage-account/container level, not per-blob. So you *cannot* cleanly restrict access to only the prod state if prod is merely a workspace — granting container access to reach prod's blob also grants access to dev's and staging's blobs beside it. Only genuinely separate containers/accounts per environment let you scope prod access to the team lead (and, in practice, the deployment pipeline's identity) while leaving dev/staging open to the whole team.

### Modules — the four keys

Within each environment/region, state is split by module into the four keys (`hub-spoke`, `modules`, `lb`, `capstone`). The reason is **blast radius and plan speed**, not just tidiness: a bad `capstone` apply structurally cannot corrupt `hub-spoke`'s state, and each `plan` only refreshes its own slice of resources. (File readability is *not* a real reason — `state show`/`state list` scope to a single resource regardless of total state size.)

### Regions — the two options considered

**Option A — separate subdirectories per region** (chosen). Each environment directory contains a `westus/` and `centralus/` subdirectory, each with its own backend.
- *Strength:* stronger blast-radius isolation (a bad `centralus` apply can't touch `westus` state) and faster per-region plans.
- *Weakness:* more directories and backends to manage.

**Option B — no region split.** One backend per environment directory covering both regions.
- *Strength:* simpler — fewer directories/backends.
- *Weakness:* larger blast radius and slower plans, since every apply/refresh spans both regions.

**Chosen: Option A**, on blast-radius and plan-speed isolation — regions treated as independent failure domains.

**Resulting count:** 3 environments × 2 regions × 4 keys = **24 state files.** (Option B would give 3 × 4 = 12.)

### Hierarchy

```
Terraform IaC repo
├── dev/                         backend -> stvglabwustfstatedev    (team-wide access)
│   ├── westus/                  backend block, keys:
│   │   └── hub-spoke · modules · lb · capstone
│   └── centralus/               backend block, keys:
│       └── hub-spoke · modules · lb · capstone
├── staging/                     backend -> (staging storage acct)  (team-wide access)
│   ├── westus/
│   │   └── hub-spoke · modules · lb · capstone
│   └── centralus/
│       └── hub-spoke · modules · lb · capstone
└── prod/                        backend -> stvglabwustfstateprod   (lead + pipeline only)
    ├── westus/
    │   └── hub-spoke · modules · lb · capstone
    └── centralus/
        └── hub-spoke · modules · lb · capstone
```

Each leaf `westus/` or `centralus/` directory holds its own `backend "azurerm"` block; the four keys are the four state blobs within that environment's storage account.

### Access model

Prod's separate storage account is RBAC-restricted (via `Storage Blob Data Contributor` scoped to that account) to the team lead and the deployment pipeline's service principal only. Dev and staging accounts are open to the full team. This is exactly why environments are separate accounts and not workspaces — it's the only structure where "restrict prod state" is actually enforceable.

### ⚠️ This is a learning-shaped answer, not a production blueprint

A few honest caveats a real design would have to address:

- **Workspaces aren't encouraged in the real world** for this kind of separation — they appear in Day 2 because they're worth *knowing*, not because they'd anchor a real environment strategy. The design above deliberately uses directories/accounts instead.
- **CI/CD does the heavy lifting in reality.** In a real setup the pipeline — not an engineer's laptop — runs `plan` on pull requests and `apply` on merge, and handles promotion of a change through dev → staging → prod with approval gates. The prod service principal (holding the restricted prod-state access) is what actually applies to prod. That whole layer is later-day material and is intentionally out of scope here.
- **Many other considerations exist** that this answer doesn't model: state backup/versioning and disaster recovery, policy-as-code guardrails, secret handling, cost controls, drift detection, and how modules get versioned and shared across these directories. Treat this as a sound *state-layout* answer, not a complete platform design.

---

## Corrections & gotchas

| # | Gotcha | Correction |
|---|---|---|
| 1 | Contributor role includes `Microsoft.Storage/storageAccounts/listKeys/action` | Any Contributor can fetch the account key and bypass RBAC entirely for blob data, regardless of assigned data-plane roles. To truly enforce RBAC-only access, disable shared key access — and note the AAD end state needs a role assignment Contributor cannot self-grant (it excludes `Microsoft.Authorization/*/Write`). |
| 2 | `az storage ...` data-plane commands without `--auth-mode login` | Silently default to key-based auth, auto-fetching the account key via `listKeys`. Always pass `--auth-mode login` to authenticate via your Entra identity/RBAC. |
| 3 | A brand-new workspace's state is completely empty | Applying unmodified config into it collides on identical resource names/scope. Make the config workspace-aware (naming and/or resource group keyed on `terraform.workspace`) before applying in a new workspace. |
| 4 | azurerm backend does not create the storage account or container | Both must pre-exist (that's why Ex 1 creates them by hand). The backend only auto-creates the **blob** (state file) inside an already-existing container. |
| 5 | Local `terraform.tfstate.backup` is a one-time migration snapshot | Not continuously maintained on a remote backend — don't treat it as an ongoing backup. Use blob versioning / container soft delete on the storage account for real protection. |
| 6 | RBAC container-level restriction only works with genuinely separate containers/accounts per environment | A shared container with key-name prefixes (or workspaces) can't be access-scoped per environment via ordinary RBAC — hence separate storage accounts per environment in the design. |

---

## Quick reference

**Reconciliation table:**

| | In config | Not in config |
|---|---|---|
| In state | update if different | destroy |
| Not in state | create | ignored |

**Backend block — `backend.tf`, current lab (shared-key):** four-argument block with `use_azuread_auth`/`use_cli` commented out (relies on shared key access being enabled).

**Backend block — intended end state (AAD auth, shared keys disabled):** uncomment the two lines —
```hcl
    use_azuread_auth = true
    use_cli          = true
```

**Disable shared keys (needs `--bypass AzureServices` for policy):**
```powershell
az storage account update --name stvglabwustfstate --resource-group rg-vg-lab-wus-01 `
  --allow-shared-key-access false --bypass AzureServices
```

**Grant the data-plane role (storage owner runs this, per identity, scoped to the account):**
```powershell
az role assignment create --assignee <object-id> --role "Storage Blob Data Contributor" `
  --scope "/subscriptions/<your-subscription-id>/resourceGroups/rg-vg-lab-wus-01/providers/Microsoft.Storage/storageAccounts/stvglabwustfstate"
```

**State commands:**
```powershell
terraform state list [prefix]
terraform state show <address>
terraform state mv SOURCE DESTINATION
terraform state rm <address>
```

**Migration:**
```powershell
terraform init -migrate-state          # prompts to copy state; verify with a zero-change plan
```

**Workspaces:**
```powershell
terraform workspace new <name>
terraform workspace select <name>
terraform workspace list
terraform workspace delete <name>      # refuses if the workspace's state still holds resources
```

**Workspace-aware naming (self-scaling):**
```hcl
environment = terraform.workspace == "default" ? "lab" : terraform.workspace
```

**Stale lock recovery (verify nobody is really running first):**
```powershell
az storage blob lease break --account-name stvglabwustfstate `
  --container-name tfstate --blob-name networking/hub-spoke
```