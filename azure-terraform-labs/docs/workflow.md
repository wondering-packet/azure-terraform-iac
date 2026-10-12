# Terraform Labs — Finalized Workflow

## Structure: one self-contained folder per day

Each day is an independent Terraform root. You copy the `_base/` template into a new
day folder, add that day's exercise files, and run Terraform inside that folder. Nothing
references anything outside its own directory.

```
azure-terraform-labs/
├── README.md
├── PROGRESS.md
├── .gitignore
├── docs/                    read-once reference + cheatsheets
├── _base/                   canonical base files — the copy source
└── dayNN-topic/             one per day, self-contained
    ├── dayNN-notes.md
    ├── main.tf              copied from _base
    ├── variables.tf         copied from _base
    ├── locals.tf            copied from _base
    ├── outputs.tf           copied from _base
    ├── terraform.tfvars     copied from _base
    └── exNN-*.tf            that day's exercises
```

## Why this works (and the parent-module approach didn't)

Terraform only reads `.tf` files in the **current working directory**. It does not read
parent folders, sibling folders, or subfolders — except folders explicitly declared as
`module` blocks. A day folder therefore cannot reference `local.*` or `var.*` defined in
a parent. The only reliable way to give each day access to the shared base is to **copy
the base files into the day folder** so they sit alongside the exercises. That's this
structure. Yes, it duplicates the base per day — that's the accepted trade-off for having
each day run standalone with zero cross-folder wiring.

## Starting a new day (PowerShell)

```powershell
Copy-Item -Recurse _base dayNN-topic-name
cd dayNN-topic-name

$env:ARM_CLIENT_ID       = "<client-id>"
$env:ARM_CLIENT_SECRET   = "<client-secret>"
$env:ARM_TENANT_ID       = "<tenant-id>"
$env:ARM_SUBSCRIPTION_ID = "<subscription-id>"

terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
# ... work through exercises ...
terraform destroy   # tear down when done
```

## Rules

1. **One declaration per name per folder.** Terraform merges all `.tf` in a folder, so
   declare each variable/local/resource once. Don't redeclare a base variable in an exercise file.
2. **tfvars key must match variable name exactly.** No fuzzy matching.
3. **Exercise files are self-contained within the day.** If ex04 references
   `azurerm_virtual_network.hub`, that resource must be defined in a `.tf` file in the same
   day folder (e.g. ex06 defines it, or you add it).
4. **Name files by purpose**, not just number where it helps: `ex04-foreach.tf`,
   `ex05-datasources.tf`.
5. **Track progress in PROGRESS.md and git commits**, not in filenames.

## Editing the base

When you improve a base file (e.g. add a variable used from Day 3 on), update `_base/`
so future day copies inherit it. Already-created day folders keep their own copy — update
them manually only if that day needs the change.
